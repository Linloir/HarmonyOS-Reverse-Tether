import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import tether from 'libtether.so';
import { PORT, VPN_ABILITY, TetherState, TunnelStats, saveState } from '../common/State';
import { hasPrivacyConsent } from '../common/PrivacyConsent';
import { ensureControlToken, loadControlToken } from '../common/ControlAuth';
import { loadTetherRequest, rememberTetherRequest } from '../common/TetherRequest';
import { TetherSettings, loadSettings, decodeRelayPolicy, routedApplications, IPV6_ADDRESS, IPV6_DNS } from '../common/Settings';
import { validIPv6 } from '../common/NetworkAddress';
import { ProbeRun, ProbeRequest, ProbeReply } from '../probe/NetworkProbe';
import { ConfigureRequest, validDNS } from './ControlProtocol';
import { VpnControlServer, VpnControlHandler, controlServerFor } from './VpnControlServer';
import { ApplicationCatalog, pendingApplicationCatalog, saveApplicationCatalog } from '../common/ApplicationCatalog';

export default class TetherVpnAbility extends VpnExtensionAbility implements VpnControlHandler {
  private connection?: vpnExtension.VpnConnection;
  private control?: VpnControlServer;
  private activeProbe?: ProbeRun;
  private stopped: boolean = true;
  private generation: number = 0;
  private session: number = 0;
  private socketFd: number = -1;
  private tunFd: number = -1;
  private timer: number = -1;
  private retryTimer: number = -1;
  private attempts: number = 0;
  private operations: Promise<void> = Promise.resolve();
  private state: TetherState = new TetherState();
  private settings: TetherSettings = new TetherSettings();
  private txOffset: number = 0;
  private rxOffset: number = 0;
  private countersActive: boolean = false;

  onCreate(want: Want): void {
    if (!hasPrivacyConsent(this.context.filesDir)) {
      hilog.info(0x0001, 'HarmonyTether', 'PRIVACY_REQUIRED VPN was not started');
      // Release this uninitialized extension so a post-consent start gets onCreate.
      // No tunnel or native worker has been created at this point.
      this.stop().catch(() => {});
      return;
    }
    try {
      // API 18 does not guarantee forwarding Want parameters to the extension.
      // EntryAbility persists these before requesting the system VPN start.
      const saved = loadTetherRequest(this.context.filesDir);
      const port = want.parameters?.port ?? saved['port'] ?? PORT;
      const dns = want.parameters?.dns ?? saved['dns'] ?? '';
      if ((typeof port !== 'string' && typeof port !== 'number') || !/^\d{1,5}$/.test(String(port)) ||
          Number(port) < 1024 || Number(port) > 65535 || typeof dns !== 'string' || !validDNS(dns)) {
        this.publish('error', '连接端口或 DNS 地址格式无效'); return;
      }
      this.state.port = Number(port);
      this.state.dns = dns;
      const token = want.parameters?.controlToken;
      ensureControlToken(this.context.filesDir, typeof token === 'string' ? token : undefined);
      this.settings = loadSettings(this.context.filesDir);
      this.connection = vpnExtension.createVpnConnection(this.context);
      this.session = tether.newSession();
      this.state.session = this.session;
      this.stopped = false;
      this.control = controlServerFor(this);
      this.control.begin().then(() => { this.state.controlReady = !this.stopped; }).catch(() => {
        hilog.warn(0x0001, 'HarmonyTether', 'CONTROL_LISTEN_FAILED');
      });
      this.timer = setInterval(() => this.tick(), 1000);
      const generation = ++this.generation;
      this.enqueue(() => this.establish(generation));
    } catch (_) { this.publish('error', '无法创建 VPN 服务，请检查系统授权'); }
  }

  private enqueue(operation: () => Promise<void>): Promise<void> {
    this.operations = this.operations.then(operation).catch(() => {
      if (!this.stopped) this.publish('error', 'VPN 操作失败，请重新连接');
    });
    return this.operations;
  }
  private current(generation: number): boolean { return !this.stopped && generation === this.generation; }
  private bundle(): string { return this.context.extensionAbilityInfo.bundleName; }
  applicationsPending(): number { return pendingApplicationCatalog(this.context.filesDir); }
  applications(value: ApplicationCatalog): void { saveApplicationCatalog(this.context.filesDir, value); }
  token(): string { return loadControlToken(this.context.filesDir); }
  status(): TetherState { this.updateCounters(); return this.state; }

  private publish(state: string, message: string): void {
    // A replaced extension must never overwrite the new instance's status.
    if (this.session > 0) { try { tether.status(this.session); } catch (_) { return; } }
    this.state.state = state;
    this.state.message = message;
    try { saveState(this.context.filesDir, this.state); }
    catch (_) { hilog.warn(0x0001, 'HarmonyTether', 'STATUS_WRITE_FAILED'); }
  }
  private updateCounters(): TunnelStats | undefined {
    if (this.session <= 0 || !this.countersActive) return undefined;
    try {
      const stats = JSON.parse(tether.status(this.session)) as TunnelStats;
      this.state.txBytes = this.txOffset + stats.txBytes;
      this.state.rxBytes = this.rxOffset + stats.rxBytes;
      return stats;
    } catch (_) { return undefined; }
  }

  private async establish(generation: number): Promise<void> {
    if (!this.current(generation) || !this.connection) return;
    this.state.retryAt = 0;
    this.publish('connecting', '正在连接…');
    let keepTunOnFailure = true;
    try {
      this.socketFd = tether.createSocket();
      await this.connection.protect(this.socketFd);
      if (!this.current(generation)) { await this.cleanup(); return; }
      const identifier = await tether.connect(this.socketFd, this.state.port);
      if (!this.current(generation)) { await this.cleanup(); return; }
      const policy = decodeRelayPolicy(identifier, this.settings.ipv6);
      const reuseTun = this.tunFd >= 0 && this.state.effectiveIpv6 === policy.effectiveIpv6 &&
        this.state.settingsRevision === this.settings.revision;
      keepTunOnFailure = reuseTun;
      this.state.ipv6Policy = policy.ipv6Policy;
      this.state.effectiveIpv6 = policy.effectiveIpv6;
      this.state.relayProtocol = policy.supported;
      this.state.appMode = this.settings.appMode;
      this.state.settingsRevision = this.settings.revision;
      if (validIPv6(this.state.dns) && !policy.effectiveIpv6) throw new Error('ipv6_dns_disabled');
      const config: vpnExtension.VpnConfig = {
        addresses: [{address: {address: '10.0.0.2', family: 1}, prefixLength: 32}],
        routes: [{interface: 'vpn-tun',
          destination: {address: {address: '0.0.0.0', family: 1}, prefixLength: 0},
          gateway: {address: '0.0.0.0', family: 1}, hasGateway: false, isDefaultRoute: true}],
        dnsAddresses: [this.state.dns || '10.0.0.3'],
        mtu: 1500, isIPv4Accepted: true, isIPv6Accepted: policy.effectiveIpv6, isBlocking: false
      };
      if (policy.effectiveIpv6) {
        config.addresses.push({address: {address: IPV6_ADDRESS, family: 2}, prefixLength: 128});
        config.routes?.push({interface: 'vpn-tun',
          destination: {address: {address: '::', family: 2}, prefixLength: 0},
          // An on-link IPv6 route needs an empty gateway on HarmonyOS.
          gateway: {address: ''}, hasGateway: false, isDefaultRoute: false});
        if (!this.state.dns) config.dnsAddresses?.push(IPV6_DNS);
      }
      if (this.settings.appMode === 'allow') config.trustedApplications = routedApplications(this.settings, this.bundle());
      if (this.settings.appMode === 'deny') config.blockedApplications = routedApplications(this.settings, this.bundle());
      if (!reuseTun) {
        await this.releaseTun();
        if (!this.current(generation)) { await this.cleanup(); return; }
        this.tunFd = await this.connection.create(config);
      }
      if (!this.current(generation)) { await this.cleanup(); return; }
      keepTunOnFailure = false;
      tether.start(this.tunFd, this.socketFd, this.session, policy.effectiveIpv6 ? 1 : 0);
      this.countersActive = true;
      this.state.vpnSession = Math.max(Date.now(), this.state.vpnSession + 1);
      this.state.connectedAt = Date.now();
      this.state.lastError = '';
      this.publish('connected', '已连接 · 正在通过 USB 共享网络');
      hilog.info(0x0001, 'HarmonyTether', 'VPN_READY port=%{public}d ipv6=%{public}s mode=%{public}s',
        this.state.port, String(policy.effectiveIpv6), this.settings.appMode);
    } catch (error) {
      const err = error as BusinessError;
      this.state.lastError = err.message === 'ipv6_dns_disabled' ? 'ipv6_dns_disabled' : 'connect_' + (err.code ?? 0);
      await this.cleanup(keepTunOnFailure && this.current(generation));
      if (!this.current(generation)) return;
      if (err.code === 201 || err.code === 2203001 || err.code === 2203002) {
        this.publish('error', '系统拒绝 VPN 连接，请检查 VPN 授权或已有连接'); return;
      }
      if (this.state.lastError === 'ipv6_dns_disabled') {
        this.publish('error', '当前 IPv6 未启用，请使用 IPv4 DNS 或启用 IPv6'); return;
      }
      this.scheduleRetry();
    }
  }

  private scheduleRetry(): void {
    if (this.stopped || this.retryTimer >= 0) return;
    this.state.reconnects++;
    const delay = Math.min(1000 * Math.pow(2, Math.min(this.attempts++, 5)), 30000);
    this.state.retryAt = Date.now() + delay;
    this.publish('reconnecting', 'USB 网络已断开，正在自动重连…');
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      const generation = ++this.generation;
      this.enqueue(() => this.establish(generation));
    }, delay);
  }
  private tick(): void {
    if (this.stopped) return;
    if (this.state.state === 'connected') {
      const stats = this.updateCounters();
      if (!stats || stats.state !== 'running') {
        this.state.lastError = 'tunnel_' + (stats?.errno ?? -1);
        this.publish('reconnecting', '连接已中断，正在恢复…');
        const generation = ++this.generation;
        this.enqueue(async () => { await this.cleanup(stats !== undefined && !stats.tunError);
          if (this.current(generation)) this.scheduleRetry(); });
        return;
      }
      // A brief successful handshake must not reset a repeated failure's backoff.
      if (Date.now() - this.state.connectedAt >= 30000) this.attempts = 0;
    }
    this.publish(this.state.state, this.state.message);
  }
  private async releaseTun(): Promise<void> {
    if (this.tunFd < 0) return;
    tether.close(this.tunFd); this.tunFd = -1;
    try { await this.connection?.destroy(); } catch (_) { /* Original fd is already released. */ }
  }
  private async cleanup(keepTun: boolean = false): Promise<void> {
    this.activeProbe?.cancel();
    this.updateCounters();
    this.countersActive = false;
    if (this.session > 0) { try { tether.stop(this.session); } catch (_) { /* Replaced native session. */ } }
    this.txOffset = this.state.txBytes;
    this.rxOffset = this.state.rxBytes;
    // A lost USB/relay socket does not invalidate the OS VPN. Keep its TUN and
    // routing while reconnecting; only settings/policy changes or stop release it.
    if (!keepTun) await this.releaseTun();
    if (this.socketFd >= 0) { tether.close(this.socketFd); this.socketFd = -1; }
  }

  async probe(request: ProbeRequest): Promise<ProbeReply> {
    const epoch = this.state.vpnSession;
    const before = this.updateCounters();
    const reply = new ProbeReply(); reply.request_id = request.request_id; reply.path = 'vpn'; reply.vpn_session = epoch;
    if (this.stopped || this.state.state !== 'connected' || !before || before.state !== 'running') {
      reply.error = 'vpn_unavailable'; return reply;
    }
    // Bind to the VPN address and never protect these sockets. The application's
    // own bundle is always included in VPN routing, even with per-app filtering.
    const run = new ProbeRun('10.0.0.2', IPV6_ADDRESS);
    this.activeProbe = run;
    try {
      const measured = await run.run(request);
      reply.results = measured.results;
      const after = this.updateCounters();
      reply.tx_bytes_delta = after ? Math.max(0, after.txBytes - before.txBytes) : 0;
      reply.rx_bytes_delta = after ? Math.max(0, after.rxBytes - before.rxBytes) : 0;
      if (epoch !== this.state.vpnSession || this.state.state !== 'connected' || after?.state !== 'running') {
        reply.error = 'vpn_changed';
      } else if (reply.tx_bytes_delta <= 0) reply.error = 'vpn_path_unverified';
      else { reply.value = measured.value; reply.error = measured.error; }
      return reply;
    } finally { if (this.activeProbe === run) this.activeProbe = undefined; }
  }
  async configure(request: ConfigureRequest): Promise<void> {
    const settings = loadSettings(this.context.filesDir);
    const port = request.port ?? this.state.port;
    const dns = request.dns ?? this.state.dns;
    if (port === this.state.port && dns === this.state.dns && settings.revision === this.settings.revision) return;
    rememberTetherRequest({parameters: {port: String(port), dns: dns}}, this.context.filesDir);
    const generation = ++this.generation;
    if (this.retryTimer >= 0) { clearTimeout(this.retryTimer); this.retryTimer = -1; }
    this.activeProbe?.cancel();
    this.publish('reconnecting', '正在应用连接设置…');
    await this.enqueue(async () => {
      await this.cleanup();
      if (!this.current(generation)) return;
      this.state.port = port; this.state.dns = dns; this.settings = settings; this.attempts = 0;
      await this.establish(generation);
    });
  }
  async stop(): Promise<void> {
    await vpnExtension.stopVpnExtensionAbility({bundleName: this.bundle(), abilityName: VPN_ABILITY});
  }
  onDestroy(): void {
    this.stopped = true; ++this.generation;
    if (this.timer >= 0) clearInterval(this.timer);
    if (this.retryTimer >= 0) clearTimeout(this.retryTimer);
    this.control?.close(); this.state.controlReady = false; this.state.retryAt = 0;
    this.activeProbe?.cancel();
    // Stop the worker synchronously. Pending connect owns a duplicate fd for at
    // most five seconds; serialized cleanup prevents it from closing new fds.
    if (this.session > 0) { try { tether.stop(this.session); } catch (_) {} }
    this.publish('stopped', '已断开');
    this.enqueue(() => this.cleanup());
    hilog.info(0x0001, 'HarmonyTether', 'VPN_STOPPED');
  }
}
