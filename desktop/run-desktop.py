#!/usr/bin/env python3
"""Launch Tauri using the local desktop OAuth client configuration."""
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
config = root / 'google-oauth-client.json'
if not config.exists():
    raise SystemExit('Place the Google Desktop OAuth client JSON at desktop/google-oauth-client.json.')
data = json.loads(config.read_text(encoding='utf-8')).get('installed', {})
client_id = data.get('client_id')
if not isinstance(client_id, str) or not client_id:
    raise SystemExit('The file must contain a Desktop app OAuth client.')
env = os.environ.copy()
env['DEVTRACK_GOOGLE_CLIENT_ID'] = client_id
if isinstance(data.get('client_secret'), str):
    env['DEVTRACK_GOOGLE_CLIENT_SECRET'] = data['client_secret']
os.chdir(root)
sys.exit(subprocess.call(['npm', 'run', 'tauri', '--', 'dev'], env=env))
