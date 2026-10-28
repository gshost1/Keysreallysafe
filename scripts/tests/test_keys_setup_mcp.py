#!/usr/bin/env python3
"""`keys setup mcp` end to end, confined to one temp tree (VAL-REG-014).

Spawns the built `.build/debug/keys` with every client home pointed inside one
temp directory via the documented overrides (KEYS_CLAUDE_JSON, CODEX_HOME,
KEYS_CURSOR_HOME, KEYS_DROID_HOME, KEYS_CLAUDE_DESKTOP_HOME) plus a KEYS_CATALOG
inside the same tree. The five REAL config files exist on this machine and must
never be touched: never run the registration without the overrides, and never
run it unconfined. Registration resolves no vault key and needs no site, no
keychain and no Touch ID — the script proves that too (no catalog is created).
CI runs this via `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`,
after `swift test` has built the binary.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
KEYS = REPO / ".build" / "debug" / "keys"
SERVER = "keysrs"
ARGS = ["mcp"]


@unittest.skipUnless(KEYS.exists() and os.access(KEYS, os.X_OK),
                     "build first: swift build (the harness drives .build/debug/keys)")
class KeysSetupMCPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.claude = self.root / "claude.json"
        self.codex = self.root / "codex-home" / "config.toml"
        self.cursor = self.root / "cursor-home" / "mcp.json"
        self.droid = self.root / "factory-home" / "mcp.json"
        self.desktop = self.root / "desktop-home" / "claude_desktop_config.json"
        self.catalog = self.root / "none.db"
        self.env = dict(os.environ)
        self.env.update({
            "KEYS_CLAUDE_JSON": str(self.claude),
            "CODEX_HOME": str(self.root / "codex-home"),
            "KEYS_CURSOR_HOME": str(self.root / "cursor-home"),
            "KEYS_DROID_HOME": str(self.root / "factory-home"),
            "KEYS_CLAUDE_DESKTOP_HOME": str(self.root / "desktop-home"),
            "KEYS_CATALOG": str(self.catalog),
        })

    def setup(self, *args):
        return subprocess.run([str(KEYS), "setup", "mcp", *args],
                               capture_output=True, text=True, env=self.env)

    def mode(self, path):
        return os.stat(path).st_mode & 0o777

    def read(self, path):
        with open(path) as fh:
            return json.load(fh)

    def test_register_five_verify_five_remove_five(self):
        # Register with no Keysrs site running and an empty vault: no catalog is
        # created, no presence prompt, exit 0.
        done = self.setup()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(self.catalog.exists(), "registration must not create a catalog")
        self.assertIn("registered %s with Claude Code" % SERVER, done.stdout)

        # The command the clients launch is the resolved absolute binary path.
        command = str(KEYS.resolve())
        self.assertTrue(command.startswith("/") and command.endswith("/keys"))

        # The four JSON files parse and hold our entry with that command.
        for path, has_type, has_env in [
            (self.claude, True, True), (self.cursor, False, False),
            (self.droid, True, False), (self.desktop, False, False),
        ]:
            ours = self.read(path)["mcpServers"][SERVER]
            self.assertEqual(ours["command"], command, str(path))
            self.assertEqual(ours["args"], ARGS, str(path))
            self.assertEqual("type" in ours, has_type, str(path))
            self.assertEqual("env" in ours, has_env, str(path))
            self.assertEqual(self.mode(path), 0o600, str(path))

        # The TOML table, by grep.
        toml = self.codex.read_text()
        self.assertIn("[mcp_servers.%s]" % SERVER, toml)
        self.assertIn('command = "%s"' % command, toml)
        self.assertIn('args = ["mcp"]', toml)
        self.assertEqual(self.mode(self.codex), 0o600)

        # A second registration is idempotent and rolls the .bak: identical file
        # bytes, .bak byte-equal to the current file, both 0600.
        again = self.setup()
        self.assertEqual(again.returncode, 0, again.stderr)
        for path in [self.claude, self.codex, self.cursor, self.droid, self.desktop]:
            bak = path.parent / (path.name + ".bak")
            self.assertTrue(bak.exists(), str(bak))
            self.assertEqual(bak.read_bytes(), path.read_bytes(), str(bak))
            self.assertEqual(self.mode(bak), 0o600, str(bak))
            self.assertEqual(self.mode(path), 0o600, str(path))

        # --remove undoes all five: our entry gone, the now-empty mcpServers dropped
        # (the JSON files hold {}), the Codex file empty again.
        removed = self.setup("--remove")
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(self.catalog.exists())
        for path in [self.claude, self.cursor, self.droid, self.desktop]:
            self.assertNotIn("mcpServers", self.read(path), str(path))
        self.assertEqual(self.codex.read_text(), "")

        # Removing with nothing registered is a harmless no-op: exit 0.
        once_more = self.setup("--remove")
        self.assertEqual(once_more.returncode, 0, once_more.stderr)
        self.assertIn("nothing to remove", once_more.stdout)

    def test_failure_paths(self):
        # A broken target file: exit 1, the usage message names the file, the bytes
        # are untouched and no .bak is created for it.
        self.cursor.parent.mkdir(parents=True, exist_ok=True)
        garbage = '{"mcpServers": {"keysrs": {'
        self.cursor.write_text(garbage)
        refused = self.setup()
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertIn("mcp.json", refused.stderr)
        self.assertIn("not valid JSON", refused.stderr)
        self.assertEqual(self.cursor.read_text(), garbage)
        self.assertFalse((self.cursor.parent / "mcp.json.bak").exists())

        # A wrong-typed mcpServers is refused the same way, with the file named.
        self.cursor.write_text('{"mcpServers": "not-an-object"}')
        wrong = self.setup()
        self.assertEqual(wrong.returncode, 1, wrong.stderr)
        self.assertIn("not an object", wrong.stderr)
        self.assertEqual(self.cursor.read_text(), '{"mcpServers": "not-an-object"}')

        # --remove with nothing registered on a fresh tree: exit 0.
        clean = self.root / "fresh"
        env = dict(self.env)
        env["KEYS_CLAUDE_JSON"] = str(clean / "claude.json")
        env["CODEX_HOME"] = str(clean / "codex")
        env["KEYS_CURSOR_HOME"] = str(clean / "cursor")
        env["KEYS_DROID_HOME"] = str(clean / "factory")
        env["KEYS_CLAUDE_DESKTOP_HOME"] = str(clean / "desktop")
        nothing = subprocess.run([str(KEYS), "setup", "mcp", "--remove"],
                                  capture_output=True, text=True, env=env)
        self.assertEqual(nothing.returncode, 0, nothing.stderr)
        self.assertFalse(clean.exists(), "a no-op removal creates no files")

        # Bad arguments exit 64 and write nothing.
        for bad in (["extra"], ["--bogus"]):
            junk = subprocess.run([str(KEYS), "setup", "mcp", *bad],
                                  capture_output=True, text=True, env=env)
            self.assertEqual(junk.returncode, 64, bad)
            self.assertFalse(clean.exists(), "a parse failure writes nothing")


if __name__ == "__main__":
    unittest.main()
