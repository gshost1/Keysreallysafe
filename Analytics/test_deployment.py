import importlib.util
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


if __name__ == "__main__":
    unittest.main()
