#!/usr/bin/env python3
"""Share a computer's network with a HarmonyOS device over USB."""
import argparse
import fcntl
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

DEFAULT_BUNDLE = "com.linloir.hrevtether"
DEVICE_PORT = 31417


class Hdc:
    def __init__(self, args):
        self.prefix = [args.hdc]
        if args.hdc_server:
            self.prefix += ["-s", args.hdc_server]
        self.prefix += ["-t", args.serial]
        self.bundle = args.bundle

    def run(self, *command):
        result = subprocess.run(self.prefix + list(command), capture_output=True, text=True, timeout=20)
        output = result.stdout + result.stderr
        # HDC can return exit status 0 for device-side failure.
        if result.returncode or re.search(r"\[Fail\]|error:|install failed|failed to", output, re.I):
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
        rule = f"tcp:{DEVICE_PORT} tcp:{port}"
        for line in self.rules().splitlines():
            fields = line.split()
            if len(fields) >= 4 and fields[0] == serial and fields[1] == f"tcp:{DEVICE_PORT}" and fields[-1] == "[Reverse]":
                if fields[2] != f"tcp:{port}":
                    raise RuntimeError(f"Device port {DEVICE_PORT} already forwards to {fields[2]}")
                return False
        self.run("rport", f"tcp:{DEVICE_PORT}", f"tcp:{port}")
        if not any(rule in line and serial in line and "[Reverse]" in line for line in self.rules().splitlines()):
            raise RuntimeError("HDC did not retain the reverse rule")
        return True

    def control(self, command):
        return self.shell("aa", "start", "-b", self.bundle, "-a", "EntryAbility", "--ps", "command", command)


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
    parser.add_argument("command", choices=["doctor", "install", "run", "stop"])
    parser.add_argument("--serial", required=True, help="Physical USB serial, never an IP endpoint")
    parser.add_argument("--hdc", default=os.environ.get("HDC", "hdc"), help="HDC executable; default is HDC or hdc on PATH")
    parser.add_argument("--hdc-server", help="Optional HDC server address; omitted to use HDC's own default")
    parser.add_argument("--bundle", default=os.environ.get("HARMONY_BUNDLE_NAME", DEFAULT_BUNDLE), help="Application bundle name; must match the installed HAP")
    parser.add_argument("--relay", type=Path, default=default_relay(), help="Relay executable; also configurable with HARMONY_RELAY")
    parser.add_argument("--relay-port", type=int, default=31417)
    parser.add_argument("--dns", help="Override the computer's IPv4 resolver; default is /etc/resolv.conf")
    parser.add_argument("--hap", type=Path, help="Device-authorized signed HAP for install")
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".local/state/harmony-reverse-tether")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.serial) or not 1 <= args.relay_port <= 65535:
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
    if args.command == "stop":
        emit("stop_requested", result=hdc.control("stop"))
        return
    # Refuse to run a partial service if the client has not been installed.
    bundle = hdc.shell("bm", "dump", "-n", args.bundle)
    if args.bundle not in bundle:
        raise RuntimeError("Signed VPN HAP is not installed on this device")
    if not args.relay.is_file():
        raise RuntimeError(f"Relay does not exist: {args.relay}")
    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = (args.state_dir / f"relay-{args.relay_port}.lock").open("w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    relay = None
    owned_rule = False
    requested = False
    stop = False

    def stop_signal(_number, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, stop_signal)
    signal.signal(signal.SIGTERM, stop_signal)
    relay_args = [str(args.relay.resolve()), "--port", str(args.relay_port)]
    if args.dns:
        relay_args += ["--dns", args.dns]
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
        while not stop:
            if relay.poll() is not None:
                raise RuntimeError("Relay exited; supervisor should restart this process")
            try:
                present = hdc.connected(args.serial)
                if present:
                    created = hdc.reverse(args.serial, args.relay_port)
                    owned_rule = owned_rule or created
                    if not online:
                        # Show foreground UI before requesting VPN consent.
                        hdc.shell("aa", "start", "-b", args.bundle, "-a", "EntryAbility")
                        time.sleep(0.5)
                        result = hdc.control("start")
                        requested = True
                        emit("vpn_start_requested", serial=args.serial, result=result,
                             note="Check application status and VPN consent; this is not proof of Internet access")
                    elif created:
                        emit("usb_forward_restored", serial=args.serial)
                elif online:
                    emit("usb_disconnected", serial=args.serial)
                online = present
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                emit("transport_error", detail=str(error))
            time.sleep(2)
    finally:
        if requested:
            try:
                emit("vpn_stop_requested", result=hdc.control("stop"))
            except Exception as error:
                emit("vpn_stop_unconfirmed", detail=str(error))
        if owned_rule:
            try:
                hdc.run("fport", "rm", f"tcp:{DEVICE_PORT}", f"tcp:{args.relay_port}")
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
