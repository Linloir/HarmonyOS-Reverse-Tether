import { fileIo } from '@kit.CoreFileKit';
import { writeTextAtomic } from './PersistentFile';

export const MAX_APPLICATIONS = 63;
export const IPV6_ADDRESS = 'fd00:7265:7674::2';
export const IPV6_DNS = 'fd00:7265:7674::3';

export class TetherSettings {
  ipv6: boolean = false;
  appMode: string = 'all';
  applications: string[] = [];
  revision: number = 0;
}

export class RelayPolicy {
  supported: boolean = false;
  ipv6Capable: boolean = false;
  ipv6Policy: string = 'off';
  effectiveIpv6: boolean = false;
}

export function decodeRelayPolicy(identifier: number, requested: boolean): RelayPolicy {
  const result = new RelayPolicy();
  const value = identifier >>> 0;
  if ((value >>> 24) !== 0xA5) return result;
  result.supported = true;
  result.ipv6Capable = (value & 0x00200000) !== 0;
  const mode = (value >>> 22) & 3;
  result.ipv6Policy = mode === 0 ? 'inherit' : mode === 2 ? 'on' : 'off';
  result.effectiveIpv6 = result.ipv6Capable && (result.ipv6Policy === 'on' ||
    (result.ipv6Policy === 'inherit' && requested));
  return result;
}

export function validApplicationBundle(name: string): boolean {
  return name.length <= 255 && /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$/.test(name);
}

export function parseApplications(text: string): string[] {
  if (text.length > 16384) throw new Error('应用列表过长');
  const result: string[] = [];
  for (const value of text.split(/[\s,，;；]+/)) {
    const name = value.trim();
    if (!name) continue;
    if (!validApplicationBundle(name)) {
      throw new Error('请输入有效应用包名，例如 com.example.app');
    }
    if (!result.includes(name)) result.push(name);
  }
  if (result.length > MAX_APPLICATIONS) throw new Error('最多添加 63 个应用');
  return result;
}

export function normalizeSettings(settings: TetherSettings): TetherSettings {
  if (!settings || typeof settings.ipv6 !== 'boolean' ||
      !['all', 'allow', 'deny'].includes(settings.appMode) || !Array.isArray(settings.applications) ||
      settings.applications.some((name: string) => typeof name !== 'string')) {
    throw new Error('设置格式无效');
  }
  const result = new TetherSettings();
  result.ipv6 = settings.ipv6;
  result.appMode = settings.appMode;
  result.applications = parseApplications(settings.applications.join('\n'));
  result.revision = Number.isFinite(settings.revision) ? settings.revision : 0;
  return result;
}

export function loadSettings(dir: string): TetherSettings {
  try { return normalizeSettings(JSON.parse(fileIo.readTextSync(dir + '/tether-settings.json')) as TetherSettings); }
  catch (_) { return new TetherSettings(); }
}

export function saveSettings(dir: string, settings: TetherSettings): void {
  const value = normalizeSettings(settings);
  value.revision = Date.now();
  writeTextAtomic(dir + '/tether-settings.json', JSON.stringify(value));
}

export function routedApplications(settings: TetherSettings, bundle: string): string[] {
  const applications = settings.applications.filter((name: string) => name !== bundle);
  // Diagnostics must exercise the same VPN. Reserve one platform list slot.
  if (settings.appMode === 'allow') applications.push(bundle);
  return applications;
}
