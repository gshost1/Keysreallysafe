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
codesign -s - --force --identifier keysreallysafe --entitlements "$ROOT/Packaging/keys.entitlements" "$BIN"
echo "ad-hoc signed $BIN (identifier keysreallysafe)"
