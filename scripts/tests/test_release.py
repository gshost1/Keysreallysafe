#!/usr/bin/env python3
"""Offline fixtures for scripts/prepare-release.py."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-release.py"
SPEC = importlib.util.spec_from_file_location("prepare_release", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def make_repo(self, directory: Path) -> Path:
        repo = directory / "repo"
        for relative in release.WEB_FILES:
            target = repo / "Web" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(relative, encoding="utf-8")
        for relative in release.FIXTURE_FILES:
            target = repo / "Fixtures" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(relative, encoding="utf-8")
        for name in release.DOC_FILES:
            target = repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(name, encoding="utf-8")
        binary = repo / "build" / "keys"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"fixture executable")
        os.chmod(binary, 0o755)
        return repo

    def test_packages_allowlisted_runtime_and_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_repo(root)
            # Files outside the allowlist never travel: a private local file, or optimizer
            # build output and scripts left over in an older checkout.
            (repo / "local-config.json").write_text("credential", encoding="utf-8")
            (repo / "Plugins" / "jev-optimizer" / "dist").mkdir(parents=True)
            (repo / "Plugins" / "jev-optimizer" / "dist" / "optimizer-cli.js").write_text("stale", encoding="utf-8")
            (repo / "scripts").mkdir(exist_ok=True)
            (repo / "scripts" / "optimizer-mcp.py").write_text("stale", encoding="utf-8")
            (repo / "docs" / "private-notes.md").write_text("private", encoding="utf-8")
            output = root / "release"
            release.prepare(repo, repo / "build" / "keys", output, check_codesign=False)
            self.assertTrue((output / "bin" / "keys").is_file())
            self.assertFalse((output / "Plugins").exists())
            self.assertFalse((output / "scripts").exists())
            self.assertFalse((output / "local-config.json").exists())
            self.assertTrue((output / "ROLLBACK.md").is_file())
            manifest = json.loads((output / "release-manifest.json").read_text(encoding="utf-8"))
            manifest_text = (output / "release-manifest.json").read_text(encoding="utf-8")
            paths = {item["path"] for item in manifest["checksums"]}
            self.assertIn("bin/keys", paths)
            self.assertTrue(set(release.DOC_FILES).issubset(paths))
            # A package is installed by someone without this checkout, so the install and
            # acceptance instructions have to travel inside it.
            # Legal notices must survive packaging independently of the allowlist definition.
            for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md",
                           "licenses/Keysreallysafe-legacy-MIT.txt",
                           "licenses/swift-argument-parser.txt"):
                self.assertIn(notice, paths)
                self.assertEqual((output / notice).read_bytes(), (repo / notice).read_bytes())
            self.assertIn("docs/mvp-quickstart.md", paths)
            self.assertIn("docs/mvp-acceptance.md", paths)
            self.assertTrue((output / "docs" / "mvp-quickstart.md").is_file())
            self.assertTrue((output / "docs" / "mvp-acceptance.md").is_file())
            self.assertFalse((output / "docs" / "private-notes.md").exists())
            self.assertTrue((output / "README.md").is_file())
            self.assertEqual({p.split("/", 1)[0] for p in paths},
                             {"bin", "Web", "Fixtures", "docs", "licenses", "Analytics", "LICENSE",
                              "THIRD_PARTY_NOTICES.md", "README.md", "SIGNING.md", "ROLLBACK.md"})
            self.assertNotIn("release-manifest.json", paths)
            self.assertNotIn("fixture executable", manifest_text)
            self.assertNotIn("credential", manifest_text)
            self.assertEqual(manifest["release_status"]["live_installation"],
                             "unvalidated; this tool did not inspect or modify a live installation")
            self.assertEqual(manifest["codesign_verification"]["requested"], "false")

    def test_rejects_binary_and_runtime_symlink_ancestors(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_repo(root)
            linked_binary = repo / "linked-keys"
            linked_binary.symlink_to(repo / "build" / "keys")
            with self.assertRaisesRegex(release.ReleaseError, "symlink ancestor"):
                release.prepare(repo, linked_binary, root / "release", check_codesign=False)
            linked_web = root / "linked-web"
            linked_web.symlink_to(repo / "Web", target_is_directory=True)
            original_web = repo / "Web"
            original_web.rename(repo / "Web-real")
            linked_web.rename(original_web)
            with self.assertRaisesRegex(release.ReleaseError, "symlink ancestor"):
                release.prepare(repo, repo / "build" / "keys", root / "release", check_codesign=False)

    def test_refuses_existing_output_without_overwriting_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_repo(root)
            output = root / "release"
            output.mkdir()
            marker = output / "keep.txt"
            marker.write_text("keep", encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError, "must not already exist"):
                release.prepare(repo, repo / "build" / "keys", output, check_codesign=False)
            self.assertEqual(marker.read_text(encoding="utf-8"), "keep")

    def test_refuses_dangling_output_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_repo(root)
            output = root / "release"
            output.symlink_to(root / "missing-release", target_is_directory=True)
            with self.assertRaisesRegex(release.ReleaseError, "must not already exist"):
                release.prepare(repo, repo / "build" / "keys", output, check_codesign=False)

    def test_dry_run_validates_without_creating_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_repo(root)
            output = root / "release"
            release.prepare(repo, repo / "build" / "keys", output, check_codesign=False, dry_run=True)
            self.assertFalse(output.exists())

    def test_verify_package_rejects_tampering_missing_and_unexpected_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self.make_repo(root)
            output = root / "release"
            release.prepare(repo, repo / "build" / "keys", output, check_codesign=False)
            target = output / "Web" / "index.html"
            target.write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError, "checksum mismatch"):
                release.verify_package(output)
            release.prepare(repo, repo / "build" / "keys", root / "fresh", check_codesign=False)
            fresh = root / "fresh"
            (fresh / "Web" / "index.html").unlink()
            with self.assertRaisesRegex(release.ReleaseError, "missing manifest file"):
                release.verify_package(fresh)
            release.prepare(repo, repo / "build" / "keys", root / "extra", check_codesign=False)
            extra = root / "extra"
            (extra / "extra.txt").write_text("unexpected", encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError, "unexpected file"):
                release.verify_package(extra)


if __name__ == "__main__":
    unittest.main()
