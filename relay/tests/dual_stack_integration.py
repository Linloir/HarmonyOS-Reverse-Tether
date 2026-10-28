#!/usr/bin/env python3
"""Self-contained real-socket relay tests, no Internet/device access required."""
import argparse
import contextlib
from concurrent.futures import ThreadPoolExecutor
import ipaddress
import json
import socket
import struct
import subprocess
import tempfile
import threading
import time

from network_fixtures import Fixtures, dns_response, STUN_COOKIE

SRC4, SRC6 = "10.0.0.2", "fd00:7265:7674::2"


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def pseudo(src, dst, protocol, length):
    src, dst = ipaddress.ip_address(src), ipaddress.ip_address(dst)
    if src.version == 6:
        return src.packed + dst.packed + struct.pack("!I3xB", length, protocol)
    return src.packed + dst.packed + struct.pack("!BBH", 0, protocol, length)


def ip_packet(src, dst, protocol, transport):
    src_ip, dst_ip = ipaddress.ip_address(src), ipaddress.ip_address(dst)
    if src_ip.version == 6:
        return struct.pack("!IHBB16s16s", 6 << 28, len(transport), protocol, 64,
                           src_ip.packed, dst_ip.packed) + transport
    header = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(transport), 0, 0, 64,
                         protocol, 0, src_ip.packed, dst_ip.packed)
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    return header + transport


def udp(src, dst, port, body, source_port=43210):
    transport = struct.pack("!HHHH", source_port, port, 8 + len(body), 0) + body
    value = checksum(pseudo(src, dst, 17, len(transport)) + transport) or 65535
    return ip_packet(src, dst, 17, transport[:6] + struct.pack("!H", value) + transport[8:])


def tcp(src, dst, port, seq, ack, flags, body=b"", options=b""):
    header = struct.pack("!HHIIHHHH", 43211, port, seq, ack,
                         ((20 + len(options)) // 4 << 12) | flags, 65535, 0, 0) + options
    transport = header + body
    value = checksum(pseudo(src, dst, 6, len(transport)) + transport)
    transport = transport[:16] + struct.pack("!H", value) + transport[18:]
    return ip_packet(src, dst, 6, transport)


def exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise AssertionError("unexpected tunnel EOF")
        data += chunk
    return data


def receive(sock):
    first = exact(sock, 1)
    if first[0] >> 4 == 6:
        header = first + exact(sock, 39)
        length, protocol = struct.unpack("!HB", header[4:7])
        src, dst = str(ipaddress.ip_address(header[8:24])), str(ipaddress.ip_address(header[24:40]))
    else:
        header = first + exact(sock, (first[0] & 15) * 4 - 1)
        length, protocol = struct.unpack("!H", header[2:4])[0] - len(header), header[9]
        src, dst = str(ipaddress.ip_address(header[12:16])), str(ipaddress.ip_address(header[16:20]))
        assert checksum(header) == 0, "bad IPv4 checksum"
    transport = exact(sock, length)
    assert checksum(pseudo(src, dst, protocol, length) + transport) == 0, "bad transport checksum"
    return src, dst, protocol, transport, len(header) + length


@contextlib.contextmanager
def echo_server(family, kind):
    with socket.socket(family, kind) as server:
        server.bind(("::1" if family == socket.AF_INET6 else "127.0.0.1", 0))
        server.settimeout(5)
        if kind == socket.SOCK_STREAM:
            server.listen(1)
        errors = []

        def run():
            try:
                if kind == socket.SOCK_DGRAM:
                    body, address = server.recvfrom(65535)
                    server.sendto(body[::-1], address)
                else:
                    with server.accept()[0] as connection:
                        while True:
                            body = connection.recv(65535)
                            if not body:
                                break
                            connection.sendall(body)
            except (OSError, TimeoutError) as error:
                errors.append(str(error))

        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        yield server.getsockname()[1]
        worker.join(timeout=1)
        assert not errors, errors


@contextlib.contextmanager
def relay(binary, policy, dns="::1"):
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen([binary, "--port", str(port), "--dns", dns, "--ipv6", policy],
                                   stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    tunnel = socket.create_connection(("127.0.0.1", port), timeout=2)
                    break
                except OSError:
                    if process.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise AssertionError(log.read().decode())
                    time.sleep(0.02)
            with tunnel:
                tunnel.settimeout(3)
                identifier = struct.unpack("!I", exact(tunnel, 4))[0]
                assert identifier >> 24 == 0xA5
                assert (identifier >> 22) & 3 == {"inherit": 0, "off": 1, "on": 2}[policy]
                assert identifier & (1 << 21)
                yield tunnel
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def check_udp(tunnel, family):
    src, dst = (SRC6, "::1") if family == socket.AF_INET6 else (SRC4, "127.0.0.1")
    with echo_server(family, socket.SOCK_DGRAM) as port:
        payload = b"dual-stack-udp-odd"
        tunnel.sendall(udp(src, dst, port, payload))
        response_src, response_dst, protocol, body, _ = receive(tunnel)
        assert (response_src, response_dst, protocol) == (dst, src, 17)
        assert body[8:] == payload[::-1]


def exchange_tcp(tunnel, src, dst, port, payload, expected):
    seq = 12345
    # Advertise an MSS lower than the MTU to verify both bounds are honored.
    tunnel.sendall(tcp(src, dst, port, seq, 0, 2, options=struct.pack("!BBH", 2, 4, 1000)))
    _, _, protocol, body, _ = receive(tunnel)
    assert protocol == 6 and body[13] & 0x12 == 0x12
    remote_seq, remote_ack = struct.unpack("!II", body[4:12])
    assert remote_ack == seq + 1
    ack, seq = remote_seq + 1, seq + 1
    tunnel.sendall(tcp(src, dst, port, seq, ack, 0x10))
    for offset in range(0, len(payload), 1000):
        piece = payload[offset:offset + 1000]
        tunnel.sendall(tcp(src, dst, port, seq + offset, ack, 0x18, piece))
    seq += len(payload)
    received = b""
    while len(received) < len(expected):
        response_src, response_dst, protocol, body, frame_length = receive(tunnel)
        assert (response_src, response_dst, protocol) == (dst, src, 6)
        response_seq = struct.unpack("!I", body[4:8])[0]
        data = body[(body[12] >> 4) * 4:]
        assert len(data) <= 1000 and frame_length <= 1500
        if data:
            assert response_seq == ack
            received += data
            ack += len(data)
            tunnel.sendall(tcp(src, dst, port, seq, ack, 0x10))
    assert received == expected
    tunnel.sendall(tcp(src, dst, port, seq, ack, 0x14))


def check_tcp(tunnel, family):
    src, dst = (SRC6, "::1") if family == socket.AF_INET6 else (SRC4, "127.0.0.1")
    with echo_server(family, socket.SOCK_STREAM) as port:
        payload = bytes(range(251)) * 25
        exchange_tcp(tunnel, src, dst, port, payload, payload)


def check_client_isolation(tunnel):
    endpoint = tunnel.getpeername()

    def handshake(_):
        with socket.create_connection(endpoint, timeout=3) as client:
            return struct.unpack("!I", exact(client, 4))[0] >> 24 == 0xA5

    with ThreadPoolExecutor(max_workers=8) as workers:
        assert all(workers.map(handshake, range(40)))
    malformed = [b"\x70", b"\x45\0\0\0", b"\x60\0\0\0\0\0",
                 ip_packet(SRC6, "::1", 6, bytes(20))]
    for packet in malformed:
        with socket.create_connection(endpoint, timeout=3) as client:
            exact(client, 4)
            client.sendall(packet)
            try:
                assert client.recv(1) == b"", "invalid client was not closed"
            except ConnectionResetError:
                pass
        assert handshake(0)
    check_udp(tunnel, socket.AF_INET6)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    checks = []
    for flag, expected in (("--network-quality-capabilities", "root-listener-v1"),
                           ("--ipv6-capabilities", "ipv6-policy-v1")):
        result = subprocess.run([args.binary, flag], capture_output=True, text=True,
                                check=True, timeout=3)
        assert result.stdout.strip() == expected
    checks.append("independent_capability_queries")
    for policy in ("inherit", "on"):
        with relay(args.binary, policy) as tunnel:
            if policy == "inherit":
                check_client_isolation(tunnel)
                checks.append("concurrent_handshakes_malformed_client_isolation")
            for family, label in ((socket.AF_INET, "ipv4"), (socket.AF_INET6, "ipv6")):
                check_udp(tunnel, family)
                check_tcp(tunnel, family)
                checks.append(f"{policy}:{label}:tcp_udp_checksums_mss")
    with relay(args.binary, "off") as tunnel:
        tunnel.sendall(udp(SRC6, "::1", 9, b"must-be-dropped"))
        tunnel.settimeout(0.2)
        try:
            tunnel.recv(1)
            raise AssertionError("disabled IPv6 produced data or closed the tunnel")
        except socket.timeout:
            pass
        tunnel.settimeout(3)
        check_udp(tunnel, socket.AF_INET)
        checks.append("off:ipv6_drop_ipv4_survives")
    # Real A/AAAA answers over UDP and TCP, crossing both upstream/client families.
    with Fixtures() as fixtures:
        for upstream_label in ("ipv4", "ipv6"):
            endpoint = fixtures.info["families"][upstream_label]
            dns = (f"[{endpoint['address']}]:{endpoint['dns_tcp']}" if upstream_label == "ipv6"
                   else f"{endpoint['address']}:{endpoint['dns_tcp']}")
            with relay(args.binary, "inherit", dns) as tunnel:
                for client_src, virtual_dst in ((SRC4, "10.0.0.3"), (SRC6, "fd00:7265:7674::3")):
                    for qtype in (1, 28):
                        query = (b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
                                 b"\x09revtether\x04test\x00" + struct.pack("!HH", qtype, 1))
                        expected = dns_response(query, "127.0.0.1", "::1")
                        tunnel.sendall(udp(client_src, virtual_dst, 53, query))
                        response_src, response_dst, protocol, body, _ = receive(tunnel)
                        assert (response_src, response_dst, protocol) == (virtual_dst, client_src, 17)
                        assert body[8:] == expected
                        exchange_tcp(tunnel, client_src, virtual_dst, 53,
                                     struct.pack("!H", len(query)) + query,
                                     struct.pack("!H", len(expected)) + expected)
                    checks.append(f"virtual_dns_A_AAAA_UDP_TCP:{client_src}->{upstream_label}")
        # A valid XOR-MAPPED-ADDRESS response proves IPv6 UDP works for the phone probe.
        endpoint = fixtures.info["families"]["ipv6"]
        with relay(args.binary, "on") as tunnel:
            transaction = bytes(range(12))
            query = struct.pack("!HHI", 1, 0, STUN_COOKIE) + transaction
            tunnel.sendall(udp(SRC6, "::1", endpoint["stun"], query))
            _, _, protocol, body, _ = receive(tunnel)
            response = body[8:]
            assert protocol == 17 and response[:2] == b"\x01\x01"
            assert response[8:20] == transaction
            assert response[20:24] == struct.pack("!HH", 0x0020, 20)
            assert response[25] == 2
            mask = struct.pack("!I", STUN_COOKIE) + transaction
            mapped_ip = bytes(a ^ b for a, b in zip(response[28:], mask))
            assert str(ipaddress.ip_address(mapped_ip)) == "::1"
            checks.append("ipv6_stun_binding")
    print(json.dumps({"result": "PASS", "checks": checks}, indent=2))


if __name__ == "__main__":
    main()
