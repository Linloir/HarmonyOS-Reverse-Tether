import { validRequestId } from '../probe/NetworkProbe';
import { validIPv4, validIPv6 } from '../common/NetworkAddress';

export class ConfigureRequest {
  request_id: string = '';
  port?: number;
  dns?: string;
  reloadSettings?: boolean;
}

export function validDNS(value: string): boolean {
  if (value === '') return true;
  return validIPv4(value) || validIPv6(value);
}

export function parseConfigure(text: string): ConfigureRequest {
  const request = JSON.parse(text) as ConfigureRequest;
  if (!request || !validRequestId(request.request_id) ||
      Object.keys(request).some((key: string) => !['request_id', 'port', 'dns', 'reloadSettings'].includes(key)) ||
      (request.port !== undefined && (!Number.isInteger(request.port) || request.port < 1024 || request.port > 65535)) ||
      (request.dns !== undefined && (typeof request.dns !== 'string' || !validDNS(request.dns))) ||
      (request.reloadSettings !== undefined && typeof request.reloadSettings !== 'boolean') ||
      (request.port === undefined && request.dns === undefined && request.reloadSettings !== true)) {
    throw new Error('invalid_request');
  }
  return request;
}

export function parseStop(text: string): string {
  const request = JSON.parse(text) as ConfigureRequest;
  if (!request || !validRequestId(request.request_id) || Object.keys(request).length !== 1) {
    throw new Error('invalid_request');
  }
  return request.request_id;
}

export function asciiJSON(value: Object): string {
  return JSON.stringify(value).replace(/[\u0080-\uffff]/g,
    (character: string) => '\\u' + character.charCodeAt(0).toString(16).padStart(4, '0'));
}
