#!/usr/bin/env python3
"""Build the shared app/extension catalog from a reviewed key inventory."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--keys', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
keys = json.loads(args.keys.read_text())
translations = json.loads((root / 'localization/zh-Hans.json').read_text())
missing = set(keys) - set(translations)
if missing:
    raise SystemExit('Missing translations: ' + repr(sorted(missing)))
strings = {}
for key, contexts in sorted(keys.items()):
    english = {'stringUnit': {'state': 'translated', 'value': key}}
    singulars = {
        '%lld photos': '%lld photo',
        '%lld videos': '%lld video',
        'Verify and remove %lld selected device copies?': 'Verify and remove %lld selected device copy?',
        '%lld pending shares use %@.': '%lld pending share uses %@.',
        'Discard %lld pending shares and their local temporary copies?': 'Discard %lld pending share and its local temporary copy?',
    }
    if key in singulars:
        english = {'variations': {'plural': {form: {'stringUnit': {'state': 'translated', 'value': value}}
                   for form, value in [('one', singulars[key]), ('other', key)]}}}
    strings[key] = {'extractionState': 'manual',
                    'localizations': {'en': english, 'zh-Hans': {'stringUnit': {'state': 'translated', 'value': translations[key]}}}}
    if contexts:
        strings[key]['comment'] = '\n'.join(sorted({f"{item['source']}:{item['line']}" for item in contexts}))
output = root / 'Shared/Resources/Localizable.xcstrings'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps({'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'}, ensure_ascii=False, indent=2) + '\n')
print(f'{len(strings)} catalog keys written')
