import { fileIo } from '@kit.CoreFileKit';
import { PRIVACY_VERSION } from './PrivacyContent';

class ConsentRecord {
  version: string = PRIVACY_VERSION;
  acceptedAt: number = Date.now();
}

// Read the persisted decision at every network entry point, including abilities
// started by HDC. A missing, outdated or unreadable record never grants consent.
export function hasPrivacyConsent(dir: string): boolean {
  try {
    const record = JSON.parse(fileIo.readTextSync(dir + '/privacy-consent.json')) as ConsentRecord;
    return record.version === PRIVACY_VERSION && typeof record.acceptedAt === 'number' &&
      Number.isFinite(record.acceptedAt) && record.acceptedAt > 0;
  } catch (_) {
    return false;
  }
}

export function acceptPrivacy(dir: string): void {
  const path = dir + '/privacy-consent.json';
  const file = fileIo.openSync(path + '.tmp', fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, JSON.stringify(new ConsentRecord()));
  } finally {
    fileIo.closeSync(file);
  }
  fileIo.renameSync(path + '.tmp', path);
}
