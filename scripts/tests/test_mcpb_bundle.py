#!/usr/bin/env python3
"""The MCPB bundle and server.json that publish Keysrs to the MCP Registry.

Offline and file-only: versions equal AppVersion.current, the registry entry
names the GitHub release asset of the same version, and its fileSha256 is the
hash of the bundle scripts/build-mcpb.py produces from this checkout (the zip is
deterministic, so a changed launcher, manifest or icon fails here until
server.json is updated). Nothing is published or installed.
"""
import hashlib
import importlib.util
import json
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
BUNDLE = REPO / "packaging" / "mcpb"
MANIFEST = BUNDLE / "manifest.json"
SERVER_JSON = REPO / "server.json"
PLUGIN_MANIFEST = REPO / "plugins" / "keysrs" / ".claude-plugin" / "plugin.json"
APP_BINARY = "/Applications/Keysrs.app/Contents/MacOS/keys"


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_builder():
    spec = importlib.util.spec_from_file_location("build_mcpb", REPO / "scripts" / "build-mcpb.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def app_version():
    return load_builder().app_version()


class McpbBundleTests(unittest.TestCase):
    def test_manifest_carries_the_app_version_and_plugin_identity(self):
        manifest, plugin = load(MANIFEST), load(PLUGIN_MANIFEST)
        self.assertEqual(manifest["version"], app_version(), "bump packaging/mcpb/manifest.json with AppVersion")
        for key in ("name", "description", "license", "keywords", "homepage"):
            self.assertEqual(manifest[key], plugin[key], key)
        self.assertEqual(manifest["display_name"], plugin["displayName"])
        self.assertEqual(manifest["repository"]["url"], plugin["repository"])

    def test_icon_is_the_brand_png(self):
        self.assertEqual((BUNDLE / load(MANIFEST)["icon"]).read_bytes(),
                         (REPO / "Assets/icon/png/keysrs-icon-256.png").read_bytes())

    def test_manifest_is_macos_only_and_runs_the_installed_app_via_the_launcher(self):
        manifest = load(MANIFEST)
        self.assertEqual(manifest["compatibility"]["platforms"], ["darwin"])
        server = manifest["server"]
        self.assertEqual(server["type"], "binary")
        self.assertTrue((BUNDLE / server["entry_point"]).is_file())
        self.assertEqual(server["mcp_config"]["command"], "/bin/sh")
        self.assertEqual(server["mcp_config"]["args"], ["${__dirname}/" + server["entry_point"]])

    def test_manifest_holds_no_secret_setting_or_environment(self):
        manifest = load(MANIFEST)
        self.assertNotIn("user_config", manifest)
        self.assertNotIn("env", manifest["server"]["mcp_config"])
        self.assertNotIn("platform_overrides", manifest["server"]["mcp_config"])

    def test_launcher_execs_keys_mcp_and_says_why_when_the_app_is_missing(self):
        launcher = (BUNDLE / "server" / "launch.sh").read_text(encoding="utf-8")
        self.assertIn(f"APP={APP_BINARY}\n", launcher)
        self.assertIn('exec "$APP" mcp', launcher)
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "launch.sh"
            copy.write_text(launcher.replace(f"APP={APP_BINARY}", f"APP={tmp}/missing/keys"), encoding="utf-8")
            result = subprocess.run(["/bin/sh", str(copy)], capture_output=True, text=True,
                                    stdin=subprocess.DEVNULL, timeout=20)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("Keysrs.app is not installed", result.stderr)

    def test_build_is_deterministic_and_holds_only_the_bundle_files(self):
        builder = load_builder()
        with tempfile.TemporaryDirectory() as tmp:
            first, second = Path(tmp) / "a" / "Keysrs.mcpb", Path(tmp) / "b" / "Keysrs.mcpb"
            self.assertEqual(builder.build(first), builder.build(second))
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with zipfile.ZipFile(first) as bundle:
                self.assertIsNone(bundle.testzip())
                self.assertEqual(sorted(bundle.namelist()), ["icon.png", "manifest.json", "server/launch.sh"])
                self.assertEqual(bundle.read("manifest.json"), MANIFEST.read_bytes())
                mode = bundle.getinfo("server/launch.sh").external_attr >> 16
                self.assertEqual(mode & 0o111, 0o111, "launcher must stay executable")

    def test_server_json_matches_the_app_version_and_the_release_asset(self):
        server, version = load(SERVER_JSON), app_version()
        self.assertEqual(server["version"], version, "bump server.json with AppVersion")
        (package,) = server["packages"]
        self.assertEqual(package["registryType"], "mcpb")
        self.assertEqual(package["transport"], {"type": "stdio"})
        self.assertEqual(package["identifier"],
                         f"https://github.com/gshost1/Keysreallysafe/releases/download/v{version}/Keysrs.mcpb")

    def test_server_json_names_the_github_namespace_and_the_same_product(self):
        server, plugin = load(SERVER_JSON), load(PLUGIN_MANIFEST)
        self.assertEqual(server["name"], "io.github.gshost1/keysrs")
        self.assertRegex(server["name"], r"^[a-zA-Z0-9.-]+/[a-zA-Z0-9._-]+$")
        self.assertLessEqual(len(server["description"]), 100)  # registry limit
        self.assertEqual(server["repository"], {"url": plugin["repository"], "source": "github"})
        self.assertEqual(server["websiteUrl"], plugin["homepage"])

    def test_server_json_checksum_is_the_hash_of_the_bundle_built_from_this_checkout(self):
        (package,) = load(SERVER_JSON)["packages"]
        self.assertRegex(package["fileSha256"], r"^[a-f0-9]{64}$")
        with tempfile.TemporaryDirectory() as tmp:
            built = load_builder().build(Path(tmp) / "Keysrs.mcpb")
            self.assertEqual(hashlib.sha256((Path(tmp) / "Keysrs.mcpb").read_bytes()).hexdigest(), built)
        self.assertEqual(package["fileSha256"], built,
                         "run scripts/build-mcpb.py and paste its SHA-256 into server.json")

    def test_release_checklist_covers_the_registry_steps(self):
        release = (REPO / "docs" / "release.md").read_text(encoding="utf-8")
        for needle in ("scripts/build-mcpb.py", "Keysrs.mcpb", "fileSha256", "mcp-publisher login github",
                       "mcp-publisher publish", "test_mcpb_bundle"):
            self.assertIn(needle, release)


if __name__ == "__main__":
    unittest.main()
