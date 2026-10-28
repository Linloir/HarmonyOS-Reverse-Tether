import { http } from '@kit.NetworkKit';
import { CONTROL_PORT } from './State';
import { ensureControlToken } from './ControlAuth';

export async function controlRequest(dir: string, path: string, body?: string): Promise<string> {
  const client = http.createHttp();
  try {
    const response = await client.request('http://127.0.0.1:' + CONTROL_PORT + path, {
      method: body === undefined ? http.RequestMethod.GET : http.RequestMethod.POST,
      header: {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + ensureControlToken(dir)},
      extraData: body, connectTimeout: 3000, readTimeout: 3000, usingCache: false,
      expectDataType: http.HttpDataType.STRING
    });
    if (response.responseCode !== 200 && response.responseCode !== 202) throw new Error('control_' + response.responseCode);
    return String(response.result);
  } finally { client.destroy(); }
}
