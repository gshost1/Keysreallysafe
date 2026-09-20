import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "optimizer-preflight.py"
SPEC = importlib.util.spec_from_file_location("optimizer_preflight", SCRIPT)
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def make_tree(self, root):
        files = (
            "Package.swift",
            "Sources/KeysCore/OptimizerCLI.swift",
            "Sources/KeysCore/OptimizerAPI.swift",
            "scripts/optimizer-mcp.py",
            "scripts/benchmark-optimizer.py",
            "Plugins/jev-optimizer/package.json",
            "Plugins/jev-optimizer/dist/index.js",
            "Analytics/Dockerfile",
            "Analytics/Caddyfile",
            "Analytics/validate_deployment.py",
        )
        for relative in files:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("pass\n" if path.suffix == ".py" else "fixture\n")
        (root / "Analytics/collector.py").write_text(
            'FIELDS={"schema_version","consent_version"}\n'
            'COUNT_KEYS={"optimizer_abstained"}\nROUTE="/v1/reports"\n',
            encoding="utf-8",
        )
        (root / "Analytics/compose.yaml").write_text("ANALYTICS_DOMAIN:?\n", encoding="utf-8")

    def test_reports_artifacts_endpoint_gate_and_presence_steps_without_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_tree(root)
            with mock.patch.object(preflight.shutil, "which", return_value="/usr/bin/tool"):
                report = preflight.run(root)
        self.assertEqual(report["blockers"], [])
        self.assertFalse(report["secrets_examined"])
        self.assertFalse(report["live_auth_invoked"])
        endpoint = next(item for item in report["checks"] if item["name"] == "analytics:endpoint")
        self.assertEqual(endpoint["status"], "user_configuration")
        self.assertEqual(len(report["user_presence_steps"]), 3)

    def test_missing_required_files_are_blockers_and_strict_cli_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", directory, "--strict"],
                text=True,
                capture_output=True,
                timeout=5,
            )
        self.assertEqual(process.returncode, 1)
        report = json.loads(process.stdout)
        self.assertIn("Package.swift", report["blockers"])
        self.assertNotIn("AI_GATEWAY_API_KEY", process.stdout)
        self.assertNotIn("KEYS_OPTIMIZER_SESSION", process.stdout)


if __name__ == "__main__":
    unittest.main()
