#!/usr/bin/env python3
"""Measure network quality inside the device without enabling its VPN."""
import argparse
import ipaddress
import json
import math
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def validate_value(value):
    if not isinstance(value, dict) or value.get('protocol') != 'stun_binding_v1':
        raise RuntimeError('Device returned no supported measurement')
    sent, received = value.get('sent'), value.get('received')
    if type(sent) is not int or type(received) is not int or not 1 <= sent <= 5 or not 0 <= received <= sent:
        raise RuntimeError('Invalid sample counts')
    loss, median = value.get('packet_loss_percent'), value.get('median_rtt_ms')
    if type(loss) not in (int, float) or not math.isfinite(loss) or abs(loss - (sent - received) * 100 / sent) > .01:
        raise RuntimeError('Invalid packet loss')
    if 'median_rtt_ms' not in value or (received == 0 and median is not None):
        raise RuntimeError('Invalid empty RTT')
    if received > 0 and (type(median) not in (int, float) or not math.isfinite(median) or not 0 <= median <= 15000):
        raise RuntimeError('Invalid RTT')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True, help='USB connect key shown by hdc list targets')
    parser.add_argument('--stun', action='append', required=True, help='IPv4 or domain:port; repeat up to four times')
    parser.add_argument('--hdc', default=os.environ.get('HDC', 'hdc'))
    parser.add_argument('--hdc-server', help='Address of an existing HDC server')
    parser.add_argument('--forward-host', default='127.0.0.1', help='Address where HDC binds local forwards')
    parser.add_argument('--bundle', default='com.linloir.hrevtether')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+', args.bundle):
        parser.error('Invalid bundle name')
    if not 1 <= len(args.stun) <= 4:
        parser.error('Supply one to four STUN servers')
    servers = []
    for target in args.stun:
        host, separator, port = target.rpartition(':')
        if not separator or len(host) > 253 or not re.fullmatch(r'[A-Za-z0-9.-]+', host):
            parser.error('STUN server must be an IPv4 address or domain followed by :port')
        if any(not label or len(label) > 63 or label.startswith('-') or label.endswith('-') for label in host.split('.')):
            parser.error('Invalid STUN hostname')
        if re.fullmatch(r'[0-9.]+', host):
            try:
                ipaddress.IPv4Address(host)
            except ValueError:
                parser.error('Invalid STUN IPv4 address')
        if not port.isdigit() or not 1 <= int(port) <= 65535:
            parser.error('STUN port must be between 1 and 65535')
        servers.append({'host': host, 'port': int(port)})

    hdc = [args.hdc]
    if args.hdc_server:
        hdc += ['-p', '-s', args.hdc_server]
    hdc += ['-t', args.serial]
    deadline = time.monotonic() + 25

    def run(*command, cleanup=False):
        timeout = 2 if cleanup else min(5, max(.1, deadline - time.monotonic()))
        result = subprocess.run(hdc + list(command), capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError('HDC command failed: ' + result.stderr.strip())
        return result.stdout

    mappings = [line.split() for line in run('fport', 'ls').splitlines()]
    used = {row[1] for row in mappings if len(row) == 4}
    for _ in range(10):
        with socket.socket() as reserve:
            reserve.bind(('0.0.0.0', 0))
            port = reserve.getsockname()[1]
        local = f'tcp:{port}'
        if local not in used:
            break
    else:
        raise RuntimeError('Could not allocate a free forwarding port')
    metadata = run('shell', f'bm dump -n {args.bundle}')
    try:
        bundle = json.loads(metadata[metadata.index('{'):])
        if bundle.get('name') != args.bundle or type(bundle.get('versionCode')) is not int:
            raise ValueError('Invalid app identity or version')
    except (ValueError, KeyError) as error:
        raise RuntimeError('A compatible network probe App must be installed') from error
    remote = 'tcp:41418' if bundle['versionCode'] >= 4 else 'tcp:31418'
    try:
        if 'Forwardport result:OK' not in run('fport', local, remote):
            raise RuntimeError('HDC did not confirm forwarding')
        request_id = str(uuid.uuid4())
        encoded = json.dumps({'request_id': request_id, 'servers': servers}, separators=(',', ':'))
        command = f"aa start -b {args.bundle} -a ProbeAbility --ps request '{encoded}'"
        if 'start ability successfully' not in run('shell', command):
            raise RuntimeError('ProbeAbility could not be started; install a compatible App')
        host = f'[{args.forward_host}]' if ':' in args.forward_host else args.forward_host
        url = f'http://{host}:{port}/v1/probe/{request_id}'
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        while time.monotonic() < deadline:
            try:
                with opener.open(url, timeout=min(1, max(.1, deadline - time.monotonic()))) as response:
                    body = response.read(32769)
                    if len(body) > 32768:
                        raise RuntimeError('Probe response exceeds size limit')
                    if response.status == 200:
                        reply = json.loads(body)
                        if reply.get('request_id') != request_id:
                            raise RuntimeError('Probe request ID mismatch')
                        if reply.get('error'):
                            raise RuntimeError('Device probe failed: ' + str(reply['error']))
                        validate_value(reply.get('value'))
                        print(json.dumps(reply, ensure_ascii=False))
                        return
                    if response.status != 202:
                        raise RuntimeError(f'Unexpected HTTP status {response.status}')
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                pass
            time.sleep(.15)
        raise RuntimeError('Probe timed out; check the device, HDC forward bind address, and concurrent probe callers')
    finally:
        try:
            rows = [line.split() for line in run('fport', 'ls', cleanup=True).splitlines()]
            if [args.serial, local, remote, '[Forward]'] in rows:
                run('fport', 'rm', local, remote, cleanup=True)
        except (RuntimeError, subprocess.TimeoutExpired):
            print(f'Could not confirm cleanup of {local} {remote}', file=sys.stderr)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
