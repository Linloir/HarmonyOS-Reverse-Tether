import { Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ensureControlToken } from './ControlAuth';
import { writeTextAtomic } from './PersistentFile';

// Keep the host's port/DNS in this UI process while the user reads the policy.
// Accepting the policy does not replay a network request; the user taps Connect.
let parameters: Record<string, string> = {};

export function rememberTetherRequest(want: Want, dir?: string): void {
  const next: Record<string, string> = {};
  const dns = want.parameters?.dns;
  if (typeof dns === 'string' && dns.length > 0) next['dns'] = dns;
  const port = want.parameters?.port;
  if (typeof port === 'string' || typeof port === 'number') next['port'] = String(port);
  const token = want.parameters?.controlToken;
  if (typeof token === 'string') next['controlToken'] = token;
  parameters = next;
  if (dir) {
    if (typeof token === 'string') ensureControlToken(dir, token);
    const persisted: Record<string, string> = {};
    if (next['port'] !== undefined) persisted['port'] = next['port'];
    if (next['dns'] !== undefined) persisted['dns'] = next['dns'];
    writeTextAtomic(dir + '/tether-host.json', JSON.stringify(persisted));
  }
}

export function loadTetherRequest(dir: string): Record<string, string> {
  try { return JSON.parse(fileIo.readTextSync(dir + '/tether-host.json')) as Record<string, string>; }
  catch (_) { return {}; }
}

export function tetherParameters(): Record<string, string> { return parameters; }
export function clearTetherRequest(): void { parameters = {}; }
