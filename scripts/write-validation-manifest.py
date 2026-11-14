#!/usr/bin/env python3
"""Record source and unsigned simulator build provenance; never reads credentials."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--derived-data', type=Path, default=Path('/private/tmp/imora-implementation/DerivedData'))
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
env = dict(os.environ, DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
def command(*parts):
    return subprocess.check_output(parts, cwd=root, env=env, text=True).strip()
def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1 << 20), b''):
            hasher.update(chunk)
    return hasher.hexdigest()

source_roots = ['Imora', 'ImoraShare', 'Shared', 'ImoraTests', 'ImoraUITests', 'scripts', 'config', 'project.yml', 'localization']
tracked = command('git', 'ls-files', '--', *source_roots).splitlines()
untracked = command('git', 'ls-files', '--others', '--exclude-standard', '--', *source_roots).splitlines()
dirty = command('git', 'diff', '--name-only', 'HEAD', '--', *source_roots).splitlines()
source = {name: digest(root/name) for name in sorted(set(tracked + untracked)) if (root/name).is_file()}
app = args.derived_data/'Build/Products/Debug-iphonesimulator/Imora.app'
info = plistlib.loads((app/'Info.plist').read_bytes())
artifacts = {str(path.relative_to(app)): digest(path) for path in sorted(app.rglob('*')) if path.is_file() and not path.is_symlink()}
result = {
    'generatedAtUTC': datetime.now(timezone.utc).isoformat(),
    'sourceRevision': command('git', 'rev-parse', 'HEAD'),
    'sourceTree': command('git', 'rev-parse', 'HEAD^{tree}'),
    'branch': command('git', 'branch', '--show-current'),
    'dirtySourcePaths': sorted(set(dirty + untracked)),
    'xcode': command('xcodebuild', '-version'),
    'simulatorSDK': command('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'),
    'configuration': 'Debug', 'platform': 'iOS Simulator arm64',
    'signing': 'CODE_SIGNING_ALLOWED=NO; not a device/release build',
    'bundleIdentifier': info['CFBundleIdentifier'],
    'bundleVersion': info['CFBundleVersion'],
    'sourceSHA256': source,
    'appFileSHA256': artifacts,
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print(f'{len(source)} source files, {len(artifacts)} simulator bundle files recorded; {len(result["dirtySourcePaths"])} dirty source paths')
