// SPDX-License-Identifier: Apache-2.0
import { connection, socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { bindingRequest, matchResponse, summarize, ProbeValue,
  SAMPLE_COUNT, SAMPLE_INTERVAL_MS, RESPONSE_TIMEOUT_MS } from './StunPacket';

export interface ProbeServer { host: string; port: number; }
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
    if (!server || typeof server.host !== 'string' || server.host.length > 253 ||
        !/^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$/.test(server.host) ||
        server.host.split('.').some((label: string) => label.length < 1 || label.length > 63 ||
          label.startsWith('-') || label.endsWith('-')) ||
        !Number.isInteger(server.port) || server.port < 1 || server.port > 65535) {
      throw new Error('invalid_server');
    }
  }
  return request;
}

function now(): number { return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000; }
function wait(ms: number): Promise<void> { return new Promise<void>((resolve) => setTimeout(resolve, ms)); }
let pendingLookups: number = 0;

async function resolveIPv4(host: string): Promise<string> {
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) {
    if (host.split('.').every((part: string) => Number(part) <= 255)) return host;
    throw new Error('dns_failed');
  }
  for (let attempt = 0; attempt < 3; ++attempt) {
    if (pendingLookups >= 4) throw new Error('dns_busy');
    pendingLookups++;
    try {
      const address = await new Promise<string>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('dns_timeout')), 750);
        connection.getAddressesByName(host).then((addresses: connection.NetAddress[]) => {
          clearTimeout(timer);
          const ipv4 = addresses.find((entry: connection.NetAddress) => entry.family === 1);
          if (ipv4) resolve(ipv4.address); else reject(new Error('dns_failed'));
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
  cancel(): void {
    this.canceled = true;
    this.active?.close().catch(() => {});
  }
  private check(): void { if (this.canceled) throw new Error('probe_canceled'); }

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
    const address = await resolveIPv4(server.host);
    this.check();
    const udp = socket.constructUDPSocketInstance();
    this.active = udp;
    const ids: Uint8Array[] = [];
    const sentAt: number[] = [];
    const received: boolean[] = [];
    const rtts: number[] = [];
    let failure: boolean = false;
    let sent = 0;
    let deadline = 0;
    udp.on('error', () => { failure = true; });
    udp.on('message', (message: socket.SocketMessageInfo) => {
      const timestamp = now();
      if (this.canceled || timestamp > deadline || message.remoteInfo.address !== address ||
          message.remoteInfo.port !== server.port) return;
      const index = matchResponse(new Uint8Array(message.message), ids);
      if (index < 0 || received[index] || sentAt[index] === undefined) return;
      received[index] = true;
      rtts.push(timestamp - sentAt[index]);
    });
    try {
      await udp.bind({address: '0.0.0.0', family: 1, port: 0});
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
        await udp.send({data: bindingRequest(id), address: {address: address, family: 1, port: server.port}});
        sent++;
      }
      await wait(Math.max(0, deadline - now()));
      this.check();
      if (failure) throw new Error('socket_failed');
      return summarize(sent, rtts, server.host, server.port);
    } catch (_) {
      throw new Error(this.canceled ? 'probe_canceled' : 'socket_failed');
    } finally {
      udp.off('message');
      udp.off('error');
      await udp.close().catch(() => {});
      if (this.active === udp) this.active = undefined;
    }
  }
}
