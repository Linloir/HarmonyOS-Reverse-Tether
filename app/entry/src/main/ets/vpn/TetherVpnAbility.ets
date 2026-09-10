import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import tether from 'libtether.so';
import { PORT, TetherState, TunnelStats, saveState, loadState } from '../common/State';
import { hasPrivacyConsent } from '../common/PrivacyConsent';

export default class TetherVpnAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  private stopped: boolean = true;
  private generation: number = 0;
  private session: number = 0;
  private socketFd: number = -1;
  private tunFd: number = -1;
  private timer: number = -1;
  private retryTimer: number = -1;
  private attempts: number = 0;
  private state: TetherState = new TetherState();
  private dnsAddress: string = '10.0.0.3';
  private port: number = PORT;

  onCreate(want: Want): void {
    if (!hasPrivacyConsent(this.context.filesDir)) {
      hilog.info(0x0001, 'HarmonyTether', 'PRIVACY_REQUIRED VPN was not started');
      return;
    }
    const requestedPort = want.parameters?.port;
    this.port = loadState(this.context.filesDir).port ?? PORT;
    if (requestedPort !== undefined) {
      if ((typeof requestedPort !== 'string' && typeof requestedPort !== 'number') ||
          !/^\d{1,5}$/.test(String(requestedPort))) {
        this.publish('error', '连接端口格式无效');
        return;
      }
      this.port = Number(requestedPort);
    }
    if (!Number.isInteger(this.port) || this.port < 1024 || this.port > 65535) {
      this.publish('error', '连接端口格式无效');
      return;
    }
    this.state.port = this.port;
    const dns = want.parameters?.dns;
    if (typeof dns === 'string' && dns.length > 0) {
      const parts = dns.split('.');
      if (parts.length !== 4 || parts.some((part: string) => !/^\d{1,3}$/.test(part) || Number(part) > 255)) {
        this.publish('error', 'DNS 地址格式无效');
        return;
      }
      this.dnsAddress = dns;
    }
    this.stopped = false;
    this.timer = setInterval(() => this.tick(), 1000);
    try {
      this.connection = vpnExtension.createVpnConnection(this.context);
      this.session = tether.newSession();
      this.establish(++this.generation);
    } catch (error) {
      this.publish('error', '无法创建 VPN 服务，请检查系统授权');
      hilog.error(0x0001, 'HarmonyTether', 'VPN_INIT_FAILED %{public}s', String(error));
    }
  }

  private publish(state: string, message: string): void {
    if (this.session > 0) {
      try { tether.status(this.session); } catch (_) { return; }
    }
    this.state.state = state;
    this.state.message = message;
    try {
      saveState(this.context.filesDir, this.state);
    } catch (error) {
      hilog.error(0x0001, 'HarmonyTether', 'status write failed: %{public}s', String(error));
    }
  }

  private async establish(generation: number): Promise<void> {
    if (this.stopped || generation !== this.generation || !this.connection) return;
    this.publish('connecting', '正在连接…');
    try {
      this.socketFd = tether.createSocket();
      await this.connection.protect(this.socketFd);
      if (this.stopped || generation !== this.generation) { await this.cleanup(); return; }
      await tether.connect(this.socketFd, this.port);
      if (this.stopped || generation !== this.generation) { await this.cleanup(); return; }
      const config: vpnExtension.VpnConfig = {
        addresses: [{address: {address: '10.0.0.2', family: 1}, prefixLength: 32}],
        routes: [{
          interface: 'vpn-tun',
          destination: {address: {address: '0.0.0.0', family: 1}, prefixLength: 0},
          gateway: {address: '0.0.0.0', family: 1},
          hasGateway: false,
          isDefaultRoute: true
        }],
        // Relay resolves the virtual address through the host's DNS server.
        dnsAddresses: [this.dnsAddress],
        mtu: 1500,
        isIPv4Accepted: true,
        isIPv6Accepted: false,
        isBlocking: false
      };
      this.tunFd = await this.connection.create(config);
      if (this.stopped || generation !== this.generation) { await this.cleanup(); return; }
      tether.start(this.tunFd, this.socketFd, this.session);
      this.attempts = 0;
      this.publish('connected', '已连接 · 正在通过 USB 共享网络');
      hilog.info(0x0001, 'HarmonyTether', 'VPN_READY port=%{public}d mtu=1500 dns=%{public}s', this.port, this.dnsAddress);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0001, 'HarmonyTether', 'VPN_CONNECT_FAILED code=%{public}d message=%{public}s', err.code ?? 0, err.message ?? String(error));
      await this.cleanup();
      if (this.stopped || generation !== this.generation) return;
      if (err.code === 201 || err.code === 2203001 || err.code === 2203002) {
        this.publish('error', '系统拒绝 VPN 连接，请检查 VPN 授权或已有连接');
        return;
      }
      this.scheduleRetry();
    }
  }

  private scheduleRetry(): void {
    if (this.stopped) return;
    this.state.reconnects++;
    const delay = Math.min(1000 * Math.pow(2, this.attempts++), 10000);
    this.publish('reconnecting', 'USB 网络已断开，正在自动重连…');
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.establish(++this.generation);
    }, delay);
  }

  private tick(): void {
    if (this.stopped) return;
    if (this.state.state === 'connected') {
      const stats = JSON.parse(tether.status(this.session)) as TunnelStats;
      this.state.txBytes = stats.txBytes;
      this.state.rxBytes = stats.rxBytes;
      if (stats.state !== 'running') {
        this.publish('reconnecting', '连接已中断，正在恢复…');
        hilog.warn(0x0001, 'HarmonyTether', 'TUNNEL_LOST errno=%{public}d', stats.errno);
        this.cleanup().then(() => this.scheduleRetry());
        return;
      }
    }
    this.publish(this.state.state, this.state.message);
  }

  private async cleanup(): Promise<void> {
    tether.stop(this.session);
    if (this.tunFd >= 0) {
      // The worker owns duplicates; release originals only after it has stopped.
      tether.close(this.tunFd);
      this.tunFd = -1;
      try { await this.connection?.destroy(); } catch (_) { /* Logged by system; local fds still released. */ }
    }
    if (this.socketFd >= 0) { tether.close(this.socketFd); this.socketFd = -1; }
  }

  onDestroy(): void {
    this.stopped = true;
    ++this.generation;
    if (this.timer >= 0) clearInterval(this.timer);
    if (this.retryTimer >= 0) clearTimeout(this.retryTimer);
    // connect() owns a duplicate fd for at most five seconds; generation fencing
    // makes its completion clean up instead of creating a late VPN.
    // The OS may terminate this extension before an asynchronous callback runs.
    // Persist the stop synchronously so the UI need not wait for stale-state expiry.
    this.publish('stopped', '已断开');
    this.cleanup().catch((error: Error) => {
      hilog.error(0x0001, 'HarmonyTether', 'VPN_CLEANUP_FAILED %{public}s', error.message);
    });
    hilog.info(0x0001, 'HarmonyTether', 'VPN_STOPPED');
  }
}
