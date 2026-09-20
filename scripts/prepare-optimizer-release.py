#!/usr/bin/env python3
"""Prepare a reproducible, offline Keys + Jev optimizer release directory.

This tool only reads a built checkout and writes a new output directory.  It
never signs, queries Keychain identities, installs an app, launches a native
authorization flow, or inspects/modifies a live installation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


WEB_FILES = (
    "app.js", "analytics.js", "index.html", "optimizer.css", "optimizer.js", "providers.json", "styles.css",
)
FIXTURE_FILES = ("models.json",)
PLUGIN_FILES = (".claude-plugin/plugin.json", "LICENSE", "README.md", "package.json")
PLUGIN_TREES = ("dist", "src", "hooks")
SCRIPTS = ("optimizer-mcp.py", "claude-with-jev.py")
DOC_FILES = (
    "LICENSE", "README.md", "SIGNING.md", "Analytics/README.md",
    # The recipient of a package needs the install and acceptance instructions inside it, not in
    # a checkout they do not have.
    "docs/mvp-quickstart.md", "docs/mvp-acceptance.md",
    "docs/jev-optimizer.md", "docs/jev-research.md", "docs/optimizer-benchmarks.md",
    "docs/optimizer-candidates.md", "docs/optimizer-client-adapter.md",
    "docs/optimizer-deployment.md", "docs/optimizer-library.md", "docs/optimizer-providers.md",
    "docs/optimizer-release.md", "docs/optimizer-task-workflow.md", "docs/product-analytics.md",
)
ALLOWED_PLUGIN_SUFFIXES = (".d.ts", ".d.ts.map", ".js", ".js.map", ".ts", ".json", ".md")
SENSITIVE_JSON_TERMS = ("credential", "secret", "token")


class ReleaseError(Exception):
    """A safe, actionable release-preflight error."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def absolute_path(path: Path) -> Path:
    """Make a path absolute without following a symlink."""
    return Path(os.path.abspath(path))


def reject_symlink_ancestors(path: Path, boundary: Path, label: str) -> None:
    """Reject a link at or below boundary before any path is canonicalized."""
    path = absolute_path(path)
    boundary = absolute_path(boundary)
    try:
        relative = path.relative_to(boundary)
    except ValueError:
        raise ReleaseError(f"{label} is outside required root {boundary}: {path}") from None
    current = boundary
    if current.is_symlink():
        raise ReleaseError(f"{label} has a symlink ancestor: {current}")
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise ReleaseError(f"{label} has a symlink ancestor: {current}")


def require_regular(path: Path, label: str, root: Path, executable: bool = False) -> None:
    reject_symlink_ancestors(path, root, label)
    if path.is_symlink():
        raise ReleaseError(f"{label} must not be a symlink: {path}")
    if not path.is_file():
        raise ReleaseError(f"missing required {label}: {path}")
    if executable and not os.access(path, os.X_OK):
        raise ReleaseError(f"{label} is not executable: {path}")


def checked_tree(root: Path, label: str, repo: Path) -> list[Path]:
    reject_symlink_ancestors(root, repo, label)
    if not root.is_dir():
        raise ReleaseError(f"missing required {label} directory: {root}")
    files: list[Path] = []
    for path in sorted(root.rglob("*")):
        reject_symlink_ancestors(path, repo, label)
        relative = path.relative_to(root)
        if any(part.startswith(".") for part in relative.parts):
            raise ReleaseError(f"{label} contains a hidden path: {path}")
        if "node_modules" in relative.parts:
            raise ReleaseError(f"{label} contains nested node_modules: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ReleaseError(f"{label} contains a non-regular file: {path}")
        if not path.name.endswith(ALLOWED_PLUGIN_SUFFIXES):
            raise ReleaseError(f"{label} contains a non-runtime file: {path}")
        if path.suffix == ".json" and any(term in path.stem.lower() for term in SENSITIVE_JSON_TERMS):
            raise ReleaseError(f"{label} contains credential-shaped JSON: {path}")
        files.append(path)
    if not files:
        raise ReleaseError(f"{label} is empty: {root}")
    return files


def copy_file(source: Path, destination: Path, executable: bool = False) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    os.chmod(destination, 0o755 if executable else 0o644)


def copy_tree(source: Path, destination: Path, files: list[Path]) -> None:
    for file in files:
        relative = file.relative_to(source)
        copy_file(file, destination / relative)


def verify_codesign(binary: Path) -> dict[str, str]:
    """Optionally run read-only codesign checks; never request or use an identity."""
    commands = (
        ("display", ["/usr/bin/codesign", "--display", "--verbose=4", str(binary)]),
        ("verify", ["/usr/bin/codesign", "--verify", "--strict", str(binary)]),
    )
    result: dict[str, str] = {"requested": "true"}
    for name, command in commands:
        try:
            completed = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, check=False, timeout=30)
            result[name] = "passed" if completed.returncode == 0 else "failed"
        except (OSError, subprocess.SubprocessError):
            result[name] = "unavailable"
    result["status"] = "passed" if all(result[name] == "passed" for name, _ in commands) else "not_verified"
    return result


def rollback_text() -> str:
    return """# Offline release rollback\n\nThis directory has not been installed, signed, or used to start Keys. It is a staging artifact only.\n\nIf a later `keys autostart` activation fails, the installer in `LoginItem.swift` restores the prior runtime from its temporary backup before returning failure. After a successful activation, it retains one prior version at `~/Library/Application Support/keysreallysafe/.previous/`.\n\nThere is no supported manual rollback command in this package. For recovery after a successful activation, first copy the verified `.previous` directory to a safe location. Do this before `keys autostart --remove`, because normal removal deletes `.previous` along with the installed runtime. Do not copy this package into an active installation by hand.\n\nThe manifest deliberately reports live installation and signing as unvalidated unless a later, separate validation step is performed.\n"""


def build_manifest(root: Path, codesign: dict[str, str]) -> dict[str, object]:
    entries = []
    for path in sorted(p for p in root.rglob("*") if p.is_file() and p.name != "release-manifest.json"):
        entries.append({
            "path": path.relative_to(root).as_posix(),
            "sha256": sha256(path),
            "bytes": path.stat().st_size,
        })
    return {
        "format": 1,
        "purpose": "offline Keys + Jev optimizer release candidate",
        "reproducibility": "ordered allowlisted files with SHA-256 checksums; no timestamps or source contents",
        "release_status": {
            "signing": "unvalidated; this tool performed no signing",
            "live_installation": "unvalidated; this tool did not inspect or modify a live installation",
        },
        "codesign_verification": codesign,
        "checksums": entries,
    }


def verify_package(package: Path) -> None:
    package = absolute_path(package)
    if package.is_symlink() or not package.is_dir():
        raise ReleaseError(f"package must be an existing non-symlink directory: {package}")
    manifest_path = package / "release-manifest.json"
    require_regular(manifest_path, "release manifest", package)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        checksums = manifest["checksums"]
    except (OSError, ValueError, KeyError, TypeError):
        raise ReleaseError("release manifest is not valid JSON with a checksum list") from None
    if not isinstance(checksums, list):
        raise ReleaseError("release manifest checksum list is invalid")
    expected: dict[str, dict[str, object]] = {}
    for item in checksums:
        if not isinstance(item, dict) or set(item) != {"path", "sha256", "bytes"}:
            raise ReleaseError("release manifest contains an invalid checksum entry")
        relative = item["path"]
        if (not isinstance(relative, str) or not isinstance(item["sha256"], str)
                or type(item["bytes"]) is not int or relative in expected):
            raise ReleaseError("release manifest contains an invalid checksum entry")
        candidate = package / relative
        if candidate.parent != package and (Path(relative).is_absolute() or ".." in Path(relative).parts):
            raise ReleaseError("release manifest contains an unsafe checksum path")
        expected[relative] = item
    actual: set[str] = set()
    for path in package.rglob("*"):
        reject_symlink_ancestors(path, package, "package file")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ReleaseError(f"package contains a non-regular file: {path}")
        relative = path.relative_to(package).as_posix()
        if relative != "release-manifest.json":
            actual.add(relative)
    missing = sorted(set(expected) - actual)
    unexpected = sorted(actual - set(expected))
    if missing:
        raise ReleaseError(f"package is missing manifest file: {missing[0]}")
    if unexpected:
        raise ReleaseError(f"package contains an unexpected file: {unexpected[0]}")
    for relative, item in expected.items():
        path = package / relative
        require_regular(path, "packaged file", package)
        if path.stat().st_size != item["bytes"] or sha256(path) != item["sha256"]:
            raise ReleaseError(f"package checksum mismatch: {relative}")


def prepare(repo: Path, binary: Path, output: Path, check_codesign: bool, dry_run: bool = False) -> None:
    repo = absolute_path(repo)
    binary = absolute_path(binary)
    output = absolute_path(output)
    if repo.is_symlink() or not repo.is_dir():
        raise ReleaseError(f"repo must be an existing non-symlink directory: {repo}")
    require_regular(binary, "built keys binary", repo, executable=True)
    if output.is_symlink() or output.exists():
        raise ReleaseError(f"output must not already exist: {output}")
    if output.parent.is_symlink() or not output.parent.is_dir():
        raise ReleaseError(f"output parent must be an existing non-symlink directory: {output.parent}")
    canonical_binary = binary.resolve()

    for name in WEB_FILES:
        require_regular(repo / "Web" / name, f"Web runtime file {name}", repo)
    for name in FIXTURE_FILES:
        require_regular(repo / "Fixtures" / name, f"fixture {name}", repo)
    plugin = repo / "Plugins" / "jev-optimizer"
    for name in PLUGIN_FILES:
        require_regular(plugin / name, f"plugin runtime file {name}", repo)
    plugin_trees = {name: checked_tree(plugin / name, f"plugin {name}", repo) for name in PLUGIN_TREES}
    require_regular(plugin / "dist" / "optimizer-cli.js", "plugin dist entrypoint", repo)
    for name in SCRIPTS:
        require_regular(repo / "scripts" / name, f"release script {name}", repo)
    for name in DOC_FILES:
        require_regular(repo / name, f"release documentation {name}", repo)

    codesign = verify_codesign(canonical_binary) if check_codesign else {
        "requested": "false", "status": "not_requested (no signing or signing verification performed)"
    }
    if dry_run:
        return
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    try:
        copy_file(canonical_binary, temporary / "bin" / "keys", executable=True)
        for name in WEB_FILES:
            copy_file(repo / "Web" / name, temporary / "Web" / name)
        for name in FIXTURE_FILES:
            copy_file(repo / "Fixtures" / name, temporary / "Fixtures" / name)
        for name in PLUGIN_FILES:
            copy_file(plugin / name, temporary / "Plugins" / "jev-optimizer" / name)
        for name, files in plugin_trees.items():
            copy_tree(plugin / name, temporary / "Plugins" / "jev-optimizer" / name, files)
        for name in SCRIPTS:
            copy_file(repo / "scripts" / name, temporary / "scripts" / name, executable=True)
        for name in DOC_FILES:
            copy_file(repo / name, temporary / name)
        (temporary / "ROLLBACK.md").write_text(rollback_text(), encoding="utf-8")
        os.chmod(temporary / "ROLLBACK.md", 0o644)
        manifest = build_manifest(temporary, codesign)
        (temporary / "release-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="checkout to package (default: this script's checkout)")
    parser.add_argument("--binary", type=Path, help="already-built executable to package")
    parser.add_argument("--output", type=Path, help="new release directory to create")
    parser.add_argument("--verify-codesign", action="store_true",
                        help="also run read-only codesign display and strict verification; never signs")
    parser.add_argument("--dry-run", action="store_true", help="perform every source preflight without writing output")
    parser.add_argument("--verify-package", type=Path,
                        help="verify an existing package manifest and reject missing, changed, or unexpected files")
    args = parser.parse_args(argv)
    if args.verify_package:
        if args.binary or args.output or args.dry_run or args.verify_codesign:
            parser.error("--verify-package cannot be combined with packaging options")
    elif not args.binary or not args.output:
        parser.error("--binary and --output are required when preparing a package")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.verify_package:
            verify_package(args.verify_package)
            print(f"package verification passed: {absolute_path(args.verify_package)}")
            return 0
        prepare(args.repo, args.binary, args.output, args.verify_codesign, args.dry_run)
    except ReleaseError as error:
        print(f"release preflight failed: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"release packaging failed: {error}", file=sys.stderr)
        return 1
    print(("offline release preflight passed" if args.dry_run else f"offline release prepared: {args.output.resolve()}"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
