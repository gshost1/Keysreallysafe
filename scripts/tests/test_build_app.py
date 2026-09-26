#!/usr/bin/env python3
"""Offline fixtures for scripts/build-app.py: fake binary, temp dirs, mocked tools."""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "build-app.py"
SPEC = importlib.util.spec_from_file_location("build_app", SCRIPT)
build_app = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(build_app)

TEAM = "ABCDE12345"
FAKE_IDENTITY = "0" * 40  # never a real certificate; subprocess is mocked wherever it is used


def make_repo(directory: Path, version: str = "0.10.0") -> Path:
    repo = directory / "repo"
    for relative in build_app.WEB_FILES:
        target = repo / "Web" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"web {relative}", encoding="utf-8")
    for relative in build_app.FIXTURE_FILES:
        target = repo / "Fixtures" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"fixture {relative}", encoding="utf-8")
    for name in build_app.LICENSE_FILES:
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"licence {name}", encoding="utf-8")
    source = repo / build_app.VERSION_SOURCE
    source.parent.mkdir(parents=True)
    source.write_text(f'enum ProductAnalytics {{\n    static let appVersion = "{version}"\n}}\n', encoding="utf-8")
    icns = repo / "Assets" / "Keysrs.icns"
    icns.parent.mkdir(parents=True)
    icns.write_bytes(b"icns fixture")
    binary = repo / "build" / "keys"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"fixture executable")
    os.chmod(binary, 0o755)
    return repo


class FakeTools:
    """Stands in for sips, iconutil and codesign; records every command."""

    def __init__(self, width: int = 512):
        self.width = width
        self.commands: list[list[str]] = []

    def __call__(self, command):
        self.commands.append(list(command))
        tool = Path(command[0]).name
        stdout = ""
        if tool == "sips" and "-g" in command:
            stdout = f"{command[-1]}\n  pixelWidth: {self.width}\n"
        elif tool == "sips":
            Path(command[-1]).write_bytes(b"png")
        elif tool == "iconutil":
            Path(command[command.index("-o") + 1]).write_bytes(b"icns")
        elif tool == "codesign":
            seal = Path(command[-1]) / "Contents" / "_CodeSignature" / "CodeResources"
            seal.parent.mkdir(parents=True, exist_ok=True)
            seal.write_text("seal", encoding="utf-8")
        return subprocess.CompletedProcess(command, 0, stdout, "")


def files_under(root: Path) -> set:
    return {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}


class BuildAppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = make_repo(self.root)
        self.binary = self.repo / "build" / "keys"
        self.output = self.root / "out"
        self.tools = FakeTools()
        patcher = mock.patch.object(build_app, "run_tool", self.tools)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def build(self, **kwargs):
        return build_app.build(self.repo, self.binary, self.output, **kwargs)

    def test_layout_matches_the_shared_contract(self):
        app = self.build()
        self.assertEqual(app, self.output / "Keysrs.app")
        expected = {"Contents/Info.plist", "Contents/MacOS/keys", "Contents/Resources/Keysrs.icns",
                    "Contents/_CodeSignature/CodeResources"}
        expected |= {f"Contents/Resources/Web/{n}" for n in build_app.WEB_FILES}
        expected |= {"Contents/Resources/Fixtures/models.json"}
        expected |= {"Contents/Resources/LICENSE", "Contents/Resources/THIRD_PARTY_NOTICES.md",
                     "Contents/Resources/licenses/Keysreallysafe-legacy-MIT.txt",
                     "Contents/Resources/licenses/swift-argument-parser.txt"}
        self.assertEqual(files_under(app), expected)
        executable = app / "Contents" / "MacOS" / "keys"
        self.assertEqual(executable.read_bytes(), b"fixture executable")
        self.assertTrue(os.access(executable, os.X_OK))
        self.assertEqual([p.name for p in self.output.iterdir()], ["Keysrs.app"])

    def test_info_plist_keys(self):
        app = self.build()
        with (app / "Contents" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["CFBundleIdentifier"], "com.keysreallysafe.keysrs")
        self.assertEqual(info["CFBundleName"], "Keysrs")
        self.assertEqual(info["CFBundleDisplayName"], "Keysrs")
        self.assertEqual(info["CFBundleExecutable"], "keys")
        self.assertEqual(info["CFBundleIconFile"], "Keysrs")
        self.assertEqual(info["CFBundleShortVersionString"], "0.10.0")
        self.assertEqual(info["CFBundleVersion"], "0.10.0")
        self.assertEqual(info["CFBundlePackageType"], "APPL")
        self.assertEqual(info["LSMinimumSystemVersion"], "14.0")
        self.assertIs(info["NSHighResolutionCapable"], True)
        self.assertEqual(info["LSApplicationCategoryType"], "public.app-category.developer-tools")
        self.assertNotIn("LSUIElement", info)  # a regular app with a Dock icon

    def test_version_override_and_bad_version(self):
        app = self.build(version="1.2.3")
        with (app / "Contents" / "Info.plist").open("rb") as handle:
            self.assertEqual(plistlib.load(handle)["CFBundleVersion"], "1.2.3")
        with self.assertRaisesRegex(build_app.BuildError, "version must look like"):
            self.build(version="1.2", replace=True)

    def test_licence_files_ship_byte_for_byte(self):
        app = self.build()
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "licenses/Keysreallysafe-legacy-MIT.txt",
                     "licenses/swift-argument-parser.txt"):
            self.assertEqual((app / "Contents" / "Resources" / name).read_bytes(),
                             (self.repo / name).read_bytes())

    def test_missing_licence_refuses_to_build(self):
        (self.repo / "licenses" / "Keysreallysafe-legacy-MIT.txt").unlink()
        with self.assertRaisesRegex(build_app.BuildError, "licence file"):
            self.build()
        self.assertFalse((self.output / "Keysrs.app").exists())

    def test_ad_hoc_signing_passes_the_frozen_identifier_once(self):
        self.build()
        signs = [c for c in self.tools.commands if Path(c[0]).name == "codesign"]
        self.assertEqual(len(signs), 1)
        command = signs[0]
        self.assertEqual(command[command.index("--identifier") + 1], "keysreallysafe")
        self.assertEqual(command[command.index("--sign") + 1], "-")
        self.assertIn("runtime", command)
        self.assertNotIn("--deep", command)
        self.assertTrue(command[-1].endswith("Keysrs.app"))

    def test_identity_signing_uses_runtime_timestamp_and_team_requirement(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(list(command))
            stderr = f"Identifier=keysreallysafe\nTeamIdentifier={TEAM}\n" if "-dvv" in command else ""
            if "--sign" in command:
                FakeTools()([command[0], command[-1]])
            return subprocess.CompletedProcess(command, 0, "", stderr)

        with mock.patch("subprocess.run", fake_run):
            app = self.build(identity=FAKE_IDENTITY)
        signs = [c for c in calls if "--sign" in c]
        self.assertEqual(len(signs), 2)
        for command in signs:
            self.assertEqual(command[0], "/usr/bin/codesign")
            self.assertEqual(command[command.index("--identifier") + 1], "keysreallysafe")
            self.assertEqual(command[command.index("--sign") + 1], FAKE_IDENTITY)
            self.assertEqual(command[command.index("--options") + 1], "runtime")
            self.assertIn("--timestamp", command)
            self.assertNotIn("--deep", command)
        requirement = signs[1][signs[1].index("--requirements") + 1]
        self.assertIn(f'identifier "keysreallysafe" and certificate leaf[subject.OU] = "{TEAM}"', requirement)
        self.assertTrue(app.is_dir())

    def test_rejects_a_malformed_identity(self):
        with self.assertRaisesRegex(build_app.BuildError, "40-character"):
            self.build(identity="Developer ID Application: Someone")

    def test_rejects_symlinked_inputs(self):
        linked = self.repo / "linked-keys"
        linked.symlink_to(self.binary)
        with self.assertRaisesRegex(build_app.BuildError, "symlink"):
            build_app.build(self.repo, linked, self.output)
        web = self.repo / "Web"
        web.rename(self.repo / "Web-real")
        web.symlink_to(self.repo / "Web-real", target_is_directory=True)
        with self.assertRaisesRegex(build_app.BuildError, "symlink ancestor"):
            self.build()
        web.unlink()
        (self.repo / "Web-real").rename(web)
        index = web / "index.html"
        index.unlink()
        index.symlink_to(web / "app.js")
        with self.assertRaisesRegex(build_app.BuildError, "symlink"):
            self.build()

    def test_rejects_web_files_missing_from_the_allowlist(self):
        (self.repo / "Web" / ".DS_Store").write_bytes(b"finder")
        self.build()  # hidden files are ignored
        (self.repo / "Web" / "window.js").write_text("new", encoding="utf-8")
        with self.assertRaisesRegex(build_app.BuildError, "window.js is not in WEB_FILES"):
            self.build(replace=True)

    def test_rejects_non_executable_binary(self):
        os.chmod(self.binary, 0o644)
        with self.assertRaisesRegex(build_app.BuildError, "not executable"):
            self.build()

    def test_refuses_existing_app_unless_replace(self):
        app = self.build()
        (app / "stale").write_text("old", encoding="utf-8")
        with self.assertRaisesRegex(build_app.BuildError, "already exists"):
            self.build()
        self.assertTrue((app / "stale").exists())
        self.build(replace=True)
        self.assertFalse((app / "stale").exists())
        self.assertEqual([p.name for p in self.output.iterdir()], ["Keysrs.app"])

    def test_refuses_symlinked_output_app(self):
        self.output.mkdir()
        (self.output / "Keysrs.app").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(build_app.BuildError, "non-directory"):
            self.build(replace=True)

    def test_icon_sizes_never_exceed_the_source(self):
        self.build()
        resized = [c for c in self.tools.commands if Path(c[0]).name == "sips" and "-z" in c]
        pixels = sorted({int(c[c.index("-z") + 1]) for c in resized})
        self.assertEqual(pixels, [16, 32, 64, 128, 256, 512])
        names = {Path(c[-1]).name for c in resized}
        self.assertIn("icon_256x256@2x.png", names)
        self.assertNotIn("icon_512x512@2x.png", names)
        self.assertTrue(any(Path(c[0]).name == "iconutil" for c in self.tools.commands))

    def test_designed_icon_set_is_the_default(self):
        designed = self.repo / "Assets" / "icon" / "Keysrs.icns"
        designed.parent.mkdir(parents=True)
        designed.write_bytes(b"designed icns")
        app = self.build()
        self.assertEqual((app / "Contents" / "Resources" / "Keysrs.icns").read_bytes(), b"designed icns")

    def test_prebuilt_icns_skips_icon_tools(self):
        app = self.build(icns=self.repo / "Assets" / "Keysrs.icns")
        self.assertEqual((app / "Contents" / "Resources" / "Keysrs.icns").read_bytes(), b"icns fixture")
        self.assertFalse(any(Path(c[0]).name in ("sips", "iconutil") for c in self.tools.commands))

    def test_failed_signing_leaves_no_partial_app(self):
        def failing(command):
            if Path(command[0]).name == "codesign":
                raise build_app.BuildError("codesign failed: fixture")
            return self.tools(command)

        with mock.patch.object(build_app, "run_tool", failing):
            with self.assertRaisesRegex(build_app.BuildError, "codesign failed"):
                self.build()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_reads_version_from_product_analytics(self):
        self.assertEqual(build_app.read_version(self.repo), "0.10.0")

    @unittest.skipUnless(Path("/usr/bin/iconutil").exists() and Path("/usr/bin/sips").exists(),
                         "sips/iconutil not available")
    def test_real_icon_tools_build_an_icns(self):
        source = Path(__file__).resolve().parents[2] / "Web" / "icon.png"
        if not source.is_file():
            self.skipTest("Web/icon.png not in this checkout")
        destination = self.root / "Keysrs.icns"
        work = self.root / "work"
        work.mkdir()
        with mock.patch.object(build_app, "run_tool", REAL_RUN_TOOL):
            build_app.build_icns(source, destination, work)
        self.assertTrue(destination.read_bytes().startswith(b"icns"))


REAL_RUN_TOOL = build_app.run_tool


if __name__ == "__main__":
    unittest.main()
