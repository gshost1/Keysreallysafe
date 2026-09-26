#!/usr/bin/env python3
"""Assemble Keysrs.app from an already-built release binary.

The bundle holds the one SwiftPM executable (app with no arguments, CLI with
arguments), the dashboard, the price table, the icon and the licence files.
With no identity the bundle is signed ad hoc so it runs on this Mac; with an
identity it is signed for distribution under the frozen `keysreallysafe`
identifier and the team-pinned designated requirement Keychain items trust.
It never installs, launches or notarizes anything.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


APP_NAME = "Keysrs.app"
EXECUTABLE = "keys"
BUNDLE_IDENTIFIER = "com.keysreallysafe.keysrs"
# Keychain items trust this signing identifier; it is frozen across the rename.
SIGNING_IDENTIFIER = "keysreallysafe"
ICON_NAME = "Keysrs"

WEB_FILES = (
    "app.js", "analytics.js", "icon.png", "icon.svg", "index.html", "providers.json", "styles.css",
)
# providers.json ships inside Web/; only the price table lives beside it (LoginItem.stageFixtures).
FIXTURE_FILES = ("models.json",)
LICENSE_FILES = (
    "LICENSE", "THIRD_PARTY_NOTICES.md",
    "licenses/Keysreallysafe-legacy-MIT.txt", "licenses/swift-argument-parser.txt",
)
ICONSET_SIZES = (16, 32, 128, 256, 512)
VERSION_SOURCE = "Sources/KeysCore/ProductAnalytics.swift"


class BuildError(Exception):
    """A safe, actionable bundle-assembly error."""


def absolute_path(path: Path) -> Path:
    """Make a path absolute without following a symlink."""
    return Path(os.path.abspath(path))


def reject_symlink_ancestors(path: Path, boundary: Path, label: str) -> None:
    path = absolute_path(path)
    boundary = absolute_path(boundary)
    try:
        relative = path.relative_to(boundary)
    except ValueError:
        raise BuildError(f"{label} is outside required root {boundary}: {path}") from None
    current = boundary
    if current.is_symlink():
        raise BuildError(f"{label} has a symlink ancestor: {current}")
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise BuildError(f"{label} has a symlink ancestor: {current}")


def require_regular(path: Path, label: str, root: Path, executable: bool = False) -> None:
    reject_symlink_ancestors(path, root, label)
    if path.is_symlink():
        raise BuildError(f"{label} must not be a symlink: {path}")
    if not path.is_file():
        raise BuildError(f"missing required {label}: {path}")
    if executable and not os.access(path, os.X_OK):
        raise BuildError(f"{label} is not executable: {path}")


def copy_file(source: Path, destination: Path, executable: bool = False) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    os.chmod(destination, 0o755 if executable else 0o644)


def default_binary(repo: Path) -> Path:
    # SwiftPM's .build/release is a symlink to the triple directory; resolve that one
    # known link so the symlink checks below still apply to everything the caller passes.
    return (repo / ".build" / "release").resolve() / EXECUTABLE


def read_version(repo: Path) -> str:
    source = repo / VERSION_SOURCE
    require_regular(source, "version source", repo)
    match = re.search(r'static let appVersion = "([0-9]+\.[0-9]+\.[0-9]+)"',
                      source.read_text(encoding="utf-8"))
    if not match:
        raise BuildError(f"no appVersion string found in {VERSION_SOURCE}")
    return match[1]


def info_plist(version: str) -> dict[str, object]:
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "Keysrs",
        "CFBundleExecutable": EXECUTABLE,
        "CFBundleIconFile": ICON_NAME,
        "CFBundleIdentifier": BUNDLE_IDENTIFIER,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Keysrs",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
        # The window loads the dashboard over http from 127.0.0.1; allow loopback only.
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }


def run_tool(command: list[str]) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              check=True, timeout=120)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise BuildError(f"{Path(command[0]).name} failed: {detail or error.returncode}") from None
    except (OSError, subprocess.SubprocessError) as error:
        raise BuildError(f"{Path(command[0]).name} unavailable: {error}") from None


# The designed icon set carries hand-tuned 16-32 px glyphs and a 1024 px size;
# Web/icon.png is only 512 px, so it is the fallback.
DEFAULT_ICNS = Path("Assets/icon/Keysrs.icns")


def build_icns(source_png: Path, destination: Path, workdir: Path) -> None:
    """Scale the PNG with sips into an iconset, then pack it with iconutil.

    Sizes above the source's resolution are left out rather than upscaled.
    """
    iconset = workdir / f"{ICON_NAME}.iconset"
    iconset.mkdir()
    probe = run_tool(["/usr/bin/sips", "-g", "pixelWidth", str(source_png)])
    match = re.search(r"pixelWidth:\s*(\d+)", probe.stdout)
    width = int(match[1]) if match else 0
    if width < ICONSET_SIZES[0]:
        raise BuildError(f"icon source is too small or unreadable: {source_png}")
    for size in ICONSET_SIZES:
        for scale, suffix in ((1, ""), (2, "@2x")):
            pixels = size * scale
            if pixels > width:
                continue
            target = iconset / f"icon_{size}x{size}{suffix}.png"
            run_tool(["/usr/bin/sips", "-z", str(pixels), str(pixels), str(source_png), "--out", str(target)])
    destination.parent.mkdir(parents=True, exist_ok=True)
    run_tool(["/usr/bin/iconutil", "-c", "icns", "-o", str(destination), str(iconset)])
    if not destination.is_file():
        raise BuildError("iconutil produced no icon file")
    os.chmod(destination, 0o644)


def load_sign_local():
    path = Path(__file__).resolve().parent / "sign-local.py"
    spec = importlib.util.spec_from_file_location("sign_local", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def sign_bundle(app: Path, identity: str) -> None:
    """Sign the bundle once; the only Mach-O is Contents/MacOS/keys, so no --deep."""
    if identity == "-":
        run_tool(["/usr/bin/codesign", "--force", "--options", "runtime", "--identifier", SIGNING_IDENTIFIER,
                  "--sign", "-", str(app)])
        return
    if not re.fullmatch(r"[0-9a-fA-F]{40}", identity):
        raise BuildError("a signing identity must be a 40-character SHA-1 fingerprint, or - for ad hoc")
    signer = load_sign_local()
    try:
        signer.sign(str(app), identity, timestamp=True)
    except subprocess.CalledProcessError as error:
        raise BuildError(f"codesign failed: {(error.stderr or '').strip() or error.returncode}") from None
    except SystemExit as error:
        raise BuildError(str(error)) from None


def build(repo: Path, binary: Path, output: Path, identity: str = "-", version: str | None = None,
          icns: Path | None = None, replace: bool = False) -> Path:
    repo = absolute_path(repo)
    binary = absolute_path(binary)
    output = absolute_path(output)
    if repo.is_symlink() or not repo.is_dir():
        raise BuildError(f"repo must be an existing non-symlink directory: {repo}")
    require_regular(binary, "built keys binary", repo, executable=True)
    for name in WEB_FILES:
        require_regular(repo / "Web" / name, f"Web runtime file {name}", repo)
    # The app serves Web/ as a whole; a new dashboard file left off the allowlist would
    # ship a broken window, so stop instead of dropping it silently.
    unlisted = sorted(p.name for p in (repo / "Web").iterdir()
                      if not p.name.startswith(".") and p.name not in WEB_FILES)
    if unlisted:
        raise BuildError(f"Web/{unlisted[0]} is not in WEB_FILES in scripts/build-app.py; add it or remove it")
    for name in FIXTURE_FILES:
        require_regular(repo / "Fixtures" / name, f"fixture {name}", repo)
    for name in LICENSE_FILES:
        require_regular(repo / name, f"licence file {name}", repo)
    if icns is None and (repo / DEFAULT_ICNS).is_file():
        icns = repo / DEFAULT_ICNS
    if icns is not None:
        icns = absolute_path(icns)
        require_regular(icns, "icon file", repo)
    version = version or read_version(repo)
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise BuildError(f"version must look like 1.2.3: {version}")

    if output.is_symlink() or (output.exists() and not output.is_dir()):
        raise BuildError(f"output must be a directory, not a symlink or file: {output}")
    if output.parent.is_symlink() or not output.parent.is_dir():
        raise BuildError(f"output parent must be an existing non-symlink directory: {output.parent}")
    output.mkdir(exist_ok=True)
    app = output / APP_NAME
    if app.is_symlink() or (app.exists() and not app.is_dir()):
        raise BuildError(f"refusing to replace a non-directory at {app}")
    if app.exists() and not replace:
        raise BuildError(f"{app} already exists; pass --replace to rebuild it")

    temporary = Path(tempfile.mkdtemp(prefix=".Keysrs.", dir=output))
    try:
        staged = temporary / APP_NAME
        contents = staged / "Contents"
        resources = contents / "Resources"
        copy_file(binary.resolve(), contents / "MacOS" / EXECUTABLE, executable=True)
        for name in WEB_FILES:
            copy_file(repo / "Web" / name, resources / "Web" / name)
        for name in FIXTURE_FILES:
            copy_file(repo / "Fixtures" / name, resources / "Fixtures" / name)
        for name in LICENSE_FILES:
            copy_file(repo / name, resources / name)
        if icns is not None:
            copy_file(icns, resources / f"{ICON_NAME}.icns")
        else:
            build_icns(repo / "Web" / "icon.png", resources / f"{ICON_NAME}.icns", temporary)
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump(info_plist(version), handle, fmt=plistlib.FMT_XML, sort_keys=True)
        os.chmod(contents / "Info.plist", 0o644)
        for directory in (staged, *[p for p in staged.rglob("*") if p.is_dir()]):
            os.chmod(directory, 0o755)
        sign_bundle(staged, identity)
        if app.exists():
            shutil.rmtree(app)
        os.replace(staged, app)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)
    return app


def parse_args(argv: list[str]) -> argparse.Namespace:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=repo, help="checkout to read Web/, Fixtures/ and licences from")
    parser.add_argument("--binary", type=Path, help="release executable (default: .build/release/keys)")
    parser.add_argument("--output", type=Path, default=repo / ".build" / "app",
                        help="directory that will contain Keysrs.app (default: .build/app)")
    parser.add_argument("--sign", dest="identity", default="-",
                        help="40-character SHA-1 of a Developer ID / Apple Development identity; "
                             "default - signs ad hoc for local runs only")
    parser.add_argument("--version", help=f"bundle version (default: appVersion in {VERSION_SOURCE})")
    parser.add_argument("--icns", type=Path, help="prebuilt .icns inside the checkout (default Assets/icon/Keysrs.icns, else built from Web/icon.png)")
    parser.add_argument("--replace", action="store_true", help="replace an existing Keysrs.app in --output")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    binary = args.binary or default_binary(absolute_path(args.repo))
    try:
        app = build(args.repo, binary, args.output, args.identity, args.version, args.icns, args.replace)
    except BuildError as error:
        print(f"app build failed: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"app build failed: {error}", file=sys.stderr)
        return 1
    kind = "ad hoc (local use only)" if args.identity == "-" else "with the given identity"
    print(f"built {app}, signed {kind}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
