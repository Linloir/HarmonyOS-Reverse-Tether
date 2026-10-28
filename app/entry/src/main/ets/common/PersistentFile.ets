import { fileIo } from '@kit.CoreFileKit';

// Readers in the UI and VPN processes must see either the old or the new file.
export function writeTextAtomic(path: string, content: string): void {
  const temporary = path + '.tmp';
  const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(file.fd, content); }
  finally { fileIo.closeSync(file); }
  fileIo.renameSync(temporary, path);
}
