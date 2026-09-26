#!/bin/bash
# Pack a prepare-release.py output directory into a styled Keysrs-arm64.dmg:
# volume icon, a background with an arrow from Keysrs to Applications, and a
# fixed Finder window layout. It does not sign or notarize the DMG.
# Usage: scripts/build-dmg.sh <staged dir with Keysrs.app + Applications> <output.dmg>
# Finder lays the window out through AppleScript, so the first run asks for
# permission to control Finder. Keep the icon positions in step with
# scripts/dmg-background.swift.
set -euo pipefail
STAGED="$1"
OUT="$2"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(basename "$OUT")" = Keysrs-arm64.dmg ] || { echo "output must be named Keysrs-arm64.dmg" >&2; exit 1; }
[ -d "$STAGED/Keysrs.app" ] && [ -L "$STAGED/Applications" ] || { echo "$STAGED is not a prepare-release output" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "$OUT already exists" >&2; exit 1; }

WORK="$(mktemp -d)"
MNT=/Volumes/Keysrs
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT
swift "$REPO/scripts/dmg-background.swift" "$WORK/background.tiff"

hdiutil create -srcfolder "$STAGED" -volname Keysrs -fs APFS -format UDRW -size 60m "$WORK/rw.dmg" -quiet
# Finder only lays out volumes it can see, i.e. ones mounted under /Volumes, and
# addresses them by name, so no other "Keysrs" volume may be mounted.
[ ! -e "$MNT" ] || { echo "eject the mounted Keysrs volume first" >&2; exit 1; }
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -quiet
[ -d "$MNT/Keysrs.app" ] || { echo "the image did not mount at $MNT" >&2; exit 1; }
mkdir "$MNT/.background"
cp "$WORK/background.tiff" "$MNT/.background/background.tiff"
cp "$REPO/Assets/icon/Keysrs.icns" "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT"

osascript <<EOF
tell application "Finder"
  set d to disk "Keysrs"
  open d
  set w to container window of d
  set current view of w to icon view
  set toolbar visible of w to false
  set statusbar visible of w to false
  set bounds of w to {200, 120, 860, 520}
  set o to icon view options of w
  set arrangement of o to not arranged
  set icon size of o to 128
  set text size of o to 13
  set background picture of o to file ".background:background.tiff" of d
  set position of item "Keysrs.app" of d to {170, 185}
  set position of item "Applications" of d to {490, 185}
  update d without registering applications
  delay 1
  close w
end tell
EOF
# Hide the helper files from the window; Finder has written .DS_Store by now.
SetFile -a V "$MNT/.background" 2>/dev/null || true
sync
hdiutil detach "$MNT" -quiet
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
echo "built $OUT"
