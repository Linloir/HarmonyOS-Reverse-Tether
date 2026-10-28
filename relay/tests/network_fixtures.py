#!/usr/bin/env python3
"""Isolated dual-stack TCP/HTTP/UDP/STUN/DNS fixtures (Python standard library)."""
import argparse
import hashlib
import http.server
import ipaddress
import json
import signal
import socket
import socketserver
import struct
import threading

SMALL_BODY = b"RevTether fixture ok\n"
LARGE_BODY = bytes(range(256)) * 4096
DNS_NAME = "revtether.test"
STUN_COOKIE = 0x2112A442


def read_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        part = connection.recv(length - len(result))
        if not part:
            raise EOFError("connection closed during request")
        result.extend(part)
    return bytes(result)


def dns_response(query, answer_v4, answer_v6):
    """Answer one ordinary A/AAAA question, preserving the question and ID."""
    if len(query) < 12:
        return None
    identifier, flags, count = struct.unpack("!HHH", query[:6])
    if flags & 0x8000 or count != 1:
        return None
    offset = 12
    while offset < len(query):
        length = query[offset]
        offset += 1
        if length == 0:
            break
        if length > 63 or offset + length > len(query):
            return None
        offset += length
    else:
        return None
    if offset + 4 > len(query):
        return None
    qtype, qclass = struct.unpack("!HH", query[offset:offset + 4])
    question = query[12:offset + 4]
    address = answer_v4 if qtype == 1 else answer_v6 if qtype == 28 else None
    answer = b""
    if qclass == 1 and address:
        packed = ipaddress.ip_address(address).packed
        answer = struct.pack("!HHHIH", 0xC00C, qtype, 1, 30, len(packed)) + packed
    header = struct.pack("!HHHHHH", identifier, 0x8080 | (flags & 0x0100), 1,
                         int(bool(answer)), 0, 0)
    return header + question + answer


def stun_response(request, peer):
    if len(request) < 20:
        return None
    kind, length, cookie = struct.unpack("!HHI", request[:8])
    if kind != 1 or cookie != STUN_COOKIE or length + 20 != len(request):
        return None
    transaction = request[8:20]
    address = ipaddress.ip_address(peer[0].split("%", 1)[0])
    mask = struct.pack("!I", cookie) + transaction
    encoded_address = bytes(a ^ b for a, b in zip(address.packed, mask))
    value = struct.pack("!BBH", 0, 2 if address.version == 6 else 1,
                        peer[1] ^ (cookie >> 16)) + encoded_address
    attribute = struct.pack("!HH", 0x0020, len(value)) + value
    return struct.pack("!HHI", 0x0101, len(attribute), cookie) + transaction + attribute


class EchoTcp(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        try:
            while True:
                data = self.request.recv(65535)
                if not data:
                    return
                self.request.sendall(data)
        except (TimeoutError, ConnectionError, OSError):
            return


class EchoUdp(socketserver.BaseRequestHandler):
    def handle(self):
        data, connection = self.request
        connection.sendto(data, self.client_address)


class StunUdp(socketserver.BaseRequestHandler):
    def handle(self):
        data, connection = self.request
        response = stun_response(data, self.client_address)
        if response:
            connection.sendto(response, self.client_address)


class DnsUdp(socketserver.BaseRequestHandler):
    def handle(self):
        data, connection = self.request
        response = dns_response(data, *self.server.dns_answers)
        if response:
            connection.sendto(response, self.client_address)


class DnsTcp(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        try:
            while True:
                size = struct.unpack("!H", read_exact(self.request, 2))[0]
                response = dns_response(read_exact(self.request, size), *self.server.dns_answers)
                if not response:
                    return
                self.request.sendall(struct.pack("!H", len(response)) + response)
        except (EOFError, TimeoutError, ConnectionError, OSError):
            return


class Http(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/small", "/large"):
            self.send_error(404)
            return
        body = LARGE_BODY if self.path == "/large" else SMALL_BODY
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-SHA256", hashlib.sha256(body).hexdigest())
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (ConnectionError, OSError):
            pass

    def log_message(self, *_args):
        pass


class Fixtures:
    def __init__(self, bind_v4="127.0.0.1", bind_v6="::1", answer_v4=None, answer_v6=None):
        self.servers = []
        self.workers = []
        answers = (answer_v4 or bind_v4, answer_v6 or bind_v6)
        self.info = {
            "schema": "revtether-network-fixtures-v1",
            "dns_name": DNS_NAME,
            "dns_answers": {"A": answers[0], "AAAA": answers[1]},
            "http_bodies": {
                "/small": {"bytes": len(SMALL_BODY), "sha256": hashlib.sha256(SMALL_BODY).hexdigest()},
                "/large": {"bytes": len(LARGE_BODY), "sha256": hashlib.sha256(LARGE_BODY).hexdigest()},
            },
            "families": {},
        }
        try:
            for family, label, address in ((socket.AF_INET, "ipv4", bind_v4),
                                           (socket.AF_INET6, "ipv6", bind_v6)):
                endpoints = {"address": address}
                for name, base, handler in (
                    ("tcp_echo", socketserver.ThreadingTCPServer, EchoTcp),
                    ("http", http.server.ThreadingHTTPServer, Http),
                    ("udp_echo", socketserver.ThreadingUDPServer, EchoUdp),
                    ("stun", socketserver.ThreadingUDPServer, StunUdp),
                    ("dns_tcp", socketserver.ThreadingTCPServer, DnsTcp),
                    ("dns_udp", socketserver.ThreadingUDPServer, DnsUdp),
                ):
                    cls = type("FixtureServer", (base,), {"address_family": family,
                               "daemon_threads": True, "allow_reuse_address": True})
                    port = endpoints.get("dns_tcp", 0) if name == "dns_udp" else 0
                    server = cls((address, port), handler)
                    server.dns_answers = answers
                    self.servers.append(server)
                    worker = threading.Thread(target=server.serve_forever, daemon=True)
                    worker.start()
                    self.workers.append(worker)
                    endpoints[name] = server.server_address[1]
                self.info["families"][label] = endpoints
        except BaseException:
            self.close()
            raise

    def close(self):
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for worker in self.workers:
            worker.join(timeout=2)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve-fixtures", action="store_true", required=True)
    parser.add_argument("--bind-v4", default="127.0.0.1")
    parser.add_argument("--bind-v6", default="::1")
    parser.add_argument("--answer-v4")
    parser.add_argument("--answer-v6")
    args = parser.parse_args()
    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_args: stop.set())
    signal.signal(signal.SIGTERM, lambda *_args: stop.set())
    with Fixtures(args.bind_v4, args.bind_v6, args.answer_v4, args.answer_v6) as fixtures:
        print(json.dumps(fixtures.info), flush=True)
        stop.wait()


if __name__ == "__main__":
    main()
