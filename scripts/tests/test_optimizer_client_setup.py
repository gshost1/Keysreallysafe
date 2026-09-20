"""Tests for the project-local client setup helper. Fake executables only; no Keys, Claude or Codex run."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "optimizer-client-setup.py"
PROJECT = "5cddfd7b-3f7f-4358-b65b-bc7dd1e1e8b5"


def fake(directory, name, help_text):
    path = Path(directory) / name
    # Anything other than a --help request would be a bug in the helper.
    path.write_text("#!/bin/sh\ncase \"$*\" in *--help) printf '%s\\n' " + shlex.quote(help_text) + ";; *) echo UNEXPECTED >> \"$0.calls\";; esac\n")
    path.chmod(0o755)
    return path


class ClientSetupTests(unittest.TestCase):
    def test_direct_typesafe_compaction_command_selects_matching_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fakes(directory)
            done, output = self.run_helper(directory, "--project", PROJECT, "--jev-key", "codex-jev",
                                           "--provider", "typesafe", "--root", directory)
            self.assertEqual(done.returncode, 0, done.stderr)
            command = shlex.split(output["commands"]["claude_mcp_and_compaction"])
            self.assertEqual(command[command.index("--provider") + 1], "typesafe")

    def run_helper(self, directory, *arguments):
        env = {"PATH": f"{directory}:/usr/bin:/bin", "HOME": str(Path(directory) / "home")}
        done = subprocess.run([sys.executable, str(SCRIPT), *arguments], capture_output=True, text=True, timeout=30, env=env)
        return done, (json.loads(done.stdout) if done.stdout.startswith("{") else None)

    def fakes(self, directory, claude_help="--mcp-config --plugin-dir"):
        fake(directory, "keys", "--project --minutes --writable --jev-key")
        fake(directory, "claude", claude_help)
        fake(directory, "codex", "-c, --config  -C, --cd")

    def test_commands_are_project_local_and_credential_free(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fakes(directory)
            done, output = self.run_helper(directory, "--project", PROJECT.upper(), "--jev-key", "jev-ass", "--root", directory, "--check")
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertTrue(output["ready"])
            self.assertFalse(output["edits_client_configuration"])
            server = output["claude_mcp_config"]["mcpServers"]["keys_optimizer"]
            self.assertEqual(server["args"], ["optimizer", "mcp", "--project", PROJECT, "--minutes", "30", "--jev-key", "jev-ass"])
            self.assertNotIn("env", server)
            for secret_marker in ("ksf_", "kso_", "sk-", "API_KEY"):
                self.assertNotIn(secret_marker, done.stdout)
            codex = shlex.split(output["commands"]["codex_mcp_only"])
            self.assertEqual(codex[:3], ["codex", "--cd", str(Path(directory).resolve())])
            self.assertIn("mcp_servers.keys_optimizer.startup_timeout_sec=120", codex)
            self.assertIn("claude-with-jev.py", output["commands"]["claude_mcp_and_compaction"])
            self.assertTrue(all(item["ok"] for item in output["checks"]), output["checks"])
            self.assertEqual(list(Path(directory).glob("*.calls")), [], "only --help may be executed")
            for owned in (".claude", ".claude.json", ".codex"):
                self.assertFalse((Path(directory) / "home" / owned).exists(), "no client configuration is created")

    def test_placeholder_and_missing_client_option_are_reported_not_hidden(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fakes(directory, claude_help="--plugin-dir")
            done, output = self.run_helper(directory, "--root", directory, "--check")
            self.assertEqual(done.returncode, 3)
            self.assertFalse(output["ready"])
            self.assertIn("PROJECT_UUID", output["commands"]["claude_mcp_only"] + json.dumps(output["claude_mcp_config"]))
            checks = {item["check"]: item for item in output["checks"]}
            self.assertFalse(checks["project_uuid"]["ok"])
            self.assertFalse(checks["claude_options"]["ok"])
            self.assertEqual(checks["claude_options"]["detail"], {"--mcp-config": False, "--plugin-dir": True})
            self.assertNotIn("claude_mcp_and_compaction", output["commands"], "no key name was given")

    def test_example_file_is_never_overwritten_or_placed_in_client_folders(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fakes(directory)
            target = Path(directory) / "project" / ".keys"
            done, output = self.run_helper(directory, "--project", PROJECT, "--write-example", str(target))
            self.assertEqual(done.returncode, 0, done.stderr)
            written = Path(output["example_written"])
            self.assertEqual(json.loads(written.read_text()), output["claude_mcp_config"])
            written.write_text("mine")
            done, _ = self.run_helper(directory, "--project", PROJECT, "--write-example", str(target))
            self.assertEqual(done.returncode, 1)
            self.assertEqual(written.read_text(), "mine")
            for owned in (".claude", ".codex/nested"):
                done, _ = self.run_helper(directory, "--project", PROJECT, "--write-example", str(Path(directory) / "home" / owned))
                self.assertEqual(done.returncode, 1)
                self.assertIn("refusing", done.stderr)
            self.assertFalse((Path(directory) / "home" / ".claude").exists())

    def test_invalid_inputs_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for arguments in (["--project", "not-a-uuid"], ["--jev-key", "Bad Key"], ["--minutes", "0"], ["--jev-key", "$(id)"]):
                done, _ = self.run_helper(directory, *arguments)
                self.assertEqual(done.returncode, 2, arguments)


if __name__ == "__main__":
    unittest.main()
