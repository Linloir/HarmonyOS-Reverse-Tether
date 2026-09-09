#!/usr/bin/env python3
"""Sign and verify a HAP or single-module App Pack using a matching Huawei profile."""
import argparse
import hashlib
import io
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
    parser.error("Signing tool or input package does not exist")
if args.input.suffix not in ('.hap', '.app') or args.output.suffix != args.input.suffix:
    parser.error('Use matching .hap or .app input and output extensions')
if args.output.resolve() == args.input.resolve():
    parser.error("Input and output must be different files")
password = Path(config["passwordFile"]).read_text().strip()
if not password:
    parser.error("Signing password file is empty")
with zipfile.ZipFile(args.input) as package:
    if args.input.suffix == '.app':
        modules = [name for name in package.namelist() if name.endswith('.hap')]
        if len(modules) != 1:
            parser.error('This signer supports App Packs with exactly one HAP')
        with zipfile.ZipFile(io.BytesIO(package.read(modules[0]))) as hap:
            metadata = json.loads(hap.read('module.json'))
    else:
        metadata = json.loads(package.read('module.json'))
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
    signed = directory / ('signed' + args.input.suffix)

    def sign_and_verify(source: Path, destination: Path) -> None:
        run_tool(["sign-app", "-mode", "localSign",
                  "-keyAlias", config["alias"], "-keyPwd", password,
                  "-appCertFile", config["certificate"], "-profileFile", config["profile"],
                  "-inFile", str(source), "-signAlg", "SHA256withECDSA",
                  "-keystoreFile", config["keystore"], "-keystorePwd", password,
                  "-outFile", str(destination), "-compatibleVersion", str(compatible_version), "-signCode", "1"],
                 "sign-app success")
        if not destination.is_file():
            sys.exit("Signing tool did not create a package")
        run_tool(["verify-app", "-inFile", str(destination),
                  "-outCertChain", str(directory / "certificate-chain.cer"),
                  "-outProfile", str(directory / "profile.p7b")], "verify-app success")
        if (directory / "profile.p7b").read_bytes() != Path(config["profile"]).read_bytes():
            sys.exit("Verified package profile does not match the supplied profile")

    source = args.input
    if args.input.suffix == '.app':
        # Signing the outer ZIP does not sign its embedded HAP. Validate both
        # layers before replacing an output intended for distribution.
        module_source = directory / 'module-unsigned.hap'
        module_signed = directory / 'module-signed.hap'
        with zipfile.ZipFile(args.input) as package:
            module_source.write_bytes(package.read(modules[0]))
        sign_and_verify(module_source, module_signed)
        source = directory / 'modules-signed.app'
        with zipfile.ZipFile(args.input) as package, zipfile.ZipFile(source, 'w') as repacked:
            for entry in package.infolist():
                data = module_signed.read_bytes() if entry.filename == modules[0] else package.read(entry)
                repacked.writestr(entry, data)
    sign_and_verify(source, signed)
    signed.replace(args.output)

print(f"Signed and locally verified package: {args.output}")
print(f"SHA-256: {hashlib.sha256(args.output.read_bytes()).hexdigest()}")
print("Device installation must separately verify that the signing chain is trusted.")
