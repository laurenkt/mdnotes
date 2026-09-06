#!/usr/bin/env bash
# The gate. Everything that must be green before a commit can land.
#
#   scripts/check.sh          full: format, build, unit tests, perf gates (release)
#   scripts/check.sh quick    same minus perf gates; for fast iteration only
#
# Perf gates only mean something in release builds, so they run in a separate
# `swift test -c release` pass filtered to *PerfTests classes.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-full}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

step "swift-format lint"
xcrun swift-format lint --strict --recursive --parallel Sources Tests Package.swift

step "build (debug, warnings are errors)"
swift build

step "unit + smoke tests (debug)"
MDNOTES_SKIP_PERF=1 swift test

if [ "$MODE" = "full" ]; then
    step "perf gates (release)"
    swift build -c release
    swift test -c release --filter 'PerfTests'
fi

step "check passed ($MODE)"
