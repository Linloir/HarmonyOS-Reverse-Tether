// SPDX-License-Identifier: Apache-2.0
import { connection, socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { systemDateTime, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { validIPv4, validIPv6, sameAddress } from '../common/NetworkAddress';
import { bindingRequest, matchResponse, summarize, ProbeValue,
  SAMPLE_COUNT, SAMPLE_INTERVAL_MS, RESPONSE_TIMEOUT_MS } from './StunPacket';

export interface ProbeServer { host: string; port: number; family?: number; }
export interface ProbeRequest { request_id: string; servers: ProbeServer[]; }
export class ServerResult {
  host: string = '';
  port: number = 0;
  value?: ProbeValue;
  error?: string;
}
export class ProbeReply {
  request_id: string = '';
  value?: ProbeValue;
  results: ServerResult[] = [];
  error?: string;
  path?: string;
  vpn_session?: number;
  tx_bytes_delta?: number;
  rx_bytes_delta?: number;
}

export function validRequestId(id: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id);
}
export function parseRequest(text: string): ProbeRequest {
  if (text.length > 4096) throw new Error('invalid_request');
  const request = JSON.parse(text) as ProbeRequest;
  if (!request || typeof request.request_id !== 'string' || !validRequestId(request.request_id) ||
      !Array.isArray(request.servers) || request.servers.length < 1 || request.servers.length > 4) {
    throw new Error('invalid_request');
  }
  for (const server of request.servers) {
    const literal = server && typeof server.host === 'string' && (validIPv4(server.host) || validIPv6(server.host));
    if (!server || typeof server.host !== 'string' || server.host.length > 253 ||
        (!literal && (!/^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$/.test(server.host) ||
        server.host.split('.').some((label: string) => label.length < 1 || label.length > 63 ||
          label.startsWith('-') || label.endsWith('-')))) ||
        (server.family !== undefined && server.family !== 4 && server.family !== 6) ||
        (server.family === 4 && validIPv6(server.host)) || (server.family === 6 && validIPv4(server.host)) ||
        !Number.isInteger(server.port) || server.port < 1 || server.port > 65535) {
      throw new Error('invalid_server');
    }
  }
  return request;
}

function now(): number { return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000; }
function wait(ms: number): Promise<void> { return new Promise<void>((resolve) => setTimeout(resolve, ms)); }
let pendingLookups: number = 0;
let pendingNetworkLookups: number = 0;

async function resolveAddress(host: string, family?: number, network?: connection.NetHandle): Promise<connection.NetAddress> {
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) {
    if (validIPv4(host)) return {address: host, family: 1};
    throw new Error('dns_failed');
  }
  if (validIPv6(host)) return {address: host, family: 2};
  for (let attempt = 0; attempt < 3; ++attempt) {
    if (pendingLookups >= 4) throw new Error('dns_busy');
    pendingLookups++;
    try {
      const address = await new Promise<connection.NetAddress>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('dns_timeout')), 750);
        const lookup = network ? network.getAddressesByName(host) : connection.getAddressesByName(host);
        lookup.then((addresses: connection.NetAddress[]) => {
          clearTimeout(timer);
          const selected = addresses.find((entry: connection.NetAddress) => entry.family === (family === 6 ? 2 : 1))
            ?? (family === undefined ? addresses.find((entry: connection.NetAddress) => entry.family === 2) : undefined);
          if (selected) resolve(selected); else reject(new Error('dns_failed'));
        }).catch(() => { clearTimeout(timer); reject(new Error('dns_failed')); })
          .finally(() => { pendingLookups--; });
      });
      return address;
    } catch (_) {
      if (attempt === 2) throw new Error('dns_failed');
      await wait(100);
    }
  }
  throw new Error('dns_failed');
}

export class ProbeRun {
  private canceled: boolean = false;
  private active?: socket.UDPSocket;
  private ipv4Source: string;
  private ipv6Source: string;
  private selectedNetwork?: Promise<connection.NetHandle>;
  constructor(ipv4Source: string = '0.0.0.0', ipv6Source: string = '::') {
    this.ipv4Source = ipv4Source;
    this.ipv6Source = ipv6Source;
  }
  cancel(): void {
    this.canceled = true;
    this.active?.close().catch(() => {});
  }
  private check(): void { if (this.canceled) throw new Error('probe_canceled'); }

  private async networkForDNS(): Promise<connection.NetHandle> {
    if (this.selectedNetwork) return this.selectedNetwork;
    if (pendingNetworkLookups >= 4) throw new Error('vpn_dns_busy');
    pendingNetworkLookups++;
    this.selectedNetwork = new Promise<connection.NetHandle>((resolve, reject) => {
      let expired = false;
      const timer = setTimeout(() => { expired = true; reject(new Error('vpn_dns_timeout')); }, 1000);
      const discover = async (): Promise<connection.NetHandle> => {
        const networks = await connection.getAllNets();
        this.check();
        for (const network of networks.slice(0, 32)) {
          if (expired) throw new Error('vpn_dns_timeout');
          this.check();
          let properties: connection.ConnectionProperties;
          try { properties = await connection.getConnectionProperties(network); }
          catch (_) { continue; }
          this.check();
          if (expired) throw new Error('vpn_dns_timeout');
          if (properties.interfaceName === 'vpn-tun' && properties.linkAddresses.some((link: connection.LinkAddress) =>
            sameAddress(link.address.address, this.ipv4Source) ||
              (this.ipv6Source !== '::' && sameAddress(link.address.address, this.ipv6Source)))) return network;
        }
        throw new Error('vpn_dns_unavailable');
      };
      discover().then(resolve).catch((error: Error) => {
        reject(new Error(error.message === 'probe_canceled' || error.message === 'vpn_dns_timeout'
          ? error.message : 'vpn_dns_unavailable'));
      }).finally(() => { clearTimeout(timer); pendingNetworkLookups--; });
    });
    return this.selectedNetwork;
  }

  private async addressFor(server: ProbeServer): Promise<connection.NetAddress> {
    this.check();
    // A default-network lookup can suppress AAAA when the underlying Wi-Fi is
    // IPv4-only, even though this VPN has a working IPv6 route and DNS server.
    // Select our existing VPN explicitly; never fall back to another network.
    const network = this.ipv4Source !== '0.0.0.0' && !validIPv4(server.host) && !validIPv6(server.host)
      ? await this.networkForDNS() : undefined;
    this.check();
    return resolveAddress(server.host, server.family, network);
  }

  async run(request: ProbeRequest): Promise<ProbeReply> {
    const reply = new ProbeReply();
    reply.request_id = request.request_id;
    const timer = setTimeout(() => this.cancel(), 16500);
    try {
      // Measure each requested endpoint independently. The first endpoint with
      // replies supplies the compatible summary; never mix endpoint samples.
      for (const server of request.servers) {
        this.check();
        const result = new ServerResult();
        result.host = server.host;
        result.port = server.port;
        try { result.value = await this.measure(server); }
        catch (error) { result.error = (error as Error).message; }
        reply.results.push(result);
      }
      this.check();
      const selected = reply.results.find((entry: ServerResult) => entry.value !== undefined && entry.value.received > 0)
        ?? reply.results.find((entry: ServerResult) => entry.value !== undefined);
      if (selected) reply.value = selected.value;
      else reply.error = 'probe_failed';
    } catch (_) { reply.error = 'probe_timeout'; }
    finally { clearTimeout(timer); this.active = undefined; }
    return reply;
  }

  private async measure(server: ProbeServer): Promise<ProbeValue> {
    const address = await this.addressFor(server);
    this.check();
    const udp = socket.constructUDPSocketInstance();
    this.active = udp;
    const ids: Uint8Array[] = [];
    const sentAt: number[] = [];
    const received: boolean[] = [];
    const rtts: number[] = [];
    let failure: boolean = false;
    let failureCode: number = 0;
    let stage: string = 'bind';
    let sent = 0;
    let deadline = 0;
    udp.on('error', (error: BusinessError) => { failure = true; failureCode = error.code ?? 0; });
    udp.on('message', (message: socket.SocketMessageInfo) => {
      const timestamp = now();
      if (this.canceled || timestamp > deadline || !sameAddress(message.remoteInfo.address, address.address) ||
          message.remoteInfo.port !== server.port) return;
      const index = matchResponse(new Uint8Array(message.message), ids);
      if (index < 0 || received[index] || sentAt[index] === undefined) return;
      received[index] = true;
      rtts.push(timestamp - sentAt[index]);
    });
    try {
      await udp.bind({address: address.family === 2 ? this.ipv6Source : this.ipv4Source, family: address.family, port: 0});
      stage = 'send';
      const first = now();
      deadline = first + (SAMPLE_COUNT - 1) * SAMPLE_INTERVAL_MS + RESPONSE_TIMEOUT_MS;
      for (let index = 0; index < SAMPLE_COUNT; ++index) {
        await wait(Math.max(0, first + index * SAMPLE_INTERVAL_MS - now()));
        this.check();
        if (failure || now() >= deadline) throw new Error('socket_failed');
        const id = cryptoFramework.createRandom().generateRandomSync(12).data;
        ids.push(id);
        sentAt.push(now());
        received.push(false);
        await udp.send({data: bindingRequest(id), address: {address: address.address, family: address.family, port: server.port}});
        sent++;
      }
      stage = 'receive';
      await wait(Math.max(0, deadline - now()));
      this.check();
      if (failure) throw new Error('socket_failed');
      return summarize(sent, rtts, server.host, server.port);
    } catch (error) {
      const code = (error as BusinessError).code ?? failureCode;
      hilog.warn(0x0001, 'HarmonyTether', 'PROBE_SOCKET_FAILED stage=%{public}s family=%{public}d code=%{public}d sent=%{public}d',
        stage, address.family ?? 1, code, sent);
      throw new Error(this.canceled ? 'probe_canceled' : 'socket_failed');
    } finally {
      udp.off('message');
      udp.off('error');
      await udp.close().catch(() => {});
      if (this.active === udp) this.active = undefined;
    }
  }
}
