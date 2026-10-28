import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { writeTextAtomic } from './PersistentFile';

export function validControlToken(token: string): boolean { return /^[0-9a-fA-F]{32,128}$/.test(token); }

export function loadControlToken(dir: string): string {
  try {
    const token = fileIo.readTextSync(dir + '/tether-control-token').trim();
    return validControlToken(token) ? token : '';
  } catch (_) { return ''; }
}

export function ensureControlToken(dir: string, supplied?: string): string {
  if (supplied !== undefined && !validControlToken(supplied)) throw new Error('invalid_control_token');
  let token = supplied ?? loadControlToken(dir);
  if (!token) {
    const data = cryptoFramework.createRandom().generateRandomSync(32).data;
    for (const byte of data) token += byte.toString(16).padStart(2, '0');
  }
  if (token !== loadControlToken(dir)) {
    writeTextAtomic(dir + '/tether-control-token', token);
  }
  return token;
}

export function matchesControlToken(expected: string, authorization: string): boolean {
  if (!expected || !authorization.startsWith('Bearer ')) return false;
  const value = authorization.substring(7);
  if (value.length !== expected.length) return false;
  let different: number = 0;
  for (let index = 0; index < expected.length; ++index) different |= value.charCodeAt(index) ^ expected.charCodeAt(index);
  return different === 0;
}

export function newRequestId(): string {
  const data = cryptoFramework.createRandom().generateRandomSync(16).data;
  data[6] = (data[6] & 15) | 64;
  data[8] = (data[8] & 63) | 128;
  let value = '';
  for (let i = 0; i < data.length; ++i) {
    if (i === 4 || i === 6 || i === 8 || i === 10) value += '-';
    value += data[i].toString(16).padStart(2, '0');
  }
  return value;
}
