#!/usr/bin/env python3
"""Prepare a reproducible, offline Keysrs release directory and optional DMG.

The input is an already-built and already-signed Keysrs.app (see
scripts/build-app.py). The output directory holds exactly what the DMG window
shows: Keysrs.app and an Applications symlink, plus a hidden checksum manifest.
This tool never signs, queries Keychain identities, notarizes, installs an
app, launches a native authorization flow, or inspects/modifies a live
installation.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


def _load_build_app():
    path = Path(__file__).resolve().parent / "build-app.py"
    spec = importlib.util.spec_from_file_location("build_app", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


build_app = _load_build_app()

APP_NAME = build_app.APP_NAME
WEB_FILES = build_app.WEB_FILES
FIXTURE_FILES = build_app.FIXTURE_FILES
LICENSE_FILES = build_app.LICENSE_FILES
MANIFEST_NAME = ".release-manifest.json"
# The Finder drag-to-install target; the only symlink a package may contain.
PACKAGE_SYMLINKS = {"Applications": "/Applications"}
DMG_NAME = "Keysrs-arm64.dmg"  # keysrs.com download links depend on this name
VOLUME_NAME = "Keysrs"

ReleaseError = build_app.BuildError
absolute_path = build_app.absolute_path
reject_symlink_ancestors = build_app.reject_symlink_ancestors
require_regular = build_app.require_regular


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def expected_app_files() -> dict[str, str]:
    """Relative path inside Keysrs.app -> the checkout file it must equal (or '' if built)."""
    files = {
        "Contents/Info.plist": "",
        f"Contents/MacOS/{build_app.EXECUTABLE}": "",
        f"Contents/Resources/{build_app.ICON_NAME}.icns": "",
        "Contents/_CodeSignature/CodeResources": "",
    }
    files.update({f"Contents/Resources/Web/{name}": f"Web/{name}" for name in WEB_FILES})
    files.update({f"Contents/Resources/Fixtures/{name}": f"Fixtures/{name}" for name in FIXTURE_FILES})
    files.update({f"Contents/Resources/{name}": name for name in LICENSE_FILES})
    return files


def walk_files(root: Path) -> list[Path]:
    """Every entry under root, never following a link; directories are omitted."""
    found = []
    for directory, subdirs, names in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in subdirs:
            if (base / name).is_symlink():
                found.append(base / name)
        found.extend(base / name for name in names)
    return sorted(found)


def check_app(repo: Path, app: Path) -> None:
    """Check the bundle against the shared layout before anything is copied."""
    if app.is_symlink() or not app.is_dir() or app.name != APP_NAME:
        raise ReleaseError(f"app must be an existing non-symlink {APP_NAME} directory: {app}")
    expected = expected_app_files()
    actual = set()
    for path in walk_files(app):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            raise ReleaseError(f"app must not contain a symlink: {relative}")
        if not path.is_file():
            raise ReleaseError(f"app contains a non-regular file: {relative}")
        if relative not in expected:
            raise ReleaseError(f"app contains an unexpected file: {relative}")
        actual.add(relative)
    missing = sorted(set(expected) - actual)
    if missing:
        if missing == ["Contents/_CodeSignature/CodeResources"]:
            raise ReleaseError("app is not signed; run scripts/build-app.py --sign <identity> first")
        raise ReleaseError(f"app is missing required file: {missing[0]}")
    for relative, source in expected.items():
        if source:
            require_regular(repo / source, f"checkout file {source}", repo)
            # Licence texts and runtime files must ship exactly as committed.
            if (app / relative).read_bytes() != (repo / source).read_bytes():
                raise ReleaseError(f"app file differs from the checkout: {relative}")
    if not os.access(app / "Contents" / "MacOS" / build_app.EXECUTABLE, os.X_OK):
        raise ReleaseError("app executable is not executable")
    try:
        with (app / "Contents" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError):
        raise ReleaseError("app Info.plist is not a valid property list") from None
    wanted = build_app.info_plist(build_app.read_version(repo))
    for key, value in wanted.items():
        if info.get(key) != value:
            raise ReleaseError(f"app Info.plist {key} is {info.get(key)!r}, expected {value!r}")


def copy_app(app: Path, destination: Path) -> None:
    for path in walk_files(app):
        target = destination / path.relative_to(app)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        os.chmod(target, 0o755 if os.access(path, os.X_OK) else 0o644)
    for directory in (destination, *[p for p in destination.rglob("*") if p.is_dir()]):
        os.chmod(directory, 0o755)


def verify_codesign(app: Path) -> dict[str, str]:
    """Optionally run read-only codesign checks; never request or use an identity."""
    result: dict[str, str] = {"requested": "true"}
    commands = (
        ("display", ["/usr/bin/codesign", "--display", "--verbose=4", str(app)]),
        ("verify", ["/usr/bin/codesign", "--verify", "--strict", str(app)]),
    )
    for name, command in commands:
        try:
            completed = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                       text=True, check=False, timeout=30)
            result[name] = "passed" if completed.returncode == 0 else "failed"
            if name == "display":
                lines = (completed.stderr or "").splitlines()
                result["identifier"] = ("passed" if f"Identifier={build_app.SIGNING_IDENTIFIER}" in lines
                                        else "failed")
        except (OSError, subprocess.SubprocessError):
            result[name] = "unavailable"
    checks = [name for name, _ in commands] + ["identifier"]
    result["status"] = "passed" if all(result.get(name) == "passed" for name in checks) else "not_verified"
    return result


def build_manifest(root: Path, codesign: dict[str, str]) -> dict[str, object]:
    entries = []
    for path in walk_files(root):
        relative = path.relative_to(root).as_posix()
        if relative == MANIFEST_NAME or path.is_symlink():
            continue
        entries.append({"path": relative, "sha256": sha256(path), "bytes": path.stat().st_size})
    return {
        "format": 2,
        "purpose": "offline Keysrs release candidate",
        "reproducibility": "ordered allowlisted files with SHA-256 checksums; no timestamps or source contents",
        "release_status": {
            "signing": "unvalidated; this tool performed no signing",
            "notarization": "unvalidated; this tool performed no notarization",
            "live_installation": "unvalidated; this tool did not inspect or modify a live installation",
        },
        "codesign_verification": codesign,
        "symlinks": dict(PACKAGE_SYMLINKS),
        "checksums": entries,
    }


def verify_package(package: Path) -> None:
    package = absolute_path(package)
    if package.is_symlink() or not package.is_dir():
        raise ReleaseError(f"package must be an existing non-symlink directory: {package}")
    manifest_path = package / MANIFEST_NAME
    require_regular(manifest_path, "release manifest", package)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        checksums = manifest["checksums"]
        symlinks = manifest["symlinks"]
    except (OSError, ValueError, KeyError, TypeError):
        raise ReleaseError("release manifest is not valid JSON with a checksum list") from None
    if not isinstance(checksums, list) or symlinks != PACKAGE_SYMLINKS:
        raise ReleaseError("release manifest checksum or symlink list is invalid")
    expected: dict[str, dict[str, object]] = {}
    for item in checksums:
        if not isinstance(item, dict) or set(item) != {"path", "sha256", "bytes"}:
            raise ReleaseError("release manifest contains an invalid checksum entry")
        relative = item["path"]
        if (not isinstance(relative, str) or not isinstance(item["sha256"], str)
                or type(item["bytes"]) is not int or relative in expected):
            raise ReleaseError("release manifest contains an invalid checksum entry")
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise ReleaseError("release manifest contains an unsafe checksum path")
        expected[relative] = item
    actual: set[str] = set()
    for path in walk_files(package):
        relative = path.relative_to(package).as_posix()
        if path.is_symlink():
            if PACKAGE_SYMLINKS.get(relative) != os.readlink(path):
                raise ReleaseError(f"package contains an unexpected symlink: {relative}")
            continue
        reject_symlink_ancestors(path, package, "package file")
        if not path.is_file():
            raise ReleaseError(f"package contains a non-regular file: {path}")
        if relative != MANIFEST_NAME:
            actual.add(relative)
    for name, target in PACKAGE_SYMLINKS.items():
        link = package / name
        if not link.is_symlink() or os.readlink(link) != target:
            raise ReleaseError(f"package is missing the {name} symlink")
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
    for name in LICENSE_FILES:
        if f"{APP_NAME}/Contents/Resources/{name}" not in expected:
            raise ReleaseError(f"package is missing licence file {name}")


def make_dmg(package: Path, dmg: Path) -> None:
    """Pack the verified package into a compressed, unsigned DMG with hdiutil."""
    dmg = absolute_path(dmg)
    if dmg.name != DMG_NAME:
        raise ReleaseError(f"DMG must be named {DMG_NAME}; the site's download links depend on it")
    if dmg.is_symlink() or dmg.exists():
        raise ReleaseError(f"DMG must not already exist: {dmg}")
    if dmg.parent.is_symlink() or not dmg.parent.is_dir():
        raise ReleaseError(f"DMG parent must be an existing non-symlink directory: {dmg.parent}")
    verify_package(package)
    command = ["/usr/bin/hdiutil", "create", "-volname", VOLUME_NAME, "-srcfolder", str(package),
               "-fs", "APFS", "-format", "UDZO", str(dmg)]
    try:
        subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True, timeout=600)
    except subprocess.CalledProcessError as error:
        raise ReleaseError(f"hdiutil create failed: {(error.stderr or '').strip() or error.returncode}") from None
    except (OSError, subprocess.SubprocessError) as error:
        raise ReleaseError(f"hdiutil unavailable: {error}") from None


def prepare(repo: Path, app: Path, output: Path, check_codesign: bool, dry_run: bool = False) -> None:
    repo = absolute_path(repo)
    app = absolute_path(app)
    output = absolute_path(output)
    if repo.is_symlink() or not repo.is_dir():
        raise ReleaseError(f"repo must be an existing non-symlink directory: {repo}")
    if output.is_symlink() or output.exists():
        raise ReleaseError(f"output must not already exist: {output}")
    if output.parent.is_symlink() or not output.parent.is_dir():
        raise ReleaseError(f"output parent must be an existing non-symlink directory: {output.parent}")
    check_app(repo, app)

    codesign = verify_codesign(app) if check_codesign else {
        "requested": "false", "status": "not_requested (no signing or signing verification performed)"
    }
    if dry_run:
        return
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    try:
        copy_app(app, temporary / APP_NAME)
        os.chmod(temporary, 0o755)
        manifest = build_manifest(temporary, codesign)
        for name, target in PACKAGE_SYMLINKS.items():
            os.symlink(target, temporary / name)
        (temporary / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                               encoding="utf-8")
        os.chmod(temporary / MANIFEST_NAME, 0o644)
        os.replace(temporary, output)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="checkout the app was built from (default: this script's checkout)")
    parser.add_argument("--app", type=Path, help="already-built, already-signed Keysrs.app to package")
    parser.add_argument("--output", type=Path, help="new release directory to create")
    parser.add_argument("--dmg", type=Path, help=f"also pack the new directory into this {DMG_NAME} (unsigned)")
    parser.add_argument("--verify-codesign", action="store_true",
                        help="also run read-only codesign display and strict verification; never signs")
    parser.add_argument("--dry-run", action="store_true", help="perform every source preflight without writing output")
    parser.add_argument("--verify-package", type=Path,
                        help="verify an existing package manifest and reject missing, changed, or unexpected files")
    args = parser.parse_args(argv)
    if args.verify_package:
        if args.app or args.output or args.dry_run or args.verify_codesign or args.dmg:
            parser.error("--verify-package cannot be combined with packaging options")
    elif not args.app or not args.output:
        parser.error("--app and --output are required when preparing a package")
    elif args.dry_run and args.dmg:
        parser.error("--dmg cannot be combined with --dry-run")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.verify_package:
            verify_package(args.verify_package)
            print(f"package verification passed: {absolute_path(args.verify_package)}")
            return 0
        prepare(args.repo, args.app, args.output, args.verify_codesign, args.dry_run)
        if args.dmg:
            make_dmg(args.output, args.dmg)
    except ReleaseError as error:
        print(f"release preflight failed: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"release packaging failed: {error}", file=sys.stderr)
        return 1
    if args.dry_run:
        print("offline release preflight passed")
    else:
        print(f"offline release prepared: {absolute_path(args.output)}")
        if args.dmg:
            print(f"unsigned DMG created: {absolute_path(args.dmg)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
