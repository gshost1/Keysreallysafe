#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-}"
if [ -z "$BIN" ]; then
  if [ -x "$ROOT/.build/release/keys" ]; then
    BIN="$ROOT/.build/release/keys"
  elif [ -x "$ROOT/.build/debug/keys" ]; then
    BIN="$ROOT/.build/debug/keys"
  else
    echo "no keys binary; run swift build first" >&2
    exit 1
  fi
fi
exec python3 "$ROOT/scripts/sign-local.py" "$BIN"
