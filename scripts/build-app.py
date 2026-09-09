#!/usr/bin/env python3
"""Build an unsigned HAP without modifying the source application identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle-name', default=os.environ.get('HARMONY_BUNDLE_NAME'),
                        help='Application ID matching your signing profile; defaults to AppScope/app.json5')
    parser.add_argument('--output', type=Path, default=root / 'build/harmony-reverse-tether-unsigned.hap')
    args = parser.parse_args()
    if args.bundle_name and not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+', args.bundle_name):
        parser.error('Invalid application bundle name')
    clt_home = os.environ.get('HARMONY_CLT_HOME')
    if not clt_home:
        parser.error('Set HARMONY_CLT_HOME to the extracted command-line-tools directory')
    clt = Path(clt_home).resolve()
    for tool in ['ohpm', 'hvigorw']:
        if not (clt / 'bin' / tool).is_file():
            parser.error(f'Missing tool: {clt / "bin" / tool}')
    output = args.output.resolve()
    # A clean staging directory prevents private identity and generated state
    # from entering the source tree or being reused by a later default build.
    with tempfile.TemporaryDirectory(prefix='harmony-tether-build-') as temporary:
        project = Path(temporary) / 'app'
        shutil.copytree(root / 'app', project, ignore=shutil.ignore_patterns(
            'build', '.hvigor', '.cxx', 'oh_modules', 'node_modules', '.idea',
            'local.properties', '*.local.json', '*.p12', '*.p7b', '*.cer', '*.csr', '*.jks', '*.pem', '*.key'))
        manifest_path = project / 'AppScope/app.json5'
        manifest = json.loads(manifest_path.read_text())
        if args.bundle_name:
            manifest['app']['bundleName'] = args.bundle_name
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        subprocess.run([str(clt / 'bin/ohpm'), 'install', '--all'], cwd=project, check=True)
        subprocess.run([str(clt / 'bin/hvigorw'), '--mode', 'module', '-p', 'product=default',
                        '-p', 'module=entry@default', 'assembleHap', '--no-daemon'], cwd=project, check=True)
        hap = project / 'entry/build/default/outputs/default/entry-default-unsigned.hap'
        output.parent.mkdir(parents=True, exist_ok=True)
        # Preserve an earlier output if the build fails.
        with tempfile.TemporaryDirectory(prefix='.hap-output-', dir=output.parent) as staging:
            staged = Path(staging) / output.name
            shutil.copyfile(hap, staged)
            staged.replace(output)
    print(f'Unsigned HAP: {output}')
    print(f'SHA-256: {hashlib.sha256(output.read_bytes()).hexdigest()}')


if __name__ == '__main__':
    main()
