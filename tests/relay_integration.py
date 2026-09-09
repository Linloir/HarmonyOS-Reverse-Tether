#!/usr/bin/env python3
"""Test a running relay or an HDC fport/rport USB loop using real sockets."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
import re
import socket
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=31417)
parser.add_argument("--probe", required=True)
args = parser.parse_args()


def connect():
    stream = socket.create_connection((args.host, args.port), timeout=10)
    stream.settimeout(10)
    data = b""
    while len(data) < 4:
        chunk = stream.recv(4 - len(data))
        assert chunk, "Relay failed handshake"
        data += chunk
    return stream


def handshake(_):
    with connect():
        return True


with ThreadPoolExecutor(max_workers=8) as pool:
    count = sum(pool.map(handshake, range(40)))
print(json.dumps({"test": "concurrent_handshakes", "passed": count, "expected": 40}), flush=True)

bad_frames = [bytes([0x60, 0, 0, 20]), bytes([0x45, 0, 0, 0]), bytes([0x4f, 0, 0, 20]),
              bytes([0x45, 0, 0, 20, 0, 0, 0, 0, 64, 6]) + bytes(10)]
for frame in bad_frames:
    with connect() as stream:
        stream.sendall(frame)
        try:
            result = stream.recv(1)
            assert result == b"", "Malformed client was not closed"
        except ConnectionResetError:
            pass
    # The entire service must still be usable after each malformed client.
    with connect():
        pass
print(json.dumps({"test": "malformed_client_isolation", "passed": len(bad_frames)}), flush=True)

env = dict(os.environ, TETHER_PROBE_RELAY_IP=args.host)
dns = subprocess.run([args.probe, str(args.port), "dns", "10.0.0.3", "example.com"], env=env, capture_output=True, text=True, timeout=20)
assert dns.returncode == 0, dns.stdout + dns.stderr
print(dns.stdout.strip(), flush=True)
ip = re.search(r"DNS_OK example\.com ([0-9.]+)", dns.stdout).group(1)
http = subprocess.run([args.probe, str(args.port), "http", ip, "80", "example.com", "/"], env=env, capture_output=True, text=True, timeout=30)
assert http.returncode == 0 and "HTTP/1.1 200 OK" in http.stdout and "Example Domain" in http.stdout, http.stdout + http.stderr
print("\n".join(http.stdout.splitlines()[:2]), flush=True)
print(json.dumps({"result": "PASS", "transport": f"{args.host}:{args.port}", "tcp_http": 200, "virtual_dns": "10.0.0.3"}), flush=True)
