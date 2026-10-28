"""Authenticated, bounded access to an already-running RevTether VPN.

Nothing in this module starts an ability or changes the device's foreground.
Only the exact temporary HDC forward created here is removed on exit.
"""
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import stat

CONTROL_PORT = 41420
MAX_BODY = 32768
TOKEN_PATTERN = re.compile(r'[0-9a-fA-F]{32,128}')


class ControlError(RuntimeError):
    def __init__(self, message, status=None, code=None):
        super().__init__(message)
        self.status = status
        self.code = code


def read_token(path):
    path = Path(path)
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or (os.name != 'nt' and info.st_mode & 0o077):
            raise ControlError('Control token must be a regular file accessible only to its owner')
        if info.st_size > 256:
            raise ControlError('Invalid control token file')
        token = os.read(fd, 257).decode('ascii').strip()
    finally:
        os.close(fd)
    if not TOKEN_PATTERN.fullmatch(token):
        raise ControlError('Invalid control token file')
    return token


def ensure_token(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    except FileExistsError:
        return read_token(path)
    token = secrets.token_hex(32)
    with os.fdopen(fd, 'w') as output:
        output.write(token + '\n')
    return token


class ForwardedControl:
    def __init__(self, run, serial, token=None, forward_host='127.0.0.1', cleanup_run=None):
        ipaddress.ip_address(forward_host)
        self.run = run
        self.cleanup_run = cleanup_run or run
        self.serial = serial
        self.token = token
        self.forward_host = forward_host
        self.local = None
        self.remote = f'tcp:{CONTROL_PORT}'
        self.port = None

    def _rules(self):
        return [line.split() for line in self.run('fport', 'ls').splitlines()]

    def __enter__(self):
        used = {row[1] for row in self._rules() if len(row) == 4}
        for _ in range(10):
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            local = f'tcp:{port}'
            if local not in used:
                break
        else:
            raise ControlError('No free HDC control forwarding port')
        # Remember the attempted exact mapping before invoking HDC. A missing
        # receipt is not permission to retry or delete a differently owned rule.
        self.local, self.port = local, port
        try:
            result = self.run('fport', local, self.remote)
            expected = [self.serial, local, self.remote, '[Forward]']
            if 'Forwardport result:OK' not in result or expected not in self._rules():
                raise ControlError('HDC did not confirm the VPN control forward')
        except BaseException:
            self.close()
            raise
        return self

    def close(self):
        if self.local is None:
            return
        local, self.local = self.local, None
        rows = [line.split() for line in self.cleanup_run('fport', 'ls').splitlines()]
        if [self.serial, local, self.remote, '[Forward]'] in rows:
            self.cleanup_run('fport', 'rm', local, self.remote)

    def __exit__(self, kind, error, traceback):
        try:
            self.close()
        except Exception:
            if error is None:
                raise ControlError('Could not confirm cleanup of the VPN control forward')

    def request(self, method, path, body=None, timeout=3):
        if method not in ('GET', 'POST') or not re.fullmatch(r'/v1/(status|applications(?:/request)?|probe(?:/[0-9a-fA-F-]{36})?|configure|stop)', path):
            raise ValueError('Invalid VPN control request')
        if path != '/v1/status' and not self.token:
            raise ControlError('VPN control is not paired; supply its private token file', code='pairing_required')
        encoded = json.dumps(body, separators=(',', ':')).encode() if body is not None else None
        if encoded is not None and len(encoded) > (131072 if path == '/v1/applications' else MAX_BODY):
            raise ValueError('VPN control request exceeds size limit')
        headers = {'Accept': 'application/json', 'Connection': 'close'}
        if encoded is not None:
            headers['Content-Type'] = 'application/json'
        if self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        connection = http.client.HTTPConnection(self.forward_host, self.port, timeout=timeout)
        try:
            connection.request(method, path, body=encoded, headers=headers)
            response = connection.getresponse()
            data = response.read(MAX_BODY + 1)
            if len(data) > MAX_BODY:
                raise ControlError('VPN control response exceeds size limit')
            try:
                reply = json.loads(data)
            except (ValueError, UnicodeError) as error:
                raise ControlError('Invalid VPN control response') from error
            if not isinstance(reply, dict):
                raise ControlError('Invalid VPN control response')
            if response.status not in (200, 202):
                code = reply.get('error')
                safe = code if isinstance(code, str) and re.fullmatch(r'[a-z_]{1,80}', code) else 'request_failed'
                if response.status == 401:
                    safe = 'pairing_required'
                raise ControlError(f'VPN control: {safe} (HTTP {response.status})', response.status, safe)
            return response.status, reply
        finally:
            connection.close()
