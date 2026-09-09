#!/usr/bin/env python3
"""Serve a finite browser upload/download check on the connected computer."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import secrets
from urllib.parse import urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bind', default='127.0.0.1')
parser.add_argument('--port', type=int, default=31421)
args = parser.parse_args()
token = secrets.token_hex(12)
download_size = 8 * 1024 * 1024
upload_size = 1024 * 1024
block = bytes(range(256)) * 4096
page = r'''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<title>USB transfer verification</title>
<style>body{font:20px system-ui;padding:32px;line-height:1.6;background:#f4f7f6;color:#163b34}pre{white-space:pre-wrap}</style>
<h1>USB transfer verification</h1><pre id="result">Running...</pre>
<script>
(async () => {
  const out = document.getElementById('result');
  try {
    const start = performance.now();
    const response = await fetch('./payload?t=' + Date.now(), {cache:'no-store'});
    if (!response.ok) throw new Error('Download HTTP ' + response.status);
    const data = new Uint8Array(await response.arrayBuffer());
    if (data.length !== 8388608) throw new Error('Wrong download length: ' + data.length);
    for (let i=0; i<data.length; i++) if (data[i] !== (i & 255)) throw new Error('Corrupt byte at ' + i);
    const seconds = ((performance.now()-start)/1000).toFixed(2);
    out.textContent = 'Download: 8 MiB verified byte for byte in ' + seconds + ' s.\n';
    const upload = data.slice(0, 1048576);
    const sent = await fetch('./upload', {method:'POST', body:upload, cache:'no-store'});
    const result = await sent.json();
    if (!sent.ok || !result.verified || result.bytes !== upload.length) throw new Error('Upload verification failed');
    out.textContent += 'Upload: 1 MiB verified byte for byte.\nPASS';
  } catch (error) { out.textContent += '\nFAIL: ' + error; }
})();
</script>'''.encode()


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, content, content_type='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(content)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == f'/{token}/':
            self.reply(200, page, 'text/html; charset=utf-8')
        elif path == f'/{token}/payload':
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(download_size))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            for _ in range(download_size // len(block)):
                self.wfile.write(block)
            print(json.dumps({'event':'download_sent', 'bytes':download_size}), flush=True)
        else:
            self.reply(404, b'{}')

    def do_POST(self):
        if urlsplit(self.path).path != f'/{token}/upload':
            self.reply(404, b'{}')
            return
        if self.headers.get('Content-Length') != str(upload_size):
            self.reply(400, b'{"error":"unexpected length"}')
            return
        self.connection.settimeout(30)
        payload = self.rfile.read(upload_size)
        verified = payload == block
        result = {'event':'upload_received', 'verified':verified, 'bytes':len(payload)}
        print(json.dumps(result), flush=True)
        self.reply(200 if verified else 400, json.dumps(result).encode())


with ThreadingHTTPServer((args.bind, args.port), Handler) as server:
    print(json.dumps({'event':'ready', 'url':f'http://{args.bind}:{args.port}/{token}/'}), flush=True)
    server.serve_forever()
