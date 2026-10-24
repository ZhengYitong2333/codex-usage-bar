#!/usr/bin/env python3
"""Inspect tracked source without printing potentially sensitive values."""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
tracked = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root).decode().split('\0')
patterns = {
    'OpenAI credential': re.compile(r'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}\b'),
    'GitHub credential': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'),
    'JWT credential': re.compile(r'\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\b'),
    'Private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'Personal absolute path': re.compile(r'/(?:Users|home)/[A-Za-z0-9._-]+/'),
}
failures = []
count = 0
for entry in filter(None, tracked):
    metadata, name = entry.split('\t', 1)
    path = Path(name)
    if path.name in ('auth.json', 'settings.json', '.env') or path.name.startswith('.env.') or path.suffix in ('.jsonl', '.log', '.db') or any(part in ('backups', 'screenshots', 'dist', '.build') for part in path.parts):
        failures.append((name, 'Runtime or private data file'))
        continue
    if metadata.split()[0] == '120000':
        failures.append((name, 'Symlink requires manual review'))
        continue
    try:
        content = subprocess.check_output(['git', 'show', ':' + name], cwd=root).decode('utf-8')
    except (UnicodeError, OSError, subprocess.CalledProcessError):
        failures.append((name, 'Non-source or unreadable file'))
        continue
    count += 1
    for label, pattern in patterns.items():
        if pattern.search(content):
            failures.append((name, label))
for name, label in failures:
    print(f'BLOCKED: {name}: {label}', file=sys.stderr)
if failures:
    raise SystemExit(1)
if count == 0:
    raise SystemExit('No tracked files to inspect; stage the intended source first.')
print(f'Privacy check passed: {count} source files; no matching private-data patterns.')
