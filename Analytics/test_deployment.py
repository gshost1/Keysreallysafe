import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import shutil

SPEC = importlib.util.spec_from_file_location(
    "validate_deployment", Path(__file__).with_name("validate_deployment.py")
)
deployment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deployment)


class DeploymentTests(unittest.TestCase):
    def test_bundle_passes_offline_checks_and_marks_docker_untested(self):
        checks = deployment.validate(check_docker=False)
        self.assertFalse([item for item in checks if item["status"] == "blocker"])
        docker = next(item for item in checks if item["name"] == "docker_build")
        self.assertEqual(docker["status"], "untested")

    def test_missing_asset_is_a_blocker_without_running_docker(self):
        with tempfile.TemporaryDirectory() as directory:
            checks = deployment.validate(Path(directory), check_docker=True)
        self.assertTrue([item for item in checks if item["status"] == "blocker"])

    def test_proxy_error_logs_and_slow_request_limits_cannot_be_removed(self):
        for removed, check in [("exclude http.log.access http.log.error", "proxy_request_logs"),
                               ("read_header 5s", "proxy_deadlines")]:
            with tempfile.TemporaryDirectory() as directory:
                bundle = Path(directory)
                for name in ("collector.py", "Dockerfile", "compose.yaml", "Caddyfile"):
                    shutil.copyfile(deployment.HERE / name, bundle / name)
                config = bundle / "Caddyfile"
                config.write_text(config.read_text().replace(removed, ""))
                checks = deployment.validate(bundle)
                self.assertEqual(next(item for item in checks if item["name"] == check)["status"], "blocker")

    def test_selected_bundle_collector_is_exercised_and_import_failure_is_a_blocker(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            for name in ("collector.py", "Dockerfile", "compose.yaml", "Caddyfile"):
                shutil.copyfile(deployment.HERE / name, bundle / name)
            (bundle / "collector.py").write_text('raise RuntimeError("broken selected collector")\n')
            checks = deployment.validate(bundle)
            self.assertEqual(next(item for item in checks if item["name"] == "collector_self_test")["status"], "blocker")
            self.assertFalse(any(item["name"] == "sqlite_open" for item in checks))

    def test_selected_bundle_summary_is_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            for name in ("Dockerfile", "compose.yaml", "Caddyfile"):
                shutil.copyfile(deployment.HERE / name, bundle / name)
            (bundle / "collector.py").write_text(
                'class Store:\n'
                '    def __init__(self, *args, **kwargs): pass\n'
                '    def summary(self): return [{"unexpected": True}]\n'
                '    def close(self): pass\n')
            checks = deployment.validate(bundle)
            self.assertEqual(next(item for item in checks if item["name"] == "empty_summary")["status"], "blocker")

    def test_selected_bundle_is_imported_instead_of_the_checkout_collector(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            for name in ("Dockerfile", "compose.yaml", "Caddyfile"):
                shutil.copyfile(deployment.HERE / name, bundle / name)
            (bundle / "collector.py").write_text(
                'from pathlib import Path\n'
                'class Store:\n'
                '    def __init__(self, path, max_reports): Path(__file__).with_name("selected.marker").write_text(str(max_reports))\n'
                '    def summary(self): return []\n'
                '    def close(self): pass\n')
            checks = deployment.validate(bundle)
            self.assertFalse([item for item in checks if item["status"] == "blocker"])
            self.assertEqual((bundle / "selected.marker").read_text(), "10")
            self.assertFalse((bundle / "__pycache__").exists())

    def test_malformed_compose_and_unreadable_assets_are_blockers_not_crashes(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            for name in ("collector.py", "Dockerfile", "compose.yaml", "Caddyfile"):
                shutil.copyfile(deployment.HERE / name, bundle / name)
            compose = bundle / "compose.yaml"
            original = compose.read_text()
            for malformed in ("", "services: [", original.replace("  proxy:", "  edge:")):
                compose.write_text(malformed)
                checks = deployment.validate(bundle)
                self.assertEqual(next(item for item in checks if item["name"] == "private_network")["status"], "blocker")
                self.assertEqual(next(item for item in checks if item["name"] == "sqlite_open")["status"], "pass")
            compose.write_bytes(b"\xff\xfe not utf-8")
            checks = deployment.validate(bundle)
            self.assertEqual(checks[-1], {"name": "assets_readable", "status": "blocker",
                                          "detail": "deployment assets must be readable UTF-8 text"})
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(deployment.main(["--bundle", str(bundle)]), 1)
            self.assertIn("assets_readable", output.getvalue())

    def test_collector_exit_or_syntax_error_is_a_blocker(self):
        for source in ("raise SystemExit(0)\n", "def broken(:\n", "class Store: pass\n"):
            with tempfile.TemporaryDirectory() as directory:
                bundle = Path(directory)
                for name in ("Dockerfile", "compose.yaml", "Caddyfile"):
                    shutil.copyfile(deployment.HERE / name, bundle / name)
                (bundle / "collector.py").write_text(source)
                checks = deployment.validate(bundle)
                self.assertEqual(next(item for item in checks if item["name"] == "collector_self_test")["status"], "blocker", source)


if __name__ == "__main__":
    unittest.main()
