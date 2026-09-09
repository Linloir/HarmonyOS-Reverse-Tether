import { fileIo } from '@kit.CoreFileKit';

export const VPN_ABILITY = 'TetherVpnAbility';
export const PORT = 31417;

export interface TunnelStats {
  state: string;
  errno: number;
  txBytes: number;
  rxBytes: number;
  txPackets: number;
  rxPackets: number;
  dropped: number;
}

export class TetherState {
  state: string = 'stopped';
  message: string = '连接 USB 后，点击连接';
  updatedAt: number = 0;
  reconnects: number = 0;
  txBytes: number = 0;
  rxBytes: number = 0;
}

export function saveState(dir: string, state: TetherState): void {
  state.updatedAt = Date.now();
  const path = dir + '/tether-status.json';
  const file = fileIo.openSync(path + '.tmp', fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, JSON.stringify(state));
  } finally {
    fileIo.closeSync(file);
  }
  fileIo.renameSync(path + '.tmp', path);
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
