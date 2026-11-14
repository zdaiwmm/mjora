#!/usr/bin/env python3
"""Validate shipped English/Chinese resources and compiler key coverage."""
import argparse
import collections
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--keys', type=Path)
args = parser.parse_args()
format_token = re.compile(r'%(?:(\d+)\$)?[-+#0 \']*\d*(?:\.\d+)?(hh|ll|h|l|L|z|t|j)?([@diuoxXfFeEgGaAcCsSp])|%%')
def placeholders(value):
    result = []; implicit = 1
    for match in format_token.finditer(value):
        if match[0] == '%%':
            result.append(('literal', '%')); continue
        position = int(match[1]) if match[1] else implicit
        implicit += not bool(match[1])
        result.append((position, (match[2] or '') + match[3]))
    return collections.Counter(result)

errors = []; total = 0
allowed_identical = {'', '%@ %@', '%@ · %@', '%@ • %@ • %@', '%lld', '%lld %@', '%lld × %lld', '%lld%%', '+%lld', 'GMT%@', 'ID', 'Imora', 'MB', 'http://192.168.1.10:2283', 'my-album', '·', '· %@'}
for path in [root/'Shared/Resources/Localizable.xcstrings', root/'Imora/Resources/InfoPlist.xcstrings', root/'ImoraShare/Resources/InfoPlist.xcstrings']:
    data = json.loads(path.read_text()); strings = data['strings']; total += len(strings)
    for key, entry in strings.items():
        locales = entry.get('localizations', {})
        if set(locales) != {'en', 'zh-Hans'}:
            errors.append(f'{path.name}: Missing language: {key}'); continue
        zh = locales['zh-Hans'].get('stringUnit', {}).get('value')
        if zh is None or (key and not zh):
            errors.append(f'Missing Chinese: {key}'); continue
        if path.name == 'Localizable.xcstrings':
            if placeholders(key) != placeholders(zh): errors.append(f'Placeholder mismatch: {key}')
            if key.count('\n') != zh.count('\n'): errors.append(f'Newline mismatch: {key}')
            if key == zh and key not in allowed_identical: errors.append(f'Unreviewed identical text: {key}')
            if 'stringUnit' in locales['en'] and locales['en']['stringUnit']['value'] != key: errors.append(f'English fallback changed: {key}')
    if args.keys and path.name == 'Localizable.xcstrings':
        missing = set(json.loads(args.keys.read_text())) - set(strings)
        errors.extend('Compiler key missing: ' + key for key in sorted(missing))
if errors:
    raise SystemExit('\n'.join(errors))
print(f'{total} entries: English/zh-Hans coverage, placeholders, newlines and reviewed literals valid')
