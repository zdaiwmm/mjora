#!/usr/bin/env python3
"""Collect compiler-extracted app and extension keys after an Xcode build."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--derived-data', type=Path, default=Path('/private/tmp/imora-implementation/DerivedData'))
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
keys = {}
for path in args.derived_data.glob('Build/Intermediates.noindex/Imora.build/Debug-iphonesimulator/*.build/Objects-normal/arm64/*.stringsdata'):
    data = json.loads(path.read_text())
    try:
        source = str(Path(data['source']).relative_to(root))
    except (KeyError, ValueError):
        continue
    if not source.startswith(('Imora/', 'ImoraShare/', 'Shared/')):
        continue
    for item in data.get('tables', {}).get('Localizable', []):
        key = item['key']
        context = {'source': source, 'line': item['location']['startingLine']}
        if context not in keys.setdefault(key, []):
            keys[key].append(context)
args.output.write_text(json.dumps(dict(sorted(keys.items())), ensure_ascii=False, indent=2) + '\n')
print(f'{len(keys)} app/extension keys collected')
