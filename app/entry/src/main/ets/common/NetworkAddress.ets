export function validIPv4(value: string): boolean {
  const parts = value.split('.');
  return parts.length === 4 && parts.every((part: string) => /^\d{1,3}$/.test(part) && Number(part) <= 255);
}

export function expandedIPv6(value: string): string {
  let address = value.toLowerCase();
  if (address.includes('.')) {
    const colon = address.lastIndexOf(':');
    const tail = address.substring(colon + 1);
    if (!validIPv4(tail)) return '';
    const parts = tail.split('.').map((part: string) => Number(part));
    address = address.substring(0, colon + 1) + ((parts[0] << 8) | parts[1]).toString(16) + ':' +
      ((parts[2] << 8) | parts[3]).toString(16);
  }
  if (!address.includes(':') || !/^[0-9a-f:]+$/.test(address)) return '';
  const halves = address.split('::');
  if (halves.length > 2) return '';
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const parts = left.concat(right);
  if (parts.some((part: string) => !/^[0-9a-f]{1,4}$/.test(part)) ||
      (halves.length === 1 && parts.length !== 8) || (halves.length === 2 && parts.length >= 8)) return '';
  const expanded = left.slice();
  if (halves.length === 2) {
    for (let index = parts.length; index < 8; ++index) expanded.push('0');
    for (const part of right) expanded.push(part);
  }
  return expanded.map((part: string) => part.padStart(4, '0')).join(':');
}

export function validIPv6(value: string): boolean { return expandedIPv6(value).length > 0; }
export function sameAddress(first: string, second: string): boolean {
  return first === second || (validIPv6(first) && expandedIPv6(first) === expandedIPv6(second));
}
