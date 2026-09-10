# Stable signing and Keychain access

The old installer re-signed every build ad hoc. The affected key's read ACL and
Keychain partition both stored a previous executable's code hash. The current
executable failed validation against that saved ACL. This is separate from the
app's LocalAuthentication prompt.

An ordinary self-signed certificate is insufficient: macOS securityd assigns
non-Apple-issued signers a `cdhash:` partition even when their designated
requirement is stable. Apple Development and Developer ID signers use a stable
team partition. The implementation follows the signer classes in Apple's
[securityd source](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp).

## Build and install

Create an Apple Development or Developer ID Application certificate in Xcode's
Apple Accounts settings. Use `security find-identity -v -p codesigning` to find
its SHA-1 fingerprint. Save the chosen 40-character fingerprint alone to
`~/.config/keysreallysafe/signing-identity`, or set `KEYS_SIGNING_IDENTITY`.
No private key belongs in the repository; Xcode stores it in the login Keychain.

Run `make build`, then `.build/debug/keys autostart`. The installer copies the
signed binary unchanged and validates it before stopping the app. It refuses
ad-hoc builds, self-signed builds, and changes to an established signing team or
designated requirement. Migration from the old ad-hoc install is allowed once.
Keep the same team when renewing the certificate and update the fingerprint
configuration; the requirement deliberately does not pin an expiring leaf.

Existing keys may require a one-time native Keychain password approval using
**Always Allow** for the new app identity. The app's Touch ID gate still runs on
each secret read. Do not disable Keychain access controls or allow all apps.

## Validation

`python3 scripts/test-signing-upgrade.py` creates a separate disposable Keychain,
adds a synthetic item with build 1, replaces the executable with different build
2 at the same path, and reads with UI interaction disabled. It also requires an
explicit authorization failure for an unrelated signer. The temporary Keychain
is deleted afterward. It never reads vault secrets.

Run `KEYS_SIGNING_IDENTITY=<fingerprint> swift test --filter StableSigningTests`
outside a sandbox for the certificate-backed fresh install, upgrade, legacy
migration, and rejected ad-hoc downgrade checks. The ordinary suite skips this
positive signing test if the environment variable is absent.

2026-09-10 validation: 206 tests, zero failures (two skipped: legacy manual
Keychain test and certificate-dependent test). Then the four StableSigningTests
passed with the actual Developer ID certificate, including the previously
skipped positive test. The live two-build disposable-Keychain test passed;
both signed reads returned status 0 and the unrelated signer returned -25293.

The installed binary matched the signed build byte-for-byte. After one-time
Always Allow approval, the existing item’s saved ACL validated the installed
app and its partition list included the signing team. One-time Allow reads
did not persist either rule. Other existing items may need the same one-time
approval on their next read.
