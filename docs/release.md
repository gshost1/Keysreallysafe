# Release packaging

Keysrs ships as `Keysrs.app` inside `Keysrs-arm64.dmg`. The DMG window shows
the app and an `Applications` symlink, so installing is a drag. The file name
must stay `Keysrs-arm64.dmg`: the download links on keysrs.com point at the
latest GitHub release asset of that name.

Three scripts produce it. None of them notarizes, installs, launches the app
or touches a live installation.

1. `scripts/build-app.py` assembles and signs the bundle.
2. `scripts/prepare-release.py` checks the signed bundle against the checkout
   and stages the DMG contents with a checksum manifest.
3. The same script, with `--dmg`, packs that directory with `hdiutil`.

## Bundle layout

```
Keysrs.app/Contents/
  Info.plist                  CFBundleIdentifier com.keysreallysafe.keysrs, CFBundleExecutable keys
  MacOS/keys                  the one release binary: app with no arguments, CLI with arguments
  Resources/Web/              the dashboard allowlist (same files the installer used to stage)
  Resources/Fixtures/models.json
  Resources/Keysrs.icns       Assets/icon/Keysrs.icns (built from Web/icon.png only if missing)
  Resources/LICENSE, THIRD_PARTY_NOTICES.md, licenses/*.txt
  _CodeSignature/CodeResources
```

The bundle version comes from `ProductAnalytics.appVersion`. The code-signing
identifier is `keysreallysafe`, not the bundle identifier: Keychain items
trust the designated requirement
`identifier "keysreallysafe" and certificate leaf[subject.OU] = "<team>" and anchor apple generic and (...)`,
and that requirement must stay identical to the one 0.9.x shipped.

## Build the app

```sh
swift build -c release
python3 scripts/build-app.py                        # ad hoc, into .build/app/Keysrs.app
python3 scripts/build-app.py --sign <SHA-1> --replace  # Developer ID, for a release
```

Without `--sign` the bundle is signed ad hoc under the `keysreallysafe`
identifier. That runs on the build Mac but cannot read existing Keychain items
and cannot be distributed. With `--sign`, the fingerprint of a Developer ID
Application (or Apple Development) certificate, the script signs the bundle
once with the hardened runtime and a secure timestamp, reads the team, and
signs again pinning the designated requirement to that team. It never uses
`--deep`: `MacOS/keys` is the only Mach-O. Use `--icns` to supply a prebuilt
icon instead of `Assets/icon/Keysrs.icns`.

The script refuses symlinked or missing inputs, a non-executable binary and
anything outside the Web and fixture allowlists. It does not replace an
existing `Keysrs.app` unless `--replace` is given.

For a local install, `make app` builds the release binary, assembles the
bundle and re-signs it with the Apple Development identity from
`~/.config/keysreallysafe/signing-identity` through `scripts/sign-local.py`.
A locally signed bundle is not a notarized release.

Confirm the requirement before shipping:

```sh
codesign -dv .build/app/Keysrs.app        # Identifier=keysreallysafe
codesign -d -r- .build/app/Keysrs.app     # same designated requirement as 0.9.2
plutil -lint .build/app/Keysrs.app/Contents/Info.plist
```

## Stage the DMG contents

```sh
python3 scripts/prepare-release.py \
  --app .build/app/Keysrs.app \
  --output ~/Documents/Codex/<date>/<release>/Keysrs-arm64 \
  --verify-codesign \
  --dmg ~/Documents/Codex/<date>/<release>/Keysrs-arm64.dmg
```

`prepare-release.py` rejects a bundle that is unsigned, contains a symlink,
an unexpected file or an Info.plist that disagrees with the contract, or whose
Web files, price table or licence texts differ byte for byte from the
checkout. `LICENSE`, `THIRD_PARTY_NOTICES.md`,
`licenses/Keysreallysafe-legacy-MIT.txt` and
`licenses/swift-argument-parser.txt` must ship inside every app.

The output path must not exist. It receives `Keysrs.app`, the
`Applications -> /Applications` symlink and a hidden `.release-manifest.json`
with ordered SHA-256 checksums, byte counts, the one permitted symlink and
explicit unvalidated signing, notarization and live-installation states. It
contains no source file contents and no timestamp, so equivalent inputs
produce the same manifest.

`--verify-codesign` runs read-only `codesign --display` and
`codesign --verify --strict` on the bundle and records whether they passed and
whether the identifier is `keysreallysafe`, without copying codesign output
into the manifest. `--dry-run` runs every preflight without writing anything.
`--verify-package PATH` later rejects any missing, changed or unexpected file
and any symlink other than `Applications`; it works on a mounted DMG too.

`--dmg` runs `hdiutil create -volname Keysrs -fs APFS -format UDZO` on the
verified directory and refuses any file name other than `Keysrs-arm64.dmg`.
The DMG is unsigned.

## Sign, notarize and publish (manual)

These steps use the Developer ID identity and the notary profile and are not
automated here:

1. Build the styled DMG instead of `--dmg`: `scripts/build-dmg.sh <staged dir>
   <dir>/Keysrs-arm64.dmg`. It adds the volume icon, the background drawn by
   `scripts/dmg-background.swift` (name, pitch, an arrow from Keysrs to
   Applications) and a fixed Finder layout. Finder does the layout through
   AppleScript, so the first run asks for permission to control Finder, and no
   other `Keysrs` volume may be mounted. Build outside `~/Documents`: files
   there carry attributes codesign rejects. `--verify-package` rejects the
   extra `.VolumeIcon.icns`, `.background` and `.DS_Store`; compare the mounted
   `Keysrs.app` with the verified build using `diff -r` instead.
2. `codesign --sign <SHA-1> --timestamp Keysrs-arm64.dmg`, then
   `hdiutil verify`.
3. `xcrun notarytool submit Keysrs-arm64.dmg --keychain-profile <profile> --wait`,
   `xcrun stapler staple` and `stapler validate`, then
   `spctl -a -t open --context context:primary-signature Keysrs-arm64.dmg` and
   `spctl -a -t exec -vv` on the mounted `Keysrs.app`.
4. Only after those pass: tag and publish the GitHub release with the DMG
   under the same name.

## Upgrading from 0.9.x

0.9.x installed a launchd agent and a runtime under
`~/Library/Application Support/Keysreallysafe/`. The app migrates that on its
first launch; the packaging scripts do not touch it. `keys autostart --remove`
still cleans up an old install. Do not copy a release directory into the
application-support runtime by hand.
