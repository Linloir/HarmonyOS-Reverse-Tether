#!/usr/bin/env python3
"""Temporary, loopback-only proof page for a real phone browser over HDC rport."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=31420)
parser.add_argument("--nonce", required=True)
args = parser.parse_args()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/" + args.nonce:
            self.send_error(404)
            return
        try:
            with urllib.request.urlopen("https://www.example.com/", timeout=10) as response:
                data = response.read(65536)
                proof = {"status": response.status, "sha256": hashlib.sha256(data).hexdigest(),
                         "bytes": len(data), "userAgent": self.headers.get("User-Agent", "")}
            body = ("<!doctype html><meta charset='utf-8'><meta name='viewport' content='width=device-width'>"
                    "<h1>USB 通道正常</h1><p>设备浏览器已访问电脑上的测试服务，服务端 HTTPS 请求成功。</p>"
                    "<p>此结果仅验证传输通道。验证 VPN 时，还应从设备应用直接发起联网请求。</p>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            print(json.dumps({"event": "PHONE_BROWSER_USB_OK", **proof}, ensure_ascii=False), flush=True)
        except Exception as error:
            print(json.dumps({"event": "PROOF_FAILED", "error": str(error)}), flush=True)
            self.send_error(502)


HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
