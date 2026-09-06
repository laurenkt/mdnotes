#!/usr/bin/env bash
# Assemble build/MDNotes.app from a release build. No Xcode project involved.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MDNotes"
BUNDLE_ID="dev.laurenkt.mdnotes"
VERSION="${MDNOTES_VERSION:-0.1.0}"
OUT="build/${APP_NAME}.app"

swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/${APP_NAME}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$OUT/Contents/Info.plist"
fi

codesign --force --sign - "$OUT"
echo "built $OUT"
