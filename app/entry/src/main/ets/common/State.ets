import { fileIo } from '@kit.CoreFileKit';
import { writeTextAtomic } from './PersistentFile';

export const VPN_ABILITY = 'TetherVpnAbility';
export const PORT = 41417;
export const CONTROL_PORT = 41420;

export interface TunnelStats {
  state: string;
  errno: number;
  txBytes: number;
  rxBytes: number;
  txPackets: number;
  rxPackets: number;
  dropped: number;
  tunError?: boolean;
}

export class TetherState {
  protocol_version: number = 2;
  port: number = PORT;
  dns: string = '';
  session: number = 0;
  vpnSession: number = 0;
  effectiveIpv6: boolean = false;
  ipv6Policy: string = 'off';
  relayProtocol: boolean = false;
  appMode: string = 'all';
  settingsRevision: number = 0;
  lastError: string = '';
  retryAt: number = 0;
  connectedAt: number = 0;
  controlReady: boolean = false;
  state: string = 'stopped';
  message: string = '连接 USB 后，点击连接';
  updatedAt: number = 0;
  reconnects: number = 0;
  txBytes: number = 0;
  rxBytes: number = 0;
}

export function saveState(dir: string, state: TetherState): void {
  state.updatedAt = Date.now();
  writeTextAtomic(dir + '/tether-status.json', JSON.stringify(state));
}

export function loadState(dir: string): TetherState {
  try {
    const state = JSON.parse(fileIo.readTextSync(dir + '/tether-status.json')) as TetherState;
    if (state.state !== 'stopped' && Date.now() - state.updatedAt > 10000) {
      state.state = 'stopped';
      state.message = '服务未运行，请重新连接';
    }
    return state;
  } catch (_) {
    return new TetherState();
  }
}
