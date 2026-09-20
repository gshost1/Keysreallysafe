#!/usr/bin/env python3
"""Read-only release and deployment preflight. Never performs authentication."""

import argparse
import ast
import json
from pathlib import Path
import shutil
import sys


def check_path(root, relative, kind="file", required=True):
    path = root / relative
    exists = path.is_file() if kind == "file" else path.is_dir()
    return {
        "name": relative,
        "status": "pass" if exists else ("blocker" if required else "missing_optional"),
        "detail": f"required {kind}" if required else f"optional {kind}",
    }


def python_syntax(root, relative):
    path = root / relative
    if not path.is_file():
        return {"name": relative + ":syntax", "status": "blocker", "detail": "source missing"}
    try:
        ast.parse(path.read_text(encoding="utf-8"), filename=relative)
        return {"name": relative + ":syntax", "status": "pass", "detail": "parsed without execution"}
    except (OSError, SyntaxError, UnicodeError):
        return {"name": relative + ":syntax", "status": "blocker", "detail": "invalid Python source"}


def run(root):
    checks = []
    for relative in (
        "Package.swift",
        "Sources/KeysCore/OptimizerCLI.swift",
        "Sources/KeysCore/OptimizerAPI.swift",
        "scripts/optimizer-mcp.py",
        "scripts/benchmark-optimizer.py",
        "Plugins/jev-optimizer/package.json",
        "Plugins/jev-optimizer/dist/index.js",
        "Analytics/collector.py",
        "Analytics/Dockerfile",
        "Analytics/compose.yaml",
        "Analytics/Caddyfile",
        "Analytics/validate_deployment.py",
    ):
        checks.append(check_path(root, relative))
    checks.append(check_path(root, ".build/release/keys", required=False))
    checks.append(check_path(root, "Plugins/jev-optimizer/node_modules", kind="directory", required=False))

    for relative in (
        "scripts/optimizer-mcp.py",
        "scripts/benchmark-optimizer.py",
        "Analytics/collector.py",
        "Analytics/validate_deployment.py",
    ):
        checks.append(python_syntax(root, relative))

    python_ok = sys.version_info >= (3, 9)
    checks.append(
        {
            "name": "runtime:python",
            "status": "pass" if python_ok else "blocker",
            "detail": "Python 3.9 or newer required",
        }
    )
    checks.append(
        {
            "name": "runtime:node",
            "status": "pass" if shutil.which("node") else "blocker",
            "detail": "Node.js required for offline Optimizer engine validation",
        }
    )
    checks.append(
        {
            "name": "runtime:docker",
            "status": "available_untested" if shutil.which("docker") else "unavailable_untested",
            "detail": "container build must be tested on the chosen deployment host",
        }
    )

    collector = root / "Analytics/collector.py"
    if collector.is_file():
        text = collector.read_text(encoding="utf-8")
        schema_ok = all(
            token in text
            for token in (
                '"schema_version"',
                '"consent_version"',
                "optimizer_abstained",
                '"/v1/reports"',
            )
        )
        checks.append(
            {
                "name": "analytics:schema_contract",
                "status": "pass" if schema_ok else "blocker",
                "detail": "v1 aggregate report contract present",
            }
        )
    compose = root / "Analytics/compose.yaml"
    endpoint_unset = compose.is_file() and "ANALYTICS_DOMAIN:?" in compose.read_text(encoding="utf-8")
    checks.append(
        {
            "name": "analytics:endpoint",
            "status": "user_configuration" if endpoint_unset else "blocker",
            "detail": "remains unset until a hosting domain is selected",
        }
    )
    return {
        "schema_version": 1,
        "root": str(root),
        "checks": checks,
        "blockers": [item["name"] for item in checks if item["status"] == "blocker"],
        "user_presence_steps": [
            {
                "name": "optimizer_live_authorization",
                "detail": "Touch ID/presence is required only when explicitly running a live Optimizer session",
            },
            {
                "name": "release_signing_and_install",
                "detail": "signing, notarization, Keychain access, and installation remain manual release steps",
            },
            {
                "name": "collector_hosting",
                "detail": "choose a domain, provision TLS host and private volume, then set the endpoint in a later change",
            },
        ],
        "secrets_examined": False,
        "live_auth_invoked": False,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--strict", action="store_true", help="Exit nonzero when blockers exist.")
    args = parser.parse_args(argv)
    report = run(args.root.resolve())
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if args.strict and report["blockers"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
