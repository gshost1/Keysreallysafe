#!/usr/bin/env python3
"""Sign local builds with a persistent Apple identity; no ad-hoc fallback."""
import os
from pathlib import Path
import re
import subprocess
import sys

CONFIG = Path.home() / '.config/keysreallysafe/signing-identity'
APPLE_SIGNER = ('anchor apple generic and ('
    '(certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists) or '
    '(certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists) or '
    '(certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.7] exists))')


def run(*args):
    return subprocess.run(['/usr/bin/codesign', *args], check=True, capture_output=True, text=True)


def main(binary):
    identity = os.environ.get('KEYS_SIGNING_IDENTITY')
    if not identity and CONFIG.exists():
        identity = CONFIG.read_text().strip()
    if not identity or not re.fullmatch(r'[0-9a-fA-F]{40}', identity):
        raise SystemExit('A persistent Apple signing certificate is required. Set KEYS_SIGNING_IDENTITY to its 40-character SHA-1 from security find-identity -v -p codesigning. No ad-hoc fallback is allowed.')
    run('--force', '--sign', identity, '--identifier', 'keysreallysafe', '--timestamp=none', binary)
    run('--verify', '--strict', '-R', '=identifier "keysreallysafe" and '+APPLE_SIGNER, binary)
    info = run('-dvv', binary)
    match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', info.stderr, re.MULTILINE)
    if not match:
        raise SystemExit('Apple signing identity has no valid team ID; refusing this build.')
    req = f'identifier "keysreallysafe" and certificate leaf[subject.OU] = "{match[1]}" and '+APPLE_SIGNER
    run('--force', '--sign', identity, '--identifier', 'keysreallysafe', '--timestamp=none', '--requirements', '=designated => '+req, binary)
    run('--verify', '--strict', '-R', '='+req, binary)
    print('Signed with stable Apple team '+match[1]+'.')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: sign-local.py BINARY')
    try:
        main(sys.argv[1])
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stderr or 'Code signing failed; no ad-hoc fallback performed.')
