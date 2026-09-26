#!/usr/bin/env python3
"""Offline fixtures for scripts/prepare-release.py."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "prepare-release.py"
SPEC = importlib.util.spec_from_file_location("prepare_release", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(release)
build_app = release.build_app

sys.path.insert(0, str(HERE))
from test_build_app import FakeTools, make_repo  # noqa: E402

APP = "Keysrs.app"


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = make_repo(self.root)
        # Private files and optimizer leftovers in the checkout must never travel.
        (self.repo / "local-config.json").write_text("credential", encoding="utf-8")
        (self.repo / "Plugins" / "jev-optimizer").mkdir(parents=True)
        (self.repo / "Plugins" / "jev-optimizer" / "optimizer-cli.js").write_text("stale", encoding="utf-8")
        with mock.patch.object(build_app, "run_tool", FakeTools()):
            self.app = build_app.build(self.repo, self.repo / "build" / "keys", self.repo / "dist")

    def prepare(self, name="release", **kwargs):
        output = self.root / name
        release.prepare(self.repo, self.app, output, check_codesign=False, **kwargs)
        return output

    def test_package_holds_the_app_and_applications_link(self):
        output = self.prepare()
        self.assertEqual(sorted(p.name for p in output.iterdir()),
                         [".release-manifest.json", "Applications", APP])
        self.assertTrue((output / "Applications").is_symlink())
        self.assertEqual(os.readlink(output / "Applications"), "/Applications")
        packaged = output / APP / "Contents" / "MacOS" / "keys"
        self.assertEqual(packaged.read_bytes(), b"fixture executable")
        self.assertTrue(os.access(packaged, os.X_OK))
        manifest_text = (output / ".release-manifest.json").read_text(encoding="utf-8")
        manifest = json.loads(manifest_text)
        paths = {item["path"] for item in manifest["checksums"]}
        self.assertEqual({p.split("/", 1)[0] for p in paths}, {APP})
        self.assertEqual(manifest["symlinks"], {"Applications": "/Applications"})
        self.assertNotIn("fixture executable", manifest_text)
        self.assertNotIn("credential", manifest_text)
        self.assertNotIn("optimizer", manifest_text)
        self.assertEqual(manifest["release_status"]["live_installation"],
                         "unvalidated; this tool did not inspect or modify a live installation")
        self.assertEqual(manifest["codesign_verification"]["requested"], "false")
        release.verify_package(output)

    def test_licence_files_ship_inside_the_app(self):
        output = self.prepare()
        # Legal notices must survive packaging independently of the allowlist definition.
        for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md", "licenses/Keysreallysafe-legacy-MIT.txt",
                       "licenses/swift-argument-parser.txt"):
            packaged = output / APP / "Contents" / "Resources" / notice
            self.assertEqual(packaged.read_bytes(), (self.repo / notice).read_bytes())

    def test_rejects_app_whose_licence_differs_from_the_checkout(self):
        (self.app / "Contents" / "Resources" / "licenses" / "Keysreallysafe-legacy-MIT.txt").write_text(
            "edited", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "differs from the checkout"):
            self.prepare()

    def test_rejects_app_missing_a_licence(self):
        (self.app / "Contents" / "Resources" / "THIRD_PARTY_NOTICES.md").unlink()
        with self.assertRaisesRegex(release.ReleaseError, "missing required file"):
            self.prepare()

    def test_rejects_unsigned_app(self):
        (self.app / "Contents" / "_CodeSignature" / "CodeResources").unlink()
        with self.assertRaisesRegex(release.ReleaseError, "not signed"):
            self.prepare()

    def test_rejects_unexpected_or_symlinked_app_content(self):
        stray = self.app / "Contents" / "Resources" / "local-config.json"
        stray.write_text("credential", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "unexpected file"):
            self.prepare()
        stray.unlink()
        index = self.app / "Contents" / "Resources" / "Web" / "index.html"
        index.unlink()
        index.symlink_to(self.repo / "Web" / "index.html")
        with self.assertRaisesRegex(release.ReleaseError, "symlink"):
            self.prepare()

    def test_rejects_wrong_bundle_identifier_or_version(self):
        plist = self.app / "Contents" / "Info.plist"
        with plist.open("rb") as handle:
            info = plistlib.load(handle)
        info["CFBundleIdentifier"] = "com.example.other"
        with plist.open("wb") as handle:
            plistlib.dump(info, handle)
        with self.assertRaisesRegex(release.ReleaseError, "CFBundleIdentifier"):
            self.prepare()
        info["CFBundleIdentifier"] = "com.keysreallysafe.keysrs"
        info["CFBundleVersion"] = "0.9.2"
        with plist.open("wb") as handle:
            plistlib.dump(info, handle)
        with self.assertRaisesRegex(release.ReleaseError, "CFBundleVersion"):
            self.prepare()

    def test_rejects_symlinked_app(self):
        linked = self.root / APP
        linked.symlink_to(self.app, target_is_directory=True)
        with self.assertRaisesRegex(release.ReleaseError, "non-symlink"):
            release.prepare(self.repo, linked, self.root / "release", check_codesign=False)

    def test_refuses_existing_output_without_overwriting_it(self):
        output = self.root / "release"
        output.mkdir()
        marker = output / "keep.txt"
        marker.write_text("keep", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "must not already exist"):
            self.prepare()
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")

    def test_refuses_dangling_output_symlink(self):
        (self.root / "release").symlink_to(self.root / "missing-release", target_is_directory=True)
        with self.assertRaisesRegex(release.ReleaseError, "must not already exist"):
            self.prepare()

    def test_dry_run_validates_without_creating_output(self):
        self.prepare(dry_run=True)
        self.assertFalse((self.root / "release").exists())

    def test_verify_package_rejects_tampering_missing_and_unexpected_files(self):
        output = self.prepare()
        (output / APP / "Contents" / "Resources" / "Web" / "index.html").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "checksum mismatch"):
            release.verify_package(output)
        fresh = self.prepare("fresh")
        (fresh / APP / "Contents" / "Resources" / "Web" / "index.html").unlink()
        with self.assertRaisesRegex(release.ReleaseError, "missing manifest file"):
            release.verify_package(fresh)
        extra = self.prepare("extra")
        (extra / "extra.txt").write_text("unexpected", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "unexpected file"):
            release.verify_package(extra)

    def test_verify_package_accepts_only_the_applications_link(self):
        output = self.prepare()
        (output / "Applications").unlink()
        (output / "Applications").symlink_to("/tmp")
        with self.assertRaisesRegex(release.ReleaseError, "unexpected symlink"):
            release.verify_package(output)
        (output / "Applications").unlink()
        with self.assertRaisesRegex(release.ReleaseError, "Applications symlink"):
            release.verify_package(output)
        other = self.prepare("other")
        (other / "Docs").symlink_to("/Applications")
        with self.assertRaisesRegex(release.ReleaseError, "unexpected symlink"):
            release.verify_package(other)

    def test_codesign_check_reports_identifier(self):
        def fake_run(command, **kwargs):
            stderr = "Executable=x\nIdentifier=keysreallysafe\nTeamIdentifier=ABCDE12345\n"
            return subprocess.CompletedProcess(command, 0, "", stderr if "--display" in command else "")

        with mock.patch("subprocess.run", fake_run):
            result = release.verify_codesign(self.app)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["identifier"], "passed")

        def other_identifier(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, "", "Identifier=keys\n")

        with mock.patch("subprocess.run", other_identifier):
            result = release.verify_codesign(self.app)
        self.assertEqual(result["identifier"], "failed")
        self.assertEqual(result["status"], "not_verified")

    def test_dmg_uses_the_keysrs_volume_and_download_name(self):
        output = self.prepare()
        with self.assertRaisesRegex(release.ReleaseError, "Keysrs-arm64.dmg"):
            release.make_dmg(output, self.root / "Keysreallysafe-arm64.dmg")
        calls = []

        def fake_run(command, **kwargs):
            calls.append(list(command))
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch("subprocess.run", fake_run):
            release.make_dmg(output, self.root / "Keysrs-arm64.dmg")
        self.assertEqual(len(calls), 1)
        command = calls[0]
        self.assertEqual(command[:2], ["/usr/bin/hdiutil", "create"])
        self.assertEqual(command[command.index("-volname") + 1], "Keysrs")
        self.assertEqual(command[command.index("-srcfolder") + 1], str(output))
        self.assertEqual(command[-1], str(self.root / "Keysrs-arm64.dmg"))
        self.assertNotIn("codesign", " ".join(command))

    def test_cli_requires_app_and_output(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            release.parse_args(["--output", str(self.root / "release")])
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            release.parse_args(["--app", str(self.app), "--output", "x", "--dry-run", "--dmg", "Keysrs-arm64.dmg"])


if __name__ == "__main__":
    unittest.main()
