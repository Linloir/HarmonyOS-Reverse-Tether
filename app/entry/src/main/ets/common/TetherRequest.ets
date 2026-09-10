import { Want } from '@kit.AbilityKit';

// Keep the host's port/DNS in this UI process while the user reads the policy.
// Accepting the policy does not replay a network request; the user taps Connect.
let parameters: Record<string, string> = {};

export function rememberTetherRequest(want: Want): void {
  const next: Record<string, string> = {};
  const dns = want.parameters?.dns;
  if (typeof dns === 'string' && dns.length > 0) next['dns'] = dns;
  const port = want.parameters?.port;
  if (typeof port === 'string' || typeof port === 'number') next['port'] = String(port);
  parameters = next;
}

export function tetherParameters(): Record<string, string> { return parameters; }
export function clearTetherRequest(): void { parameters = {}; }
