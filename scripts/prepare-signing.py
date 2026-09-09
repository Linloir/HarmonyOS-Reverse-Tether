#!/usr/bin/env python3
"""Generate a local key and public CSR for a Huawei-issued debug certificate."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("--bundle", default=os.environ.get("HARMONY_BUNDLE_NAME", "com.linloir.hrevtether"))
parser.add_argument("--subject", default="CN=linloir", help="X.509 subject for the certificate request")
args = parser.parse_args()
directory = args.directory.resolve()
directory.mkdir(parents=True, exist_ok=True, mode=0o700)
key = directory / "harmony-reverse.p12"
password_file = directory / "password"
csr = directory / "harmony-reverse.csr"
if any(path.exists() for path in (key, password_file, csr)):
    parser.error("Signing material already exists; refusing to overwrite it")
password = secrets.token_urlsafe(32)
fd = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as stream:
    stream.write(password + "\n")
env = dict(os.environ, HARMONY_SIGNING_PASSWORD=password)
common = ["-keystore", str(key), "-storetype", "PKCS12", "-storepass:env", "HARMONY_SIGNING_PASSWORD", "-alias", "harmonyreverse"]
subprocess.run(["keytool", "-genkeypair", *common, "-keyalg", "EC", "-groupname", "secp256r1", "-sigalg", "SHA256withECDSA", "-validity", "3650", "-dname", args.subject], env=env, check=True)
os.chmod(key, 0o600)
subprocess.run(["keytool", "-certreq", *common, "-sigalg", "SHA256withECDSA", "-file", str(csr), "-rfc"], env=env, check=True)
config = {"keystore": str(key), "alias": "harmonyreverse", "passwordFile": str(password_file),
          "certificate": str(directory / "huawei-debug.cer"), "profile": str(directory / "huawei-debug.p7b")}
path = directory / "signing.local.json"
path.write_text(json.dumps(config, indent=2) + "\n")
os.chmod(path, 0o600)
print(f"Public CSR: {csr}\nLocal signing config: {path}\nUse the CSR to obtain a Huawei debug certificate and a profile for {args.bundle}.")
