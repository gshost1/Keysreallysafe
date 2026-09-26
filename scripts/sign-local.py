#!/usr/bin/env python3
"""Sign local builds with a persistent Apple identity; no ad-hoc fallback.

TARGET is either a bare `keys` executable (development builds) or a
Keysrs.app bundle. A bundle is signed once, with the hardened runtime, under
the same `keysreallysafe` identifier and team-pinned designated requirement as
the bare binary, so Keychain items stay readable across the move to an app.
"""
import os
from pathlib import Path
import re
import subprocess
import sys

CONFIG = Path.home() / '.config/keysreallysafe/signing-identity'
IDENTIFIER = 'keysreallysafe'
APPLE_SIGNER = ('anchor apple generic and ('
    '(certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists) or '
    '(certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists) or '
    '(certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.7] exists))')


def run(*args):
    return subprocess.run(['/usr/bin/codesign', *args], check=True, capture_output=True, text=True)


def designated_requirement(team):
    return f'identifier "{IDENTIFIER}" and certificate leaf[subject.OU] = "{team}" and ' + APPLE_SIGNER


def sign(target, identity, timestamp=False):
    """Sign twice: once to learn the team, then again pinning the requirement to that team."""
    target = str(target)
    options = ['--force', '--sign', identity, '--identifier', IDENTIFIER,
               '--timestamp' if timestamp else '--timestamp=none']
    if target.rstrip('/').endswith('.app'):
        # Distribution-ready bundles need the hardened runtime; the only Mach-O is
        # Contents/MacOS/keys, so the bundle is signed once without --deep.
        options += ['--options', 'runtime']
    run(*options, target)
    run('--verify', '--strict', '-R', f'=identifier "{IDENTIFIER}" and ' + APPLE_SIGNER, target)
    info = run('-dvv', target)
    match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', info.stderr, re.MULTILINE)
    if not match:
        raise SystemExit('Apple signing identity has no valid team ID; refusing this build.')
    req = designated_requirement(match[1])
    run(*options, '--requirements', '=designated => ' + req, target)
    run('--verify', '--strict', '-R', '=' + req, target)
    return match[1]


def local_identity():
    identity = os.environ.get('KEYS_SIGNING_IDENTITY')
    if not identity and CONFIG.exists():
        identity = CONFIG.read_text().strip()
    if not identity or not re.fullmatch(r'[0-9a-fA-F]{40}', identity):
        raise SystemExit('A persistent Apple signing certificate is required. Set KEYS_SIGNING_IDENTITY to its 40-character SHA-1 from security find-identity -v -p codesigning. No ad-hoc fallback is allowed.')
    return identity


def main(target):
    team = sign(target, local_identity())
    print('Signed with stable Apple team ' + team + '.')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: sign-local.py BINARY|Keysrs.app')
    try:
        main(sys.argv[1])
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stderr or 'Code signing failed; no ad-hoc fallback performed.')
