#!/usr/bin/env python3
"""Share a computer's network with a HarmonyOS device over USB."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid

from application_catalog import sync_applications
from tether_control import ForwardedControl, ensure_token, read_token

DEFAULT_BUNDLE = "com.linloir.hrevtether"
DEVICE_PORT = 41417


class Hdc:
    def __init__(self, args):
        self.prefix = [args.hdc]
        if args.hdc_server:
            self.prefix += ["-p", "-s", args.hdc_server]
        self.prefix += ["-t", args.serial]
        self.bundle = args.bundle
        self.device_port = args.device_port
        self.secrets = []

    def run(self, *command):
        try:
            result = subprocess.run(self.prefix + list(command), capture_output=True, text=True, timeout=20)
        except subprocess.TimeoutExpired:
            # TimeoutExpired includes argv, which may contain a control token.
            raise RuntimeError('HDC command timed out after 20 seconds') from None
        output = result.stdout + result.stderr
        # HDC can return exit status 0 for device-side failure.
        if result.returncode or re.search(r"\[Fail\]|error:|install failed|failed to", output, re.I):
            for secret in self.secrets:
                output = output.replace(secret, '<redacted>')
            raise RuntimeError(output.strip() or f"hdc exited {result.returncode}")
        return output.strip()

    def shell(self, *command):
        return self.run("shell", shlex.join(command))

    def connected(self, serial):
        text = self.run("list", "targets", "-v")
        return any(line.split()[:3] == [serial, "USB", "Connected"] for line in text.splitlines())

    def rules(self):
        return self.run("fport", "ls")

    def reverse(self, serial, port):
        rule = f"tcp:{self.device_port} tcp:{port}"
        for line in self.rules().splitlines():
            fields = line.split()
            if len(fields) >= 4 and fields[0] == serial and fields[1] == f"tcp:{self.device_port}" and fields[-1] == "[Reverse]":
                if fields[2] != f"tcp:{port}":
                    raise RuntimeError(f"Device port {self.device_port} already forwards to {fields[2]}")
                return False
        self.run("rport", f"tcp:{self.device_port}", f"tcp:{port}")
        if not any(rule in line and serial in line and "[Reverse]" in line for line in self.rules().splitlines()):
            raise RuntimeError("HDC did not retain the reverse rule")
        return True

    def control(self, command, token=None):
        parameters = ["--ps", "port", str(self.device_port)] if command == "start" else []
        if token:
            self.secrets.append(token)
            parameters += ['--ps', 'controlToken', token]
        return self.shell("aa", "start", "-b", self.bundle, "-a", "EntryAbility", "--ps", "command", command, *parameters)

    def remove_reverse(self, serial, port):
        expected = [serial, f'tcp:{self.device_port}', f'tcp:{port}', '[Reverse]']
        if expected in [line.split() for line in self.rules().splitlines()]:
            self.run('fport', 'rm', expected[1], expected[2])

    def vpn_present(self):
        output = self.shell('pidof', self.bundle + ':vpn')
        return bool(re.fullmatch(r'[0-9]+(?:\s+[0-9]+)*', output.strip()))

    def background_start(self, token):
        self.secrets.append(token)
        return self.shell('aa', 'start', '-b', self.bundle, '-a', 'TetherVpnAbility', '-E',
                          '--ps', 'port', str(self.device_port), '--ps', 'controlToken', token)


def relay_arguments(args):
    command = [str(args.relay.resolve()), '--port', str(args.relay_port), '--ipv6', args.ipv6]
    if args.dns:
        command += ['--dns', args.dns]
    return command


def emit(event, **values):
    print(json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event, **values}), flush=True)


def default_relay():
    if os.environ.get("HARMONY_RELAY"):
        return Path(os.environ["HARMONY_RELAY"])
    root = Path(__file__).resolve().parent.parent
    for candidate in [root / "bin/harmony-relay", root / "build/harmony-relay"]:
        if candidate.is_file():
            return candidate
    return Path(shutil.which("harmony-relay") or root / "bin/harmony-relay")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["doctor", "install", "run", "stop", "status", "pair", "sync-apps"])
    parser.add_argument("--serial", required=True, help="Physical USB serial, never an IP endpoint")
    parser.add_argument("--hdc", default=os.environ.get("HDC", "hdc"), help="HDC executable; default is HDC or hdc on PATH")
    parser.add_argument("--hdc-server", help="Optional HDC server address; omitted to use HDC's own default")
    parser.add_argument("--bundle", default=os.environ.get("HARMONY_BUNDLE_NAME", DEFAULT_BUNDLE), help="Application bundle name; must match the installed HAP")
    parser.add_argument("--relay", type=Path, default=default_relay(), help="Relay executable; also configurable with HARMONY_RELAY")
    parser.add_argument("--relay-port", type=int, default=31417)
    parser.add_argument("--device-port", type=int, default=DEVICE_PORT,
                        help="Device loopback port; requires App 0.1.3 or newer for custom ports")
    parser.add_argument("--dns", help="Override the computer's IPv4 or IPv6 resolver")
    parser.add_argument('--ipv6', choices=['inherit', 'off', 'on'], default='inherit',
                        help='Server policy: inherit the phone setting, or force IPv6 off/on')
    parser.add_argument('--token-file', type=Path, help='Private VPN control token; defaults under --state-dir')
    parser.add_argument('--forward-host', default='127.0.0.1', help='HDC local-forward address for status/control')
    parser.add_argument("--hap", type=Path, help="Device-authorized signed HAP for install")
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".local/state/harmony-reverse-tether")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.serial) or not 1 <= args.relay_port <= 65535 or not 1024 <= args.device_port <= 65535:
        parser.error("Invalid USB serial or relay port")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+", args.bundle):
        parser.error("Invalid application bundle name")
    hdc = Hdc(args)
    if args.command == "doctor":
        emit("doctor", serial=args.serial, connected=hdc.connected(args.serial),
             api=hdc.shell("param", "get", "const.ohos.apiversion"),
             software=hdc.shell("param", "get", "const.product.software.version"), rules=hdc.rules())
        return
    if not hdc.connected(args.serial):
        raise RuntimeError("The specified device is not connected through USB")
    if args.command == "install":
        if not args.hap or not args.hap.is_file():
            parser.error("install requires --hap PATH")
        emit("install", result=hdc.run("install", str(args.hap.resolve())))
        return
    token_path = args.token_file or args.state_dir / f'{args.bundle}-{args.serial}.token'
    if args.command == 'sync-apps':
        count = sync_applications(hdc, args.serial, read_token(token_path), args.forward_host)
        if count is None:
            raise RuntimeError('On the phone, choose Add application > USB > Read application list first')
        emit('application_catalog_synced', count=count)
        return
    if args.command == 'status':
        with ForwardedControl(hdc.run, args.serial, forward_host=args.forward_host) as control:
            _, status = control.request('GET', '/v1/status')
            emit('vpn_status', status=status)
        return
    if args.command == 'pair':
        token = ensure_token(token_path)
        result = hdc.control('pair', token)
        if 'start ability successfully' not in result.lower():
            raise RuntimeError('The explicit VPN pairing request was not accepted')
        emit('pair_requested', token_file=str(token_path),
             note='RevTether was explicitly opened to pair this computer; the VPN was not restarted')
        return
    if args.command == "stop":
        if args.token_file:
            with ForwardedControl(hdc.run, args.serial, read_token(token_path), args.forward_host) as control:
                _, response = control.request('POST', '/v1/stop', {'request_id': str(uuid.uuid4())})
                emit('vpn_stop_requested', result=response)
            return
        emit("stop_requested", result=hdc.control("stop"))
        return
    # Refuse to run a partial service if the client has not been installed.
    bundle = hdc.shell("bm", "dump", "-n", args.bundle)
    if args.bundle not in bundle:
        raise RuntimeError("Signed VPN HAP is not installed on this device")
    if not args.relay.is_file():
        raise RuntimeError(f"Relay does not exist: {args.relay}")
    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    token = ensure_token(token_path)
    lock = (args.state_dir / f"relay-{args.relay_port}.lock").open("w")
    if os.name == 'nt':
        import msvcrt
        lock.write('0'); lock.flush(); lock.seek(0)
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    relay = None
    owned_rule = False
    requested = False
    stop = False
    stop_vpn = False

    def stop_signal(_number, _frame):
        nonlocal stop, stop_vpn
        stop = True
        stop_vpn = _number == signal.SIGINT

    signal.signal(signal.SIGINT, stop_signal)
    signal.signal(signal.SIGTERM, stop_signal)
    relay_args = relay_arguments(args)
    try:
        # Let bind() be authoritative; never reuse or terminate an unrelated listener.
        relay = subprocess.Popen(relay_args)
        for _ in range(30):
            if relay.poll() is not None:
                raise RuntimeError(f"Relay exited with {relay.returncode}; check port/DNS")
            try:
                with socket.create_connection(("127.0.0.1", args.relay_port), timeout=0.2) as sock:
                    sock.settimeout(1)
                    data = b""
                    while len(data) < 4:
                        part = sock.recv(4 - len(data))
                        if not part:
                            raise RuntimeError("Relay disconnected during readiness check")
                        data += part
                time.sleep(0.1)
                if relay.poll() is not None:
                    raise RuntimeError("Relay could not own the port")
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("Relay did not become ready")
        online = False
        initial_request = True
        next_start = 0
        next_catalog = 0
        while not stop:
            if relay.poll() is not None:
                raise RuntimeError("Relay exited; supervisor should restart this process")
            try:
                present = hdc.connected(args.serial)
                if present:
                    created = hdc.reverse(args.serial, args.relay_port)
                    owned_rule = owned_rule or created
                    vpn_present = hdc.vpn_present()
                    if not online and vpn_present:
                        emit('vpn_adopted', serial=args.serial, ipv6=args.ipv6,
                             note='Restored the USB path and preserved the existing VPN; use pair if control is not paired')
                    if not vpn_present and time.monotonic() >= next_start:
                        next_start = time.monotonic() + 30
                        foreground_request = initial_request
                        initial_request = False
                        if foreground_request:
                            # An explicit run may open initial consent. Reconnecting
                            # an existing VPN never uses this foreground path.
                            result = hdc.control("start", token)
                            if 'start ability successfully' not in result.lower():
                                raise RuntimeError('VPN start request was not accepted')
                            requested = True
                            emit("vpn_start_requested", serial=args.serial, result='accepted',
                                 token_file=str(token_path), ipv6=args.ipv6,
                                 note="Check application status and VPN consent; this is not proof of Internet access")
                        else:
                            result = hdc.background_start(token)
                            if 'start ability successfully' not in result.lower():
                                raise RuntimeError('Background VPN start was not accepted; open RevTether to complete consent or pairing')
                            requested = True
                            emit('vpn_background_start_requested', serial=args.serial)
                    elif created:
                        emit("usb_forward_restored", serial=args.serial)
                    initial_request = False
                    if vpn_present and time.monotonic() >= next_catalog:
                        next_catalog = time.monotonic() + 10
                        try:
                            count = sync_applications(hdc, args.serial, token, args.forward_host)
                            if count is not None:
                                emit('application_catalog_synced', count=count)
                        except (RuntimeError, OSError):
                            # Old clients, unpaired controls and failed reads must
                            # not change VPN state or its recovery lifecycle.
                            pass
                elif online:
                    emit("usb_disconnected", serial=args.serial)
                online = present
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                emit("transport_error", detail=str(error))
            time.sleep(2)
    finally:
        if requested and stop_vpn:
            try:
                with ForwardedControl(hdc.run, args.serial, token, args.forward_host) as control:
                    _, response = control.request('POST', '/v1/stop', {'request_id': str(uuid.uuid4())})
                    emit('vpn_stop_requested', result=response)
            except Exception as error:
                emit("vpn_stop_unconfirmed", detail=str(error))
        if owned_rule:
            try:
                hdc.remove_reverse(args.serial, args.relay_port)
            except Exception as error:
                emit("forward_cleanup_unconfirmed", detail=str(error))
        if relay and relay.poll() is None:
            relay.terminate()
            try:
                relay.wait(timeout=5)
            except subprocess.TimeoutExpired:
                relay.kill()
                relay.wait()
        lock.close()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        emit("error", detail=str(error))
        sys.exit(1)
