#!/usr/bin/env python3
"""Sign a built HAP using an existing device-authorized Huawei debug profile."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--config", type=Path, required=True)
parser.add_argument("--tool", type=Path, required=True, help="SDK toolchains/lib/hap-sign-tool.jar")
parser.add_argument("--input", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
config = json.loads(args.config.read_text())
for name in ("keystore", "passwordFile", "certificate", "profile"):
    if not Path(config[name]).is_file():
        parser.error(f"Missing signing {name}: {config[name]}")
if not args.tool.is_file() or not args.input.is_file():
    parser.error("Signing tool or input HAP does not exist")
if args.output.resolve() == args.input.resolve():
    parser.error("Input and output must be different files")
password = Path(config["passwordFile"]).read_text().strip()
if not password:
    parser.error("Signing password file is empty")
with zipfile.ZipFile(args.input) as hap:
    metadata = json.loads(hap.read("module.json"))
compatible_version = int(metadata["app"]["minAPIVersion"])
args.output.parent.mkdir(parents=True, exist_ok=True)


def run_tool(arguments: list[str], success_marker: str) -> None:
    result = subprocess.run(["java", "-jar", str(args.tool), *arguments],
                            capture_output=True, text=True)
    # The tool receives passwords through its required arguments; never echo them.
    output = result.stdout + result.stderr
    print(output.replace(password, "<redacted>"), end="")
    if result.returncode or success_marker not in output:
        sys.exit(result.returncode or 1)


# Keep any existing output intact until both signing and verification succeed.
with tempfile.TemporaryDirectory(prefix=".hap-sign-", dir=args.output.parent) as temporary:
    directory = Path(temporary)
    signed = directory / "signed.hap"
    run_tool(["sign-app", "-mode", "localSign",
              "-keyAlias", config["alias"], "-keyPwd", password,
              "-appCertFile", config["certificate"], "-profileFile", config["profile"],
              "-inFile", str(args.input), "-signAlg", "SHA256withECDSA",
              "-keystoreFile", config["keystore"], "-keystorePwd", password,
              "-outFile", str(signed), "-compatibleVersion", str(compatible_version), "-signCode", "1"],
             "sign-app success")
    if not signed.is_file():
        sys.exit("Signing tool did not create a HAP")
    run_tool(["verify-app", "-inFile", str(signed),
              "-outCertChain", str(directory / "certificate-chain.cer"),
              "-outProfile", str(directory / "profile.p7b")], "verify-app success")
    signed.replace(args.output)

print(f"Signed and locally verified HAP: {args.output}")
print(f"SHA-256: {hashlib.sha256(args.output.read_bytes()).hexdigest()}")
print("Device installation must separately verify that the signing chain is trusted.")
