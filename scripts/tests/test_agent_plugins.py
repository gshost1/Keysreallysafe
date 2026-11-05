#!/usr/bin/env python3
"""The Claude and Codex plugin bundle (plugins/keysrs) and its two marketplaces.

Offline and file-only: every manifest parses, every path it names exists, the
version is AppVersion.current, and the shipped skill and icon are byte copies
of their sources (the directory rejects symlinks, so the plugin folder has to
hold real files). Nothing here installs into a real Claude or Codex config.
"""
import json
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
PLUGIN = REPO / "plugins" / "keysrs"
CLAUDE_MANIFEST = PLUGIN / ".claude-plugin" / "plugin.json"
CODEX_MANIFEST = PLUGIN / ".codex-plugin" / "plugin.json"
CLAUDE_MARKET = REPO / ".claude-plugin" / "marketplace.json"
CODEX_MARKET = REPO / ".agents" / "plugins" / "marketplace.json"
APP_BINARY = "/Applications/Keysrs.app/Contents/MacOS/keys"


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def app_version():
    text = (REPO / "Sources/KeysCore/AppVersion.swift").read_text(encoding="utf-8")
    return re.search(r'static let current = "([^"]+)"', text).group(1)


class AgentPluginTests(unittest.TestCase):
    def test_manifests_carry_the_app_version(self):
        version = app_version()
        for path in (CLAUDE_MANIFEST, CODEX_MANIFEST):
            self.assertEqual(load(path)["version"], version, f"{path.relative_to(REPO)}: bump with AppVersion")

    def test_both_manifests_name_the_same_plugin(self):
        claude, codex = load(CLAUDE_MANIFEST), load(CODEX_MANIFEST)
        for key in ("name", "version", "description", "license"):
            self.assertEqual(claude[key], codex[key], key)
        self.assertEqual(claude["name"], "keysrs")

    def test_description_says_the_app_is_required(self):
        for path in (CLAUDE_MANIFEST, CODEX_MANIFEST):
            description = load(path)["description"]
            self.assertIn("Keysrs.app", description)
            self.assertIn("macOS", description)
        self.assertIn("Keysrs.app", load(CODEX_MANIFEST)["interface"]["longDescription"])
        readme = (PLUGIN / "README.md").read_text(encoding="utf-8")
        self.assertIn("gshost1/keysrs/keysrs", readme)
        self.assertIn("does not install Keysrs", readme)

    def test_every_path_a_manifest_names_exists(self):
        claude, codex = load(CLAUDE_MANIFEST), load(CODEX_MANIFEST)
        self.assertTrue((PLUGIN / claude["icon"]).is_file())
        self.assertTrue((PLUGIN / codex["skills"]).is_dir())
        self.assertTrue((PLUGIN / codex["mcpServers"]).is_file())
        interface = codex["interface"]
        for key in ("composerIcon", "logo"):
            self.assertTrue((PLUGIN / interface[key]).is_file(), key)
        for path in (CLAUDE_MANIFEST, CODEX_MANIFEST):
            for value in json.dumps(load(path)).split('"'):
                if value.startswith("./"):
                    self.assertNotIn("..", value)
                    self.assertTrue((PLUGIN / value).exists(), value)

    def test_mcp_config_runs_keys_mcp_and_holds_no_secret(self):
        raw = (PLUGIN / ".mcp.json").read_text(encoding="utf-8")
        servers = json.loads(raw)["mcpServers"]
        self.assertEqual(list(servers), ["keysrs"])  # same name `keys setup mcp` writes
        self.assertEqual(servers["keysrs"], {"command": APP_BINARY, "args": ["mcp"]})
        self.assertNotIn("env", servers["keysrs"])
        # Registration code is the other source of truth for the server name and args.
        swift = (REPO / "Sources/KeysCore/MCPRegistration.swift").read_text(encoding="utf-8")
        self.assertIn('static let serverName = "keysrs"', swift)
        self.assertIn('static let stdioArgs = ["mcp"]', swift)

    def test_no_manifest_holds_a_secret_or_env_value(self):
        for path in (CLAUDE_MANIFEST, CODEX_MANIFEST, CLAUDE_MARKET, CODEX_MARKET, PLUGIN / ".mcp.json"):
            text = path.read_text(encoding="utf-8")
            for needle in ("sk-", "Bearer ", "token", "password", "secret", "api_key", "${"):
                self.assertNotIn(needle, text, f"{path.relative_to(REPO)} mentions {needle!r}")

    def test_skill_copy_is_byte_identical_to_the_shipped_skill(self):
        # The plugin folder cannot symlink out of itself, so it holds a copy.
        self.assertFalse((PLUGIN / "skills" / "keysrs" / "SKILL.md").is_symlink())
        self.assertEqual((PLUGIN / "skills" / "keysrs" / "SKILL.md").read_bytes(),
                         (REPO / "Skills" / "keysrs" / "SKILL.md").read_bytes(),
                         "copy Skills/keysrs/SKILL.md into plugins/keysrs/skills/keysrs/")

    def test_icon_copy_is_identical_to_the_brand_png(self):
        self.assertEqual((PLUGIN / "assets" / "icon.png").read_bytes(),
                         (REPO / "Assets/icon/png/keysrs-icon-256.png").read_bytes())

    def test_skill_no_longer_claims_usage_log_reading(self):
        skill = (REPO / "Skills/keysrs/SKILL.md").read_text(encoding="utf-8")
        self.assertNotIn("usage logs", skill)
        self.assertNotIn("already write", skill)

    def test_plugin_folder_has_only_regular_files_the_directory_accepts(self):
        for path in PLUGIN.rglob("*"):
            self.assertFalse(path.is_symlink(), path)
            self.assertNotIn(path.name, {".DS_Store", "Thumbs.db"})
            if path.is_file():
                self.assertLess(path.stat().st_size, 256 * 1024 if path.suffix != ".png" else 5 * 1024 * 1024)

    def test_readme_is_long_enough_for_the_directory(self):
        readme = (PLUGIN / "README.md").read_text(encoding="utf-8")
        prose = re.sub(r"```.*?```", "", readme, flags=re.S)
        self.assertGreaterEqual(len(prose.split()), 40)

    def test_claude_marketplace_lists_the_plugin_folder(self):
        market = load(CLAUDE_MARKET)
        self.assertEqual(market["name"], "keysrs")
        self.assertIn("name", market["owner"])
        (entry,) = market["plugins"]
        self.assertEqual(entry["name"], load(CLAUDE_MANIFEST)["name"])
        self.assertTrue(entry["source"].startswith("./"))
        self.assertTrue((REPO / entry["source"] / ".claude-plugin" / "plugin.json").is_file())

    def test_codex_marketplace_lists_the_plugin_folder(self):
        market = load(CODEX_MARKET)
        (entry,) = market["plugins"]
        self.assertEqual(entry["name"], load(CODEX_MANIFEST)["name"])
        self.assertEqual(entry["source"]["source"], "local")
        self.assertTrue(entry["source"]["path"].startswith("./"))
        self.assertTrue((REPO / entry["source"]["path"] / ".codex-plugin" / "plugin.json").is_file())
        self.assertEqual(set(entry["policy"]), {"installation", "authentication"})
        self.assertIn("category", entry)

    def test_release_checklist_mentions_the_plugin_manifests(self):
        release = (REPO / "docs" / "release.md").read_text(encoding="utf-8")
        self.assertIn("plugins/keysrs", release)
        self.assertIn("test_agent_plugins", release)


if __name__ == "__main__":
    unittest.main()
