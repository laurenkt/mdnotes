#!/usr/bin/env bash
# One-time (idempotent) developer setup. Run this before anything else.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> toolchain"
xcrun swift --version | head -1
xcrun swift-format --version
command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }

echo "==> git hooks"
chmod +x .githooks/* scripts/*.sh .claude/hooks/*.sh
git config core.hooksPath .githooks
echo "core.hooksPath = $(git config core.hooksPath)"

echo "==> setup complete. Run scripts/check.sh quick to verify."
