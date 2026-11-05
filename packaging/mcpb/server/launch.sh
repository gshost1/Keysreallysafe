#!/bin/sh
# Starts the installed app's MCP server over stdio. The bundle holds no app,
# key or setting: it only finds Keysrs.app and hands its stdio to `keys mcp`.
APP=/Applications/Keysrs.app/Contents/MacOS/keys
if [ ! -x "$APP" ]; then
  echo "Keysrs.app is not installed at /Applications/Keysrs.app." >&2
  echo "Install it first: brew install --cask gshost1/keysrs/keysrs, or https://keysrs.com" >&2
  exit 1
fi
exec "$APP" mcp
