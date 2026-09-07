#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift.
# The .icns is committed; run this only when the artwork changes, then commit the result.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift scripts/make-icon.swift "$TMP/AppIcon.iconset"
mkdir -p Resources
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
