#!/usr/bin/env bash
# For the orchestrator: print the next item to work on, and nothing else.
# Open issues go first; when more than three are open, alternate with plan tasks.
set -euo pipefail
cd "$(dirname "$0")/.."

item_lines() { # $1 file, $2 literal prefix of the first line; prints it plus its continuation lines
    awk -v pre="$2" '
        found && (/^- \[/ || /^## / || /^$/) { exit }
        found { print; next }
        index($0, pre) == 1 { found = 1; print }
    ' "$1"
}

open_issues=$(grep -c '^- \[ \] I-' docs/ISSUES.md || true)
open_tasks=$(grep -c '^- \[ \] M' docs/PLAN.md || true)
blocked_tasks=$(grep -c '^- \[?\] M' docs/PLAN.md || true)
last_subject=$(git log -1 --format=%s)

pick_issue=false
if [ "$open_issues" -gt 0 ]; then
    if [ "$open_issues" -le 3 ] || [ "${last_subject#I-}" = "$last_subject" ]; then
        pick_issue=true
    fi
fi

if $pick_issue; then
    lines=$(item_lines docs/ISSUES.md '- [ ] I-')
    id=$(printf '%s\n' "$lines" | head -1 | grep -oE 'I-[0-9]+' || true)
    echo "KIND: issue"
elif [ "$open_tasks" -gt 0 ]; then
    lines=$(item_lines docs/PLAN.md '- [ ] M')
    id=$(printf '%s\n' "$lines" | head -1 | grep -oE 'M[0-9]+\.[0-9]+[a-z]?' || true)
    echo "KIND: task"
else
    echo "KIND: none"
    id=""
    lines=""
fi

[ -n "$id" ] && echo "ID: $id"
[ -n "$lines" ] && printf '%s\n' "$lines"
echo "OPEN: $open_tasks tasks, $blocked_tasks blocked, $open_issues issues"
scripts/inbox-status.sh
echo "HEAD: $(git rev-parse HEAD)"
