# Offline optimizer release preparation

`scripts/prepare-optimizer-release.py` creates a new, self-contained release
candidate directory from an already-built `keys` executable. Its default mode
is offline: it only reads the checkout and writes the requested new directory.
It does not sign, enumerate Keychain identities, start Keys, install or replace
the login item, invoke native authorization, or inspect a live installation.

The package has a strict runtime allowlist: `bin/keys`, the static Web files (including the Privacy dialog's `analytics.js`),
the `models.json` fixture catalog, the Jev plugin runtime (`dist`, `src`, `hooks`, and
selected plugin metadata), and `optimizer-mcp.py` plus `claude-with-jev.py`.
An explicit documentation allowlist includes the MIT license, main README,
signing guide, collector README, and the optimizer/provider/client/analytics
guides under `docs/`. Other local notes are excluded. Collector deployment
source is delivered separately; the application package does not deploy it.
It refuses symlinks in every packaged input. It does not package
`node_modules`, tests, development fixtures, `.env` files, or unlisted plugin
configuration, so local credentials and private configuration remain outside
the artifact.

Create a user-facing candidate in a new directory. Pick the built binary
explicitly; this script deliberately does not build one.

```sh
python3 scripts/prepare-optimizer-release.py \
  --binary .build/arm64-apple-macosx/release/keys \
  --output /Users/Shost2/Documents/Codex/2026-09-19/can-x20/outputs/keys-jev-release-candidate
```

The output path must not exist. The artifact contains `release-manifest.json`
with ordered SHA-256 checksums, byte counts, an explicit unvalidated signing
state, and an explicit unvalidated live-installation state. It intentionally
contains no source file contents and no timestamp, which keeps equivalent
inputs reproducible. The manifest does not checksum itself; it checks every
other delivered file to avoid a self-referential checksum.

For a separate, read-only local signing check, add `--verify-codesign`. That
option runs `/usr/bin/codesign --display --verbose=4` and
`/usr/bin/codesign --verify --strict` against the supplied binary with no
identity lookup or signing action. Its pass/fail result is recorded without
copying codesign output into the manifest.

Use `--dry-run` with the same `--binary` and `--output` arguments to check all
source prerequisites without creating the output directory. Use
`--verify-package PATH` later to verify the manifest and reject any missing,
changed, symlinked, or unexpected package file. It performs no signing,
Keychain access, or installation.

## Rollback

Preparing this artifact makes no live changes, so there is nothing to roll
back at that stage. Each artifact includes `ROLLBACK.md`. The existing installer
stages and validates before it stops the agent; if activation fails, it restores
the prior runtime. After a successful activation it retains one prior version
at `~/Library/Application Support/keysreallysafe/.previous/`. There is no
supported manual rollback command in this release tool. If recovery from a
successful activation is needed, first copy that verified `.previous` directory
to a safe location. Do this before using `keys autostart --remove`: normal
removal deletes `.previous` along with the installed runtime.

Do not hand-copy this release directory into an active application-support
runtime. Use the normal installer only after separately completing the signing
and target-machine checks described in `SIGNING.md`.
