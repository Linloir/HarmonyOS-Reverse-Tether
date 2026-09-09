// SPDX-License-Identifier: Apache-2.0
import { socket } from '@kit.NetworkKit';
import { ProbeReply } from './NetworkProbe';

// Only a caller holding the unpredictable request ID supplied over the system
// ability interface can retrieve the result. This listener never starts probes.
export class ProbeResultServer {
  private server?: socket.TCPSocketServer;
  private starting?: Promise<void>;
  private clients: number = 0;
  private requestId: string = '';
  private reply?: ProbeReply;
  private consumed?: () => void;

  async begin(id: string, consumed: () => void): Promise<void> {
    if (this.requestId.length > 0) throw new Error('probe_busy');
    this.requestId = id;
    this.reply = undefined;
    this.consumed = consumed;
    if (!this.starting) {
      this.server = socket.constructTCPSocketServerInstance();
      this.server.on('connect', (client: socket.TCPSocketConnection) => this.accept(client));
      this.server.on('error', () => {});
      this.starting = this.server.listen({address: '127.0.0.1', family: 1, port: 41418});
    }
    try { await this.starting; }
    catch (_) { this.starting = undefined; this.end(id); throw new Error('listener_failed'); }
  }
  finish(reply: ProbeReply): void { if (reply.request_id === this.requestId) this.reply = reply; }
  end(id: string): void {
    if (id === this.requestId) { this.requestId = ''; this.reply = undefined; this.consumed = undefined; }
  }
  private accept(client: socket.TCPSocketConnection): void {
    if (this.clients >= 4) { client.close().catch(() => {}); return; }
    this.clients++;
    let done = false;
    let text = '';
    let counted = true;
    const timer = setTimeout(() => { done = true; client.close().catch(() => {}); }, 2000);
    const release = (): void => {
      if (counted) { counted = false; this.clients--; }
      clearTimeout(timer);
    };
    client.on('close', release);
    client.on('error', () => { done = true; release(); client.close().catch(() => {}); });
    client.on('message', (message: socket.SocketMessageInfo) => {
      if (done) return;
      const bytes = new Uint8Array(message.message);
      if (text.length + bytes.length > 2048 || bytes.some((byte: number) => byte > 127 || byte === 0)) {
        done = true; client.close().catch(() => {}); return;
      }
      for (const byte of bytes) text += String.fromCharCode(byte);
      if (!text.includes('\r\n\r\n')) return;
      done = true;
      clearTimeout(timer);
      const line = text.split('\r\n')[0];
      if (!this.requestId || line !== 'GET /v1/probe/' + this.requestId + ' HTTP/1.1') {
        this.send(client, 404, '{"error":"not_found"}').finally(release);
      } else if (!this.reply) {
        this.send(client, 202, '{"state":"pending"}').finally(release);
      } else {
        const consumed = this.consumed;
        this.send(client, 200, JSON.stringify(this.reply)).then((sent: boolean) => { if (sent) consumed?.(); }).finally(release);
      }
    });
  }
  private async send(client: socket.TCPSocketConnection, code: number, body: string): Promise<boolean> {
    // All wire values are ASCII: validated hostnames, numeric metrics and codes.
    const status = code === 200 ? 'OK' : code === 202 ? 'Accepted' : 'Not Found';
    const response = 'HTTP/1.1 ' + code + ' ' + status + '\r\nContent-Type: application/json\r\n' +
      'Cache-Control: no-store\r\nConnection: close\r\nContent-Length: ' + body.length + '\r\n\r\n' + body;
    try { await client.send({data: response}); return true; }
    catch (_) { return false; }
    finally { await client.close().catch(() => {}); }
  }
}

export const probeResultServer = new ProbeResultServer();
