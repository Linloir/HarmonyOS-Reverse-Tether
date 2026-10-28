import { fileIo } from '@kit.CoreFileKit';
import { MAX_APPLICATIONS, parseApplications, validApplicationBundle } from './Settings';
import { writeTextAtomic } from './PersistentFile';

export const CATALOG_REQUEST_TTL = 45000;

export class SelectableApplication {
  bundleName: string = '';
  label: string = '';
  available: boolean = true;
}
export class ApplicationCatalog {
  request: number = 0;
  updatedAt: number = 0;
  error: string = '';
  applications: SelectableApplication[] = [];
}
export function requestApplicationCatalog(dir: string): number {
  const value = new ApplicationCatalog(); value.request = Math.max(Date.now(), catalogRequest(dir) + 1);
  writeTextAtomic(dir + '/application-request.json', JSON.stringify(value));
  return value.request;
}
export function cancelApplicationCatalog(dir: string, request: number): void {
  if (request > 0 && request === catalogRequest(dir)) {
    writeTextAtomic(dir + '/application-request.json', JSON.stringify(new ApplicationCatalog()));
  }
}
export function catalogRequest(dir: string): number {
  try { return (JSON.parse(fileIo.readTextSync(dir + '/application-request.json')) as ApplicationCatalog).request || 0; }
  catch (_) { return 0; }
}
export function pendingApplicationCatalog(dir: string): number {
  const request = catalogRequest(dir);
  if (request <= 0 || Date.now() - request > CATALOG_REQUEST_TTL || request > Date.now() + 1000) return 0;
  return loadApplicationCatalog(dir).request === request ? 0 : request;
}
export function parseApplicationCatalog(text: string): ApplicationCatalog {
  if (text.length > 131072) throw new Error('invalid_catalog');
  const value = JSON.parse(text) as ApplicationCatalog;
  if (!value || !Number.isSafeInteger(value.request) || value.request <= 0 ||
      !Array.isArray(value.applications) || value.applications.length > 1000) throw new Error('invalid_catalog');
  const seen = new Set<string>();
  const result = new ApplicationCatalog(); result.request = value.request;
  result.updatedAt = Number.isFinite(value.updatedAt) && value.updatedAt > 0 ? value.updatedAt : 0;
  if (value.error !== undefined && value.error !== '' && value.error !== 'read_failed' && value.error !== 'unsupported') {
    throw new Error('invalid_catalog');
  }
  result.error = value.error || '';
  if (result.error && value.applications.length > 0) throw new Error('invalid_catalog');
  for (const item of value.applications) {
    if (!item || typeof item.bundleName !== 'string' || !validApplicationBundle(item.bundleName) ||
        typeof item.label !== 'string' || item.label.length > 128 || /[\x00-\x1f\x7f]/.test(item.label)) {
      throw new Error('invalid_catalog');
    }
    if (seen.has(item.bundleName)) continue;
    seen.add(item.bundleName);
    const app = new SelectableApplication(); app.bundleName = item.bundleName;
    app.label = item.label.trim() || item.bundleName; result.applications.push(app);
  }
  result.applications.sort((a: SelectableApplication, b: SelectableApplication) =>
    a.label.localeCompare(b.label, 'zh-CN') || a.bundleName.localeCompare(b.bundleName));
  return result;
}
export function saveApplicationCatalog(dir: string, value: ApplicationCatalog): void {
  if (value.request !== pendingApplicationCatalog(dir)) throw new Error('stale_catalog');
  value.updatedAt = Date.now();
  writeTextAtomic(dir + '/application-catalog.json', JSON.stringify(value));
}

export function addApplication(selected: string[], input: string, selfBundle: string): string[] {
  const name = input.trim();
  if (!name || /[\s,，;；]/.test(name) || parseApplications(name).length !== 1) {
    throw new Error('每次请输入一个完整包名，例如 com.example.app');
  }
  if (name === selfBundle) throw new Error('RevTether 始终经过 VPN，无需添加');
  if (selected.includes(name)) throw new Error('这个包名已经在名单中');
  if (selected.length >= MAX_APPLICATIONS) throw new Error('最多添加 63 个应用');
  return selected.concat(name);
}
export function loadApplicationCatalog(dir: string): ApplicationCatalog {
  try { return parseApplicationCatalog(fileIo.readTextSync(dir + '/application-catalog.json')); }
  catch (_) { return new ApplicationCatalog(); }
}

export function applicationChoices(catalog: SelectableApplication[], selected: string[],
  selfBundle: string, query: string, selectedOnly: boolean): SelectableApplication[] {
  const apps = catalog.filter((app: SelectableApplication) => app.bundleName !== selfBundle);
  const availableNames = new Set<string>(apps.map((app: SelectableApplication) => app.bundleName));
  const selectedNames = new Set<string>(selected);
  for (const name of selected) {
    if (name === selfBundle || availableNames.has(name)) continue;
    const app = new SelectableApplication(); app.bundleName = name; app.label = name; app.available = false;
    apps.push(app); availableNames.add(name);
  }
  const needle = query.trim().toLocaleLowerCase();
  return apps.filter((app: SelectableApplication) =>
    (!selectedOnly || selectedNames.has(app.bundleName)) &&
    (!needle || app.label.toLocaleLowerCase().includes(needle) || app.bundleName.toLowerCase().includes(needle)));
}

export function toggleApplication(selected: string[], name: string, selfBundle: string): string[] {
  if (name === selfBundle) return selected.slice();
  if (selected.includes(name)) return selected.filter((item: string) => item !== name);
  if (selected.length >= MAX_APPLICATIONS) throw new Error('最多选择 ' + MAX_APPLICATIONS + ' 个应用');
  return selected.concat(name);
}
