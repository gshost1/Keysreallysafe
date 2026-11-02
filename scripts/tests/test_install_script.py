#!/usr/bin/env python3
"""Offline tests for Site/install, the `curl -fsSL https://keysrs.com/install | bash` script.

The script runs for real, but every tool it calls (uname, sw_vers, sysctl, curl, shasum,
hdiutil, codesign, ditto, pgrep, open) is a fake on PATH, and KEYSRS_APPS_DIR points it
at a scratch folder. Nothing touches the network, a disk image, /Applications or a
real signature.
"""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Site" / "install"
DMG_BYTES = b"pretend this is a disk image"
DMG_SHA = hashlib.sha256(DMG_BYTES).hexdigest()
RELEASE = "https://github.com/gshost1/Keysreallysafe/releases/latest/download"

FAKES = {
    "uname": '''#!/bin/sh
case "$1" in -s) echo "${FAKE_OS:-Darwin}" ;; -m) echo "${FAKE_ARCH:-arm64}" ;; *) echo "${FAKE_OS:-Darwin}" ;; esac
''',
    "sw_vers": '''#!/bin/sh
echo "${FAKE_MACOS:-15.1}"
''',
    "sysctl": '''#!/bin/sh
echo "${FAKE_SYSCTL_ARM64:-1}"
''',
    # the https argument is the URL, -o names the file; .sha256 is the checksum file
    "curl": '''#!/bin/sh
echo "curl $*" >> "$FAKE_STATE/calls"
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; https://*) url=$1 ;; esac; shift; done
case "$url" in
  *.sha256) [ -z "${FAKE_NO_SIDECAR:-}" ] || exit 22; cp "$FAKE_STATE/sidecar" "$out" ;;
  *) [ -z "${FAKE_NO_DMG:-}" ] || exit 22; cp "$FAKE_STATE/dmg" "$out" ;;
esac
''',
    "shasum": '''#!/bin/sh
echo "shasum $*" >> "$FAKE_STATE/calls"
exec "$FAKE_PYTHON" -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest() + "  " + sys.argv[1])' "$3"
''',
    "hdiutil": '''#!/bin/sh
echo "hdiutil $*" >> "$FAKE_STATE/calls"
case "$1" in
  attach)
    [ -z "${FAKE_ATTACH_FAIL:-}" ] || exit 1
    while [ $# -gt 0 ]; do [ "$1" = -mountpoint ] && mp=$2; shift; done
    [ -n "${FAKE_NO_APP_IN_DMG:-}" ] || cp -R "$FAKE_STATE/app_template" "$mp/Keysrs.app" ;;
  detach)
    [ -z "${FAKE_DETACH_FAIL:-}" ] || exit 1
    rm -rf "$2/Keysrs.app" ;;
esac
''',
    # Succeeds only when the bundle is "signed" the way the script requires, so the
    # requirement string the script sends is what is really under test.
    "codesign": '''#!/bin/sh
echo "codesign $*" >> "$FAKE_STATE/calls"
req=""; for a in "$@"; do case "$a" in --test-requirement=*) req=${a#--test-requirement==} ;; esac; done
[ "${FAKE_CODESIGN:-ok}" != invalid ] || exit 3
if [ -n "$req" ]; then
  echo "$req" > "$FAKE_STATE/requirement"
  case "$req" in *"identifier \\"${FAKE_SIGNED_ID:-keysreallysafe}\\""*) ;; *) exit 3 ;; esac
  case "$req" in *"leaf[subject.OU] = \\"${FAKE_SIGNED_TEAM:-YS9TM7MAA5}\\""*) ;; *) exit 3 ;; esac
fi
exit 0
''',
    "ditto": '''#!/bin/sh
echo "ditto $*" >> "$FAKE_STATE/calls"
[ -z "${FAKE_DITTO_FAIL:-}" ] || exit 1
cp -R "$1" "$2"
''',
    "pgrep": '''#!/bin/sh
echo "pgrep $*" >> "$FAKE_STATE/calls"
[ -n "${FAKE_RUNNING:-}" ] && { echo 4242; exit 0; }
exit 1
''',
    "open": '''#!/bin/sh
echo "open $*" >> "$FAKE_STATE/calls"
''',
}

GOOD_SIDECAR = f"{DMG_SHA}  Keysrs-arm64.dmg\n"


class InstallScriptTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="keysrs-install-test-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.bin = self.root / "bin"
        self.state = self.root / "state"
        self.apps = self.root / "Applications"
        self.tmp = self.root / "tmp"
        for d in (self.bin, self.state, self.apps, self.tmp):
            d.mkdir()
        for name, body in FAKES.items():
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        (self.state / "dmg").write_bytes(DMG_BYTES)
        (self.state / "sidecar").write_text(GOOD_SIDECAR)
        template = self.state / "app_template"
        (template / "Contents").mkdir(parents=True)
        (template / "Contents" / "marker").write_text("new build")

    def run_script(self, script=None, shell="bash", **env):
        full = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.root),
            "TMPDIR": str(self.tmp),
            "KEYSRS_APPS_DIR": str(self.apps),
            "FAKE_STATE": str(self.state),
            "FAKE_PYTHON": sys.executable,
        }
        full.update({k: str(v) for k, v in env.items()})
        return subprocess.run([shell, str(script or SCRIPT)], env=full, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=60)

    def calls(self):
        log = self.state / "calls"
        return log.read_text().splitlines() if log.exists() else []

    def called(self, prefix):
        return [c for c in self.calls() if c.startswith(prefix)]

    def dmg_fetches(self):
        return [c for c in self.called("curl") if not c.endswith(".sha256")]

    def put_old_app(self):
        old = self.apps / "Keysrs.app" / "Contents"
        old.mkdir(parents=True)
        (old / "marker").write_text("old build")
        return old / "marker"

    def assertRefused(self, result, text):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(text, result.stderr)
        self.assertFalse((self.apps / "Keysrs.app").exists(), "nothing may be installed")
        self.assertFalse((self.apps / ".Keysrs.app.incoming").exists(), "no staging left behind")

    def assertCleanedUp(self):
        self.assertEqual(list(self.tmp.iterdir()), [], "the temporary folder must be removed")
        self.assertEqual(len(self.called("hdiutil attach")), len(self.called("hdiutil detach")),
                         "every mount must be detached")

    # ---- the script's shape --------------------------------------------------------

    def test_syntax_under_bash_and_sh(self):
        for shell in ("bash", "sh"):
            r = subprocess.run([shell, "-n", str(SCRIPT)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, f"{shell} -n: {r.stderr}")

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck is not installed")
    def test_shellcheck(self):
        r = subprocess.run(["shellcheck", "-s", "sh", "-S", "warning", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_everything_runs_from_main_on_the_last_line(self):
        lines = SCRIPT.read_text().splitlines()
        self.assertEqual(lines[-1], 'main "$@"')
        allowed = re.compile(r'^(#|$|[A-Z_]+=|set |[a-z_0-9]+\(\) \{|\}|main "\$@"$)')
        for number, line in enumerate(lines, 1):
            if line and not line[0].isspace():
                self.assertRegex(line, allowed, f"line {number} runs outside a function: {line!r}")

    def test_never_uses_sudo(self):
        code = "\n".join(l for l in SCRIPT.read_text().splitlines() if not l.lstrip().startswith("#"))
        self.assertNotRegex(code, r"(?m)(^|[;&|(]|\bthen\b|\bdo\b|\belse\b)\s*sudo\s")

    def test_no_bare_variable_is_followed_by_a_non_ascii_character(self):
        # bash reads "$VAR…" as one name (the ellipsis bytes join it): a crash under set -u
        self.assertIsNone(re.search(r"\$[A-Za-z_][A-Za-z_0-9]*[^\x00-\x7f]", SCRIPT.read_text()))

    def test_a_cut_off_download_runs_nothing(self):
        lines = SCRIPT.read_text().splitlines()
        short = self.root / "short"
        short.write_text("\n".join(lines[:-1]) + "\n")  # cut just before the final call
        r = self.run_script(short)
        self.assertEqual(self.calls(), [])
        self.assertEqual(r.returncode, 0)
        for fraction in (0.3, 0.6, 0.9):  # cut inside a function: a syntax error, still nothing runs
            cut = self.root / f"cut{fraction}"
            cut.write_text("\n".join(lines[: int(len(lines) * fraction)]) + "\n")
            r = self.run_script(cut)
            self.assertEqual(self.calls(), [], f"cut at {fraction} ran something")

    # ---- platform ------------------------------------------------------------------

    def test_refuses_anything_but_macos(self):
        r = self.run_script(FAKE_OS="Linux")
        self.assertRefused(r, "not macOS")
        self.assertEqual(self.called("curl"), [])

    def test_refuses_intel_but_accepts_apple_silicon_under_rosetta(self):
        r = self.run_script(FAKE_ARCH="x86_64", FAKE_SYSCTL_ARM64="0")
        self.assertRefused(r, "Apple Silicon")
        self.assertEqual(self.called("curl"), [])
        r = self.run_script(FAKE_ARCH="x86_64", FAKE_SYSCTL_ARM64="1")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_refuses_macos_13_and_older_and_accepts_14(self):
        for version in ("13.6.9", "12.7", "11.0"):
            r = self.run_script(FAKE_MACOS=version)
            self.assertRefused(r, "macOS 14 or newer")
        self.assertEqual(self.called("curl"), [])
        r = self.run_script(FAKE_MACOS="14.0")
        self.assertEqual(r.returncode, 0, r.stderr)

    # ---- checksum ------------------------------------------------------------------

    def test_checksum_mismatch_is_refused_before_the_image_is_opened(self):
        (self.state / "sidecar").write_text("0" * 64 + "  Keysrs-arm64.dmg\n")
        r = self.run_script()
        self.assertRefused(r, "checksum does not match")
        self.assertEqual(self.called("hdiutil attach"), [], "an unverified download is never mounted")
        self.assertCleanedUp()

    def test_a_release_without_a_checksum_file_is_refused_before_the_download(self):
        r = self.run_script(FAKE_NO_SIDECAR=1)
        self.assertRefused(r, "does not publish a checksum")
        self.assertEqual(self.dmg_fetches(), [], "the DMG is not fetched")
        self.assertCleanedUp()

    def test_an_unreadable_checksum_file_is_refused(self):
        for text in ("", "not a checksum\n", "abc123  Keysrs-arm64.dmg\n", f"SHA256 (Keysrs-arm64.dmg) {DMG_SHA}\n"):
            (self.state / "sidecar").write_text(text)
            r = self.run_script()
            self.assertRefused(r, "checksum file could not be read")
            self.assertEqual(self.dmg_fetches(), [])

    def test_the_updaters_checksum_layouts_are_accepted(self):
        for text in (
            DMG_SHA + "\n",                                    # bare hash
            DMG_SHA.upper() + "  Keysrs-arm64.dmg\n",          # upper case
            f"SHA256 (Keysrs-arm64.dmg) = {DMG_SHA}\n",        # BSD layout
            f"a comment line\n{DMG_SHA}\ttab.dmg\n",           # first matching line wins
            f"{DMG_SHA}  Keysrs-arm64.dmg",                    # no trailing newline
        ):
            (self.state / "sidecar").write_text(text)
            shutil.rmtree(self.apps / "Keysrs.app", ignore_errors=True)
            r = self.run_script()
            self.assertEqual(r.returncode, 0, f"{text!r}: {r.stderr}")

    def test_the_download_is_hashed_with_sha256(self):
        self.run_script()
        self.assertTrue(any("-a 256" in c for c in self.called("shasum")))

    # ---- signature -----------------------------------------------------------------

    def test_wrong_signing_identifier_is_refused(self):
        r = self.run_script(FAKE_SIGNED_ID="com.example.other")
        self.assertRefused(r, "not signed as keysreallysafe by team YS9TM7MAA5")
        self.assertEqual(self.called("ditto"), [])
        self.assertCleanedUp()

    def test_wrong_team_is_refused(self):
        r = self.run_script(FAKE_SIGNED_TEAM="ABCDE12345")
        self.assertRefused(r, "not signed as keysreallysafe by team YS9TM7MAA5")
        self.assertEqual(self.called("ditto"), [])
        self.assertCleanedUp()

    def test_an_invalid_signature_is_refused(self):
        r = self.run_script(FAKE_CODESIGN="invalid")
        self.assertRefused(r, "code signature is not valid")
        self.assertEqual(self.called("ditto"), [])
        self.assertCleanedUp()

    def test_the_signature_check_is_strict_deep_and_pins_identifier_team_and_apple_chain(self):
        self.run_script()
        self.assertTrue(self.called("codesign --verify --deep --strict"))
        requirement = (self.state / "requirement").read_text()
        self.assertIn('identifier "keysreallysafe"', requirement)
        self.assertIn('certificate leaf[subject.OU] = "YS9TM7MAA5"', requirement)
        self.assertIn("anchor apple generic", requirement)
        self.assertIn("1.2.840.113635.100.6.2.6", requirement)  # the Developer ID CA field
        # the mounted app and the staged copy are both checked
        self.assertGreaterEqual(len(self.called("codesign --verify --strict --test-requirement")), 2)

    def test_the_requirement_matches_the_updaters_apple_signer_clause(self):
        swift = (SCRIPT.parents[1] / "Sources" / "KeysCore" / "StableSigning.swift").read_text()
        fields = re.findall(r"field\.[0-9.]+", swift.split("static func requirement")[0])
        self.run_script()
        requirement = (self.state / "requirement").read_text()
        self.assertEqual(re.findall(r"field\.[0-9.]+", requirement), fields)

    def test_the_image_must_hold_the_app(self):
        r = self.run_script(FAKE_NO_APP_IN_DMG=1)
        self.assertRefused(r, "does not contain Keysrs.app")
        self.assertCleanedUp()

    def test_an_image_that_will_not_mount_is_refused(self):
        r = self.run_script(FAKE_ATTACH_FAIL=1)
        self.assertRefused(r, "could not be opened as a disk image")
        self.assertCleanedUp()

    # ---- running app ---------------------------------------------------------------

    def test_a_running_app_is_not_replaced_and_nothing_is_downloaded(self):
        marker = self.put_old_app()
        r = self.run_script(FAKE_RUNNING=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Keysrs is running. Quit it", r.stderr)
        self.assertEqual(marker.read_text(), "old build")
        self.assertEqual(self.called("curl"), [])
        self.assertIn(f"{self.apps}/Keysrs.app/Contents/MacOS/", self.called("pgrep")[0])

    # ---- success -------------------------------------------------------------------

    def test_a_fresh_install_copies_the_app_cleans_up_and_opens_it(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.apps / "Keysrs.app" / "Contents" / "marker").read_text(), "new build")
        self.assertEqual(sorted(p.name for p in self.apps.iterdir()), ["Keysrs.app"],
                         "no staging or previous folder left")
        self.assertCleanedUp()
        self.assertEqual(self.called("open"), [f"open {self.apps}/Keysrs.app"])
        attach = self.called("hdiutil attach")[0]
        for flag in ("-nobrowse", "-readonly"):
            self.assertIn(flag, attach)
        self.assertEqual([c.split()[-1] for c in self.called("curl")],
                         [f"{RELEASE}/Keysrs-arm64.dmg.sha256", f"{RELEASE}/Keysrs-arm64.dmg"])
        for c in self.called("curl"):
            self.assertIn("-fsSL", c)

    def test_it_works_under_plain_sh_too(self):
        r = self.run_script(shell="sh")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.apps / "Keysrs.app").is_dir())

    def test_an_existing_app_that_is_not_running_is_replaced(self):
        marker = self.put_old_app()
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(marker.read_text(), "new build")
        self.assertEqual(sorted(p.name for p in self.apps.iterdir()), ["Keysrs.app"])
        self.assertCleanedUp()

    def test_a_failed_copy_leaves_the_old_app_and_no_litter(self):
        marker = self.put_old_app()
        r = self.run_script(FAKE_DITTO_FAIL=1)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Could not copy Keysrs", r.stderr)
        self.assertEqual(marker.read_text(), "old build")
        self.assertEqual(sorted(p.name for p in self.apps.iterdir()), ["Keysrs.app"])
        self.assertCleanedUp()

    def test_a_missing_applications_folder_is_a_clear_error(self):
        r = self.run_script(KEYSRS_APPS_DIR=self.root / "nope")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Cannot write to", r.stderr)
        self.assertIn("never uses sudo", r.stderr)
        self.assertEqual(self.called("curl"), [])

    def test_a_failed_eject_never_deletes_the_work_folder(self):
        r = self.run_script(FAKE_DETACH_FAIL=1)
        self.assertIn("could not eject the disk image", r.stderr)
        self.assertEqual(len(list(self.tmp.iterdir())), 1, "the folder holding the mount stays")

    def test_an_unexpected_failure_still_exits_nonzero(self):
        # an unset variable reports status 0 inside bash 3.2's EXIT trap; the script must still fail
        broken = self.root / "broken"
        broken.write_text(SCRIPT.read_text().replace('say "Checking the latest release…"', 'say "$NOPE"'))
        r = self.run_script(broken)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.dmg_fetches(), [])


if __name__ == "__main__":
    unittest.main()
