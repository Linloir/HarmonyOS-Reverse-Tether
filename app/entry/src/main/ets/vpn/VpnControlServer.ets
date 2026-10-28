import { socket } from '@kit.NetworkKit';
import { CONTROL_PORT, TetherState } from '../common/State';
import { matchesControlToken } from '../common/ControlAuth';
import { ProbeReply, ProbeRequest, parseRequest, validRequestId } from '../probe/NetworkProbe';
import { ConfigureRequest, parseConfigure, parseStop, asciiJSON } from './ControlProtocol';
import { ApplicationCatalog, parseApplicationCatalog } from '../common/ApplicationCatalog';

export interface VpnControlHandler {
  applicationsPending(): number;
  applications(value: ApplicationCatalog): void;
  status(): TetherState;
  token(): string;
  probe(request: ProbeRequest): Promise<ProbeReply>;
  configure(request: ConfigureRequest): Promise<void>;
  stop(): Promise<void>;
}

export class VpnControlServer {
  private server?: socket.TCPSocketServer;
  private clients: number = 0;
  private probeId: string = '';
  private probeReply?: ProbeReply;
  private probeExpires: number = 0;
  private changing: boolean = false;
  private closed: boolean = false;
  private handler: VpnControlHandler;
  constructor(handler: VpnControlHandler) { this.handler = handler; }

  updateHandler(handler: VpnControlHandler): void { this.handler = handler; }

  async begin(): Promise<void> {
    this.closed = false;
    if (this.server) return;
    this.server = socket.constructTCPSocketServerInstance();
    this.server.on('connect', (client: socket.TCPSocketConnection) => this.accept(client));
    this.server.on('error', () => {});
    try { await this.server.listen({address: '127.0.0.1', family: 1, port: CONTROL_PORT}); }
    catch (_) { this.server = undefined; throw new Error('control_listen_failed'); }
  }

  close(): void {
    this.closed = true;
    // API 18 TCPSocketServer has no close method. Retain a single listener for
    // this VPN process, reject requests while stopped, and reuse it if the
    // extension is recreated. Process exit releases the underlying listener.
  }

  private accept(client: socket.TCPSocketConnection): void {
    if (this.closed || this.clients >= 4) { client.close().catch(() => {}); return; }
    this.clients++;
    let finished = false;
    let counted = true;
    let text = '';
    const release = (): void => { if (counted) { counted = false; this.clients--; } };
    const timer = setTimeout(() => { finished = true; release(); client.close().catch(() => {}); }, 3000);
    client.on('close', () => { release(); clearTimeout(timer); });
    client.on('error', () => { finished = true; release(); clearTimeout(timer); client.close().catch(() => {}); });
    client.on('message', (message: socket.SocketMessageInfo) => {
      if (finished) return;
      const bytes = new Uint8Array(message.message);
      if (text.length + bytes.length > 139264 || bytes.some((byte: number) => byte > 127 || byte === 0)) {
        finished = true; clearTimeout(timer); release(); this.send(client, 400, '{"error":"invalid_request"}'); return;
      }
      for (const byte of bytes) text += String.fromCharCode(byte);
      const boundary = text.indexOf('\r\n\r\n');
      if (boundary >= 8192 || boundary < 0 && text.length >= 8192) {
        finished = true; clearTimeout(timer); release(); this.send(client, 400, '{"error":"invalid_request"}'); return;
      }
      if (boundary < 0) return;
      const lines = text.substring(0, boundary).split('\r\n');
      const headers: Record<string, string> = {};
      for (const line of lines.slice(1)) {
        const colon = line.indexOf(':');
        const key = line.substring(0, colon).trim().toLowerCase();
        if (colon <= 0 || headers[key] !== undefined) {
          finished = true; clearTimeout(timer); release(); this.send(client, 400, '{"error":"invalid_request"}'); return;
        }
        headers[key] = line.substring(colon + 1).trim();
      }
      const lengthValue = headers['content-length'] ?? '0';
      const length = Number(lengthValue);
      const maximum = lines[0] === 'POST /v1/applications HTTP/1.1' ? 131072 : 4096;
      if (!/^\d{1,6}$/.test(lengthValue) || length > maximum || headers['transfer-encoding'] !== undefined) {
        finished = true; clearTimeout(timer); release(); this.send(client, 400, '{"error":"invalid_request"}'); return;
      }
      if (text.length < boundary + 4 + length) return;
      finished = true;
      clearTimeout(timer);
      if (text.length !== boundary + 4 + length || !/^(GET|POST) \/v1\/[A-Za-z0-9\/-]+ HTTP\/1\.1$/.test(lines[0])) {
        release(); this.send(client, 400, '{"error":"invalid_request"}'); return;
      }
      const parts = lines[0].split(' ');
      const method = parts[0], path = parts[1];
      if (method === 'GET' && length !== 0 || method === 'POST' &&
          (headers['content-type'] ?? '').split(';')[0].trim() !== 'application/json') {
        release(); this.send(client, 400, '{"error":"invalid_request"}'); return;
      }
      this.handle(client, method, path, headers['authorization'] ?? '', text.substring(boundary + 4))
        .catch(() => this.send(client, 503, '{"error":"control_failed"}')).finally(release);
    });
  }

  private async handle(client: socket.TCPSocketConnection, method: string, path: string,
    authorization: string, body: string): Promise<void> {
    if (method === 'GET' && path === '/v1/status') {
      await this.send(client, 200, asciiJSON(this.handler.status())); return;
    }
    if (!matchesControlToken(this.handler.token(), authorization)) {
      await this.send(client, 401, '{"error":"unauthorized"}'); return;
    }
    if (method === 'GET' && path === '/v1/applications/request') {
      await this.send(client, 200, '{"request":' + this.handler.applicationsPending().toString() + '}'); return;
    }
    if (method === 'POST' && path === '/v1/applications') {
      let value: ApplicationCatalog;
      try { value = parseApplicationCatalog(body); }
      catch (_) { await this.send(client, 400, '{"error":"invalid_catalog"}'); return; }
      if (value.request !== this.handler.applicationsPending()) {
        await this.send(client, 409, '{"error":"stale_catalog"}'); return;
      }
      try { this.handler.applications(value); }
      catch (_) { await this.send(client, 409, '{"error":"stale_catalog"}'); return; }
      await this.send(client, 200, '{"state":"saved"}'); return;
    }
    if (method === 'GET' && path.startsWith('/v1/probe/')) {
      const id = path.substring('/v1/probe/'.length);
      if (!validRequestId(id) || id !== this.probeId || Date.now() > this.probeExpires) {
        await this.send(client, 404, '{"error":"not_found"}'); return;
      }
      await this.send(client, this.probeReply ? 200 : 202, this.probeReply ? asciiJSON(this.probeReply) :
        '{"request_id":"' + id + '","state":"pending"}'); return;
    }
    if (method === 'POST' && path === '/v1/probe') {
      let request: ProbeRequest;
      try { request = parseRequest(body); }
      catch (_) { await this.send(client, 400, '{"error":"invalid_request"}'); return; }
      if (this.probeId === request.request_id && Date.now() <= this.probeExpires) {
        await this.send(client, 202, '{"request_id":"' + request.request_id + '","state":"pending"}'); return;
      }
      if (this.probeId && !this.probeReply && Date.now() <= this.probeExpires) {
        await this.send(client, 409, '{"error":"probe_busy"}'); return;
      }
      if (this.handler.status().state !== 'connected') {
        await this.send(client, 409, '{"error":"vpn_unavailable"}'); return;
      }
      this.probeId = request.request_id;
      this.probeReply = undefined;
      this.probeExpires = Date.now() + 60000;
      this.handler.probe(request).then((reply: ProbeReply) => {
        if (this.probeId === reply.request_id) this.probeReply = reply;
      }).catch(() => {
        const reply = new ProbeReply(); reply.request_id = request.request_id; reply.error = 'probe_failed';
        this.probeReply = reply;
      });
      await this.send(client, 202, '{"request_id":"' + request.request_id + '","state":"pending"}'); return;
    }
    if (method === 'POST' && (path === '/v1/configure' || path === '/v1/stop')) {
      if (this.changing) { await this.send(client, 409, '{"error":"control_busy"}'); return; }
      let request: ConfigureRequest | undefined;
      let id: string;
      try {
        if (path === '/v1/configure') { request = parseConfigure(body); id = request.request_id; }
        else id = parseStop(body);
      } catch (_) { await this.send(client, 400, '{"error":"invalid_request"}'); return; }
      this.changing = true;
      await this.send(client, 202, '{"request_id":"' + id + '","state":"accepted"}');
      try {
        if (request) await this.handler.configure(request);
        else await this.handler.stop();
      } finally { this.changing = false; }
      return;
    }
    await this.send(client, 404, '{"error":"not_found"}');
  }

  private async send(client: socket.TCPSocketConnection, code: number, body: string): Promise<void> {
    const response = 'HTTP/1.1 ' + code + ' Response\r\nContent-Type: application/json\r\n' +
      'Cache-Control: no-store\r\nConnection: close\r\nContent-Length: ' + body.length + '\r\n\r\n' + body;
    try { await client.send({data: response}); }
    catch (_) { /* The caller may disconnect after submitting its request. */ }
    finally { await client.close().catch(() => {}); }
  }
}

let sharedControlServer: VpnControlServer | undefined;
export function controlServerFor(handler: VpnControlHandler): VpnControlServer {
  if (!sharedControlServer) sharedControlServer = new VpnControlServer(handler);
  else sharedControlServer.updateHandler(handler);
  return sharedControlServer;
}
