// SPDX-License-Identifier: Apache-2.0
export const SAMPLE_COUNT: number = 5;
export const SAMPLE_INTERVAL_MS: number = 100;
export const RESPONSE_TIMEOUT_MS: number = 800;

export function bindingRequest(id: Uint8Array): ArrayBuffer {
  if (id.length !== 12) throw new Error('invalid_transaction');
  const packet = new Uint8Array(20);
  packet.set([0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42]);
  packet.set(id, 8);
  return packet.buffer;
}

export function matchResponse(packet: Uint8Array, ids: Uint8Array[]): number {
  if (packet.length < 20 || packet.length > 1200) return -1;
  if (packet[0] !== 1 || packet[1] !== 1 || packet[4] !== 0x21 ||
      packet[5] !== 0x12 || packet[6] !== 0xa4 || packet[7] !== 0x42) return -1;
  const bytes = packet[2] * 256 + packet[3];
  if (bytes % 4 !== 0 || bytes + 20 !== packet.length) return -1;
  // Reject malformed attribute lengths, including a truncated padded value.
  let offset = 20;
  while (offset < packet.length) {
    if (offset + 4 > packet.length) return -1;
    const length = packet[offset + 2] * 256 + packet[offset + 3];
    offset += 4 + Math.ceil(length / 4) * 4;
    if (offset > packet.length) return -1;
  }
  for (let index = 0; index < ids.length; ++index) {
    if (ids[index].length === 12 && ids[index].every((byte: number, i: number) => byte === packet[8 + i])) return index;
  }
  return -1;
}

export class ProbeValue {
  protocol: string = 'stun_binding_v1';
  median_rtt_ms: number | null = null;
  packet_loss_percent: number = 100;
  sent: number = 0;
  received: number = 0;
  rtts_ms: number[] = [];
  host: string = '';
  port: number = 0;
}

export function summarize(sent: number, rtts: number[], host: string, port: number): ProbeValue {
  if (sent < 1 || sent > SAMPLE_COUNT || rtts.length > sent ||
      rtts.some((rtt: number) => !Number.isFinite(rtt) || rtt < 0)) throw new Error('invalid_samples');
  const value = new ProbeValue();
  value.sent = sent;
  value.received = rtts.length;
  value.packet_loss_percent = (sent - rtts.length) * 100 / sent;
  value.rtts_ms = rtts.slice();
  value.host = host;
  value.port = port;
  if (rtts.length > 0) {
    const ordered = rtts.slice().sort((a: number, b: number) => a - b);
    const middle = Math.floor(ordered.length / 2);
    value.median_rtt_ms = ordered.length % 2 === 0 ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle];
  }
  return value;
}
