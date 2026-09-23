# MVP quickstart (private preview)

How to run a prepared Keys package on a second Mac. It covers only the
supported path: a package produced by `scripts/prepare-optimizer-release.py`,
verified, then started from its own directory. Nothing here asks you to disable
or work around a macOS security control.

## What this package is, and is not

- **Signed, and normally notarized.** The binary is signed with the owner's
  Developer ID certificate (see [the signing guide](../SIGNING.md)); signing is
  what gives the app a stable Keychain identity across updates. A delivered
  DMG is submitted to Apple for notarization and stapled, and the release
  folder keeps the submission status, the stapler and Gatekeeper logs and the
  digests beside it. The 2026-09-22 arm64 candidate was accepted by Gatekeeper
  on the build Mac and the second Mac.
- **Still a private hand-over.** There is no public download; a package reaches
  a second Mac directly from the owner with its digest. If a candidate arrives
  without notarization evidence, or macOS refuses to run it, record the exact
  message and stop; the release needs to satisfy the normal platform checks.

## Requirements

| | Required for | Notes |
|---|---|---|
| macOS 14 or newer | core app | `Package.swift` sets `platforms: [.macOS(.v14)]` |
| Matching CPU architecture | core app | the package carries one built binary; see the check below |
| Swift toolchain | **not** required | the recipient runs the delivered `bin/keys`; no build step |
| A checkout of this repository | **not** required on the target | the strict package verifier runs on the build Mac; the target uses `shasum`, `codesign`, `uname` and `file`, supplied with macOS |
| Node.js 18 or newer | optional Optimizer only | `Plugins/jev-optimizer/package.json` sets `engines.node >= 18` |
| `python3` | optional Optimizer only | `scripts/optimizer-mcp.py` and `scripts/claude-with-jev.py` |

The vault, the local gateway, the usage meter and the dashboard need none of the
optional rows. The Optimizer and Jev context compaction are **optional and
experimental**; see [the Jev optimizer](jev-optimizer.md).

## Who verifies what

Verification is split, because the strict package verifier lives in the
checkout and is not delivered inside the package.

**The owner, on the build Mac, before sending anything.** Run the strict check
against the prepared directory, then archive it and record the digest and the
signing and architecture metadata beside the archive:

```sh
python3 scripts/prepare-optimizer-release.py --verify-package /path/to/keys-package
/usr/bin/codesign --display --verbose=4 /path/to/keys-package/bin/keys
/usr/bin/lipo -archs /path/to/keys-package/bin/keys
ditto -c -k --sequesterRsrc --keepParent /path/to/keys-package keys-package.zip
shasum -a 256 keys-package.zip > keys-package.zip.sha256
```

`--verify-package` rejects a missing, changed, symlinked or unexpected file.
The `codesign` line is read-only: it displays, it never signs.

**The recipient, on the second Mac.** Everything here is built into macOS; no
checkout, no Python and no Swift toolchain is needed:

```sh
shasum -a 256 -c keys-package.zip.sha256     # must print: OK
ditto -x -k keys-package.zip .
cd keys-package
ls -l bin/keys Web/index.html release-manifest.json
/usr/bin/codesign --verify --strict bin/keys
/usr/bin/codesign --display --verbose=4 bin/keys
uname -m
file bin/keys
```

The digest must match the one the owner sent over a separate channel, and the
displayed signing identity must match the metadata they sent with it. The architecture
reported by `file bin/keys` must include the value from `uname -m` and agree
with the owner's metadata: `arm64` for Apple Silicon or `x86_64` for Intel.
Request a matching build if it does not.

## Run it

`keys` finds its web assets by walking up from the executable, so `bin/keys`
inside the package finds the sibling `Web/` directory. Run it from the package
directory and do not move `bin/keys` out on its own.

```sh
cd /path/to/keys-package
./bin/keys doctor
./bin/keys autostart
```

`doctor` prints local sources, the catalog, Keychain, gateway and autostart
state. `autostart` installs a per-user login item that serves
`http://127.0.0.1:12766/` and puts the menu bar item in place. If the assets are
somewhere else, `KEYS_WEB_ROOT=/path/to/Web ./bin/keys autostart` names them
explicitly; without either, the command fails with `Web/ not found`.

Re-run `./bin/keys autostart` after replacing the package: the login item serves
a snapshot of the binary and assets it was installed from.

To remove it:

```sh
./bin/keys autostart --remove
```

That unloads and deletes the login item and its snapshot. It also deletes the
retained previous version at
`~/Library/Application Support/keysreallysafe/.previous/`; copy that directory
somewhere safe first if you may want to go back (see
[optimizer release](optimizer-release.md)).

## First run on the new Mac

1. Open `http://127.0.0.1:12766/`. The Usage pane shows a short guide on a first
   run with an empty vault; it stays available under **?** in the toolbar.
2. **Add key** stores the secret in the macOS Keychain. Every read asks for
   Touch ID, with the login password fallback macOS offers. No key value is
   written into this repository, the package, or a `.env` file.
3. Use a key through the local gateway with a scoped grant (one key, one host, a
   method and path scope, an expiry) or hand it to one child process as an
   environment variable. A grant dies on screen lock, revoke, expiry, gateway
   off or restart.
4. The Chart pane's **API keys** scope shows what the local gateway routed, in
   tokens and requests by default; choose **USD** to price it from this repo's
   list-price table. That price is an estimate, never an invoice.

Existing keys created under an older ad-hoc build may ask once for a native
Keychain password approval with **Always Allow** for the newly signed app. Do
not disable Keychain access controls and do not allow all applications.

## Acceptance

The checks that must pass on the second Mac, and their current state, are in
[mvp-acceptance.md](mvp-acceptance.md). They are **pending**: none of them has
been run on a second Mac yet.
