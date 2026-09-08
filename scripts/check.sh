#!/usr/bin/env bash
# The gate. Everything that must be green before a commit can land.
#
#   scripts/check.sh          full: format, build, unit tests, perf gates (release)
#   scripts/check.sh quick    same minus perf gates; for fast iteration only
#
# Perf gates only mean something in release builds, so they run in separate
# `swift test -c release` passes, one per *PerfTests class. Each class gets its own
# process because the gates are absolute measurements of that class's subject: PF-5 is
# the resident size after a full index, and a class that has shown a 1 MB note in a
# window before it in the same process leaves tens of megabytes behind that TextKit and
# AppKit never hand back, which would count against the index. scripts/perf-gate.sh runs
# each class: a failed gate is retried once and a pass on retry is recorded as a flake
# (ADR-0016), and an attempt that fails while the machine is loaded is not counted (I-6).
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
    swift build -c release --build-tests
    for class in $(grep -rhoE 'class [A-Za-z0-9_]+PerfTests' Tests | awk '{print $2}' | sort -u); do
        step "perf gate: $class"
        scripts/perf-gate.sh "$class"
    done
fi

step "check passed ($MODE)"
