#!/usr/bin/env bash
# Append one row to docs/METRICS.md: scripts/log-metric.sh <item> <subagent-tokens> <duration-ms>
set -euo pipefail
cd "$(dirname "$0")/.."
item="${1:?item}"; tokens="${2:?tokens}"; ms="${3:?ms}"
mins=$(( ms / 60000 ))
printf '| %s | %s | %s | %s | %s |\n' "$(date +%Y-%m-%d\ %H:%M)" "$item" "$tokens" "$mins" "$(git rev-parse --short HEAD)" >> docs/METRICS.md
# Commit only this file. The pre-commit gate skips a metrics-only commit.
if [ -n "$(git status --porcelain | grep -v ' docs/METRICS.md$')" ]; then
    echo "working tree has other changes; metrics row appended but not committed" >&2
    exit 0
fi
git add docs/METRICS.md
git commit -q -m "metrics: $item" -- docs/METRICS.md
echo "logged and committed $item"
