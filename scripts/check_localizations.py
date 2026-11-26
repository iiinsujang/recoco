#!/usr/bin/env python3
"""Check launch-locale parity, privacy prompts and typed interpolation in the app bundle.

Optionally pass --app path/to/Recoco.app, or --stringsdata the app target's Swift
Objects-normal/arm64 directory from a Release build (not the package targets).
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / 'Recoco/Resources'
LANGUAGES = set('ko en ja zh-Hant vi th de fr it es pt-PT nl da sv fi pl cs sk bg ro hr sl hu el lv lt et ga mt nb is'.split())
ARG = re.compile(r'%(?:(\d+)\$)?(lld|ld|d|u|@|%)')


def signature(text):
    args, index = {}, 0
    for match in ARG.finditer(text):
        if match[2] == '%':
            continue
        index += 1
        pos = int(match[1]) if match[1] else index
        if args.setdefault(pos, match[2]) != match[2]:
            raise ValueError(f'conflicting argument {pos} in {text!r}')
    return args


def read_plist(path):
    return plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(path)]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--stringsdata', type=Path)
    opt = parser.parse_args()
    fail = []
    catalog = json.loads((RES / 'Localizable.xcstrings').read_text())
    assert catalog['sourceLanguage'] == 'ko'
    strings = catalog['strings']
    for key, entry in strings.items():
        localizations = entry.get('localizations', {})
        if set(localizations) != LANGUAGES:
            fail.append((key, 'locale mismatch', sorted(set(localizations) ^ LANGUAGES)))
        for lang, loc in localizations.items():
            value = loc['stringUnit']['value']
            if not value.strip() or signature(key) != signature(value):
                fail.append((lang, key, 'empty or invalid arguments', value))
            if lang != 'ko' and re.search('[가-힣]', value):
                fail.append((lang, key, 'unexpected Korean text'))
            if lang == 'ko' and value != key:
                fail.append((lang, key, 'changed Korean copy'))
    if opt.stringsdata:
        paths = list(opt.stringsdata.glob('*.stringsdata'))
        if not paths:
            fail.append(('no compiler emissions at', str(opt.stringsdata)))
        for path in paths:
            if path.stem in {'SubscriptionView', 'SubscriptionStore'}:
                continue  # Paid features are disabled in this release.
            emitted = json.loads(path.read_text()).get('tables', {}).get('Localizable', [])
            for row in emitted:
                key = row['key']
                if key == '홈 화면 준비 중' and path.stem == 'RecocoApp':
                    continue  # Unused MainPlaceholderView, not an app route.
                if re.search('[가-힣]', key) and key not in strings:
                    fail.append((path.stem, 'missing Swift key', key))
    for language in LANGUAGES:
        folder = (opt.app or RES) / (language + '.lproj')
        privacy = read_plist(folder / 'InfoPlist.strings')
        if not privacy.get('NSPhotoLibraryUsageDescription', '').strip():
            fail.append((language, 'missing photo permission'))
        if opt.app:
            table = read_plist(folder / 'Localizable.strings')
            for key, entry in strings.items():
                if table.get(key) != entry['localizations'][language]['stringUnit']['value']:
                    fail.append((language, 'bundle differs from catalog', key))
    if fail:
        raise SystemExit('\n'.join(map(str, fail[:30])) + f'\n{len(fail)} issues')
    print(f'{len(LANGUAGES)} localizations; {len(strings)} UI keys; all photo prompts and format arguments verified.')
    if opt.app:
        print(f'Checked compiled resources in {opt.app}')


if __name__ == '__main__':
    main()
