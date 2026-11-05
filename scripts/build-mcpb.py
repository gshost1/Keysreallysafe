#!/usr/bin/env python3
"""Pack packaging/mcpb into Keysrs.mcpb for the MCP Registry.

The bundle is a zip of manifest.json, icon.png and the launcher that starts the
installed app's `keys mcp`; it holds no app, key or setting. The zip is
deterministic (sorted names, fixed timestamps and modes, stored not deflated so
no zlib build can change the bytes), so the SHA-256 the
script prints is the `fileSha256` for server.json, and rebuilding the same
checkout gives the same hash. Nothing is uploaded or published.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "packaging" / "mcpb"
FILES = ("manifest.json", "icon.png", "server/launch.sh")
EXECUTABLE = {"server/launch.sh"}
FIXED_TIME = (1980, 1, 1, 0, 0, 0)


class BuildError(Exception):
    pass


def app_version() -> str:
    text = (REPO / "Sources/KeysCore/AppVersion.swift").read_text(encoding="utf-8")
    match = re.search(r'static let current = "([^"]+)"', text)
    if not match:
        raise BuildError("AppVersion.current not found")
    return match.group(1)


def build(output: Path) -> str:
    manifest = json.loads((SOURCE / "manifest.json").read_text(encoding="utf-8"))
    version = app_version()
    if manifest["version"] != version:
        raise BuildError(f"manifest.json version {manifest['version']} != AppVersion.current {version}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_STORED) as bundle:
        for name in sorted(FILES):
            path = SOURCE / name
            if path.is_symlink() or not path.is_file():
                raise BuildError(f"{name} must be a regular file")
            info = zipfile.ZipInfo(name, FIXED_TIME)
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = (0o100755 if name in EXECUTABLE else 0o100644) << 16
            bundle.writestr(info, path.read_bytes())
    return hashlib.sha256(output.read_bytes()).hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=REPO / ".build" / "mcpb" / "Keysrs.mcpb")
    args = parser.parse_args(argv)
    try:
        digest = build(args.output)
    except BuildError as error:
        print(f"build-mcpb: {error}", file=sys.stderr)
        return 1
    print(f"{digest}  {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
