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
    parser.add_argument('--mode', choices=['debug', 'release'], default='debug',
                        help='Compilation mode; use release for distribution')
    parser.add_argument('--app-output', type=Path,
                        help='Also build an unsigned App Pack using assembleApp')
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
    app_output = args.app_output.resolve() if args.app_output else None
    if app_output == output:
        parser.error('HAP and App Pack outputs must be different files')
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
        command = [str(clt / 'bin/hvigorw'), '--mode', 'project' if app_output else 'module',
                   '-p', 'product=default', '-p', f'buildMode={args.mode}']
        if not app_output:
            command += ['-p', 'module=entry@default']
        command += ['assembleApp' if app_output else 'assembleHap', '--no-daemon']
        subprocess.run(command, cwd=project, check=True)
        hap = project / 'entry/build/default/outputs/default/entry-default-unsigned.hap'
        products = [(hap, output)]
        if app_output:
            apps = list((project / 'build/outputs').rglob('*.app'))
            if len(apps) != 1:
                raise RuntimeError(f'Expected one App Pack, found {len(apps)}')
            products.append((apps[0], app_output))
        for source, destination in products:
            copy_output(source, destination)
    print(f'Build mode: {args.mode}')
    for _, destination in products:
        print(f'Unsigned package: {destination}')
        print(f'SHA-256: {hashlib.sha256(destination.read_bytes()).hexdigest()}')


def copy_output(source: Path, output: Path):
    """Replace an output only after the build has completed."""
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.hap-output-', dir=output.parent) as staging:
        staged = Path(staging) / output.name
        shutil.copyfile(source, staged)
        staged.replace(output)


if __name__ == '__main__':
    main()
