#!/usr/bin/env python3
"""Generate local Google URL-scheme settings from the downloaded Firebase plist."""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parent
config = root / 'DevTrack' / 'GoogleService-Info.plist'
if not config.exists():
    raise SystemExit('Place GoogleService-Info.plist in ios/DevTrack first.')
with config.open('rb') as source:
    value = plistlib.load(source).get('REVERSED_CLIENT_ID', '')
if not re.fullmatch(r'[A-Za-z0-9.-]+', value):
    raise SystemExit('The plist lacks a valid REVERSED_CLIENT_ID; enable Google sign-in and download it again.')
(root / 'Config' / 'Firebase.local.xcconfig').write_text(f'GOOGLE_REVERSED_CLIENT_ID = {value}\n')
print('Wrote local Google URL-scheme configuration.')
