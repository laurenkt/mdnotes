#!/usr/bin/env bash
# Print the Info.plist for build/MDNotes.app to stdout.
# Kept separate from bundle.sh so a test can lint the generated plist without a release build.
#
#   MDNOTES_VERSION    CFBundleShortVersionString / CFBundleVersion (default 0.3.0)
#   MDNOTES_ICON_FILE  when set, adds CFBundleIconFile with this value
set -euo pipefail

APP_NAME="MDNotes"
BUNDLE_ID="dev.laurenkt.mdnotes"
VERSION="${MDNOTES_VERSION:-0.3.0}"
ICON_FILE="${MDNOTES_ICON_FILE:-}"

ICON_ENTRY=""
if [ -n "$ICON_FILE" ]; then
    ICON_ENTRY="    <key>CFBundleIconFile</key><string>${ICON_FILE}</string>"
fi

cat <<PLIST
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
${ICON_ENTRY}
</dict>
</plist>
PLIST
