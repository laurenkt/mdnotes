#!/usr/bin/env bash
# For the orchestrator, after a subagent returns:
#   scripts/verify-item.sh <head-before> <id>
# Prints a few RESULT lines. Tags a completed milestone itself.
set -euo pipefail
cd "$(dirname "$0")/.."
before="${1:?head before}"; id="${2:?item id}"

status=ok
dirty=$(git status --porcelain)
if [ -n "$dirty" ]; then
    echo "DIRTY: $(printf '%s\n' "$dirty" | wc -l | tr -d ' ') paths"
    status=dirty
fi

head=$(git rev-parse HEAD)
if [ "$head" = "$before" ]; then
    echo "COMMIT: none"
    status=stall
else
    echo "COMMIT: $(git rev-parse --short HEAD) $(git log -1 --format=%s | cut -c1-100)"
fi

case "$id" in
    I-*)
        state=$(grep -oE "^- \[.\] $id " docs/ISSUES.md | head -1 | cut -c4)
        ;;
    *)
        state=$(grep -oE "^- \[.\] $id " docs/PLAN.md | head -1 | cut -c4)
        ;;
esac
echo "ITEM: $id [${state:-?}]"
[ "${state:-}" = " " ] && status=stall

added=$(git diff "$before" HEAD --unified=0 -- docs/ISSUES.md 2>/dev/null | grep -cE '^\+- \[ \] I-' || true)
[ "$added" -gt 0 ] && echo "ISSUES_ADDED: $added"

if [ "${id#M}" != "$id" ]; then
    m=$(printf '%s' "$id" | grep -oE '^M[0-9]+' | tr -d M)
    remaining=$(awk -v h="## M$m:" '
        $0 ~ "^" h { inms = 1; next }
        inms && /^## / { exit }
        inms && (/^- \[ \]/ || /^- \[\?\]/) { n++ }
        END { print n + 0 }
    ' docs/PLAN.md)
    if [ "$remaining" -eq 0 ]; then
        if git rev-parse -q --verify "refs/tags/m$m" >/dev/null; then
            echo "MILESTONE: m$m already tagged"
        else
            git tag "m$m"
            echo "MILESTONE: m$m tagged now"
        fi
    fi
fi

echo "OPEN: $(grep -c '^- \[ \] M' docs/PLAN.md || true) tasks, $(grep -c '^- \[ \] I-' docs/ISSUES.md || true) issues"
echo "STATUS: $status"
