#!/usr/bin/env python3
"""Offline validation for the collector deployment bundle; performs no deployment."""

import argparse
import importlib.util
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent


def load_collector(bundle):
    spec = importlib.util.spec_from_file_location("analytics_collector", bundle / "collector.py")
    module = importlib.util.module_from_spec(spec)
    # Validation must not leave bytecode caches inside the selected bundle.
    previous, sys.dont_write_bytecode = sys.dont_write_bytecode, True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


def validate(bundle=HERE, check_docker=False):
    checks = []

    def add(name, status, detail):
        checks.append({"name": name, "status": status, "detail": detail})

    required = ("collector.py", "Dockerfile", "compose.yaml", "Caddyfile")
    for name in required:
        add("file:" + name, "pass" if (bundle / name).is_file() else "blocker", "required deployment asset")
    if any(item["status"] == "blocker" for item in checks):
        return checks

    try:
        dockerfile = (bundle / "Dockerfile").read_text(encoding="utf-8")
        compose = (bundle / "compose.yaml").read_text(encoding="utf-8")
        caddy = (bundle / "Caddyfile").read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        add("assets_readable", "blocker", "deployment assets must be readable UTF-8 text")
        return checks
    add("container_nonroot", "pass" if "USER 10001:10001" in dockerfile else "blocker", "numeric non-root runtime user")
    add("persistent_database", "pass" if "analytics-data:/data" in compose else "blocker", "private named volume")
    add("domain_unset_gate", "pass" if "ANALYTICS_DOMAIN:?" in compose else "blocker", "hosting domain must be chosen explicitly")
    # A global logger is required to suppress proxy-error request details too.
    # Strip comments before checking the small, fixed deployment template.
    directives = "\n".join(line.split("#", 1)[0] for line in caddy.splitlines())
    logs = re.findall(r"(?m)^\s*log(?:\s+([^\s{]+))?\s*\{?\s*$", directives)
    protected_logger = re.search(r"log\s+default\s*\{\s*exclude\s+http\.log\.access\s+http\.log\.error\s*\}", directives)
    add("proxy_request_logs", "pass" if logs == ["default"] and protected_logger else "blocker", "HTTP access and proxy-error request details excluded from the default logger")
    add("proxy_body_limit", "pass" if "max_size 32KB" in caddy else "blocker", "edge request-body cap")
    deadlines = ("max_header_size 16KB", "read_header 5s", "read_body 15s", "write 30s", "idle 30s")
    add("proxy_deadlines", "pass" if all(value in directives for value in deadlines) else "blocker", "bounded headers, body reads, writes and idle connections")
    collector_section, proxy_marker, proxy_section = compose.partition("  proxy:")
    private_network = (
        bool(proxy_marker) and "internal: true" in compose
        and "analytics-edge" not in collector_section
        and "analytics-edge" in proxy_section
        and "ports:" not in collector_section
    )
    add("private_network", "pass" if private_network else "blocker", "collector is not host-published; proxy has an egress network")
    add("healthcheck", "pass" if "/healthz" in dockerfile and "/healthz" in caddy else "blocker", "content-free liveness route")

    try:
        collector = load_collector(bundle)
        with tempfile.TemporaryDirectory() as directory:
            store = collector.Store(Path(directory) / "selftest.sqlite", max_reports=10)
            try:
                add("sqlite_open", "pass", "selected bundle opened a temporary private database")
                add("empty_summary", "pass" if store.summary() == [] else "blocker", "fresh database contains no reports")
            finally:
                store.close()
    except (Exception, SystemExit):
        add("collector_self_test", "blocker", "selected bundle's collector could not complete the offline self-test")

    docker = shutil.which("docker")
    if not check_docker:
        add("docker_build", "untested", "run with --check-docker on the intended build host")
    elif not docker:
        add("docker_build", "untested", "Docker is unavailable on this host")
    else:
        process = subprocess.run(
            [docker, "compose", "-f", str(bundle / "compose.yaml"), "config", "--quiet"],
            cwd=bundle,
            env={"PATH": str(Path(docker).parent), "ANALYTICS_DOMAIN": "deployment-validation.invalid"},
            capture_output=True,
            timeout=30,
        )
        add("docker_compose_config", "pass" if process.returncode == 0 else "blocker", "offline Compose syntax validation")
        add("docker_build", "untested", "image pull/build intentionally not run by this validator")
    return checks


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=HERE)
    parser.add_argument("--check-docker", action="store_true")
    args = parser.parse_args(argv)
    checks = validate(args.bundle.resolve(), args.check_docker)
    print(json.dumps({"checks": checks}, indent=2, sort_keys=True))
    return 1 if any(item["status"] == "blocker" for item in checks) else 0


if __name__ == "__main__":
    raise SystemExit(main())
