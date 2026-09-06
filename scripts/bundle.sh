#!/usr/bin/env bash
# Assemble build/MDNotes.app from a release build. No Xcode project involved.
# The Info.plist comes from scripts/info-plist.sh so tests can lint it on its own.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MDNotes"
OUT="build/${APP_NAME}.app"

swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/${APP_NAME}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
    export MDNOTES_ICON_FILE="AppIcon"
fi
scripts/info-plist.sh > "$OUT/Contents/Info.plist"
plutil -lint "$OUT/Contents/Info.plist"

codesign --force --sign - "$OUT"
echo "built $OUT"
