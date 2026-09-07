#!/usr/bin/env bash
# Append an entry to docs/ISSUES.md. Used by check.sh for flakes; agents may call it too.
#
#   scripts/record-issue.sh <kind> <where> <one-line description>
#   kind: flaky | bug | debt
set -euo pipefail
cd "$(dirname "$0")/.."
kind="${1:?kind}"; where="${2:?where}"; desc="${3:?description}"
case "$kind" in flaky|bug|debt) ;; *) echo "kind must be flaky, bug or debt" >&2; exit 1 ;; esac
file="docs/ISSUES.md"
last="$(grep -oE '^- \[.\] I-[0-9]+' "$file" | grep -oE '[0-9]+$' | sort -n | tail -1)"
n=$(( ${last:-0} + 1 ))
today="$(date +%Y-%m-%d)"
# Do not record the same flaky subject twice while an entry for it is still open.
if [ "$kind" = "flaky" ] && grep -qE "^- \[ \] I-[0-9]+ flaky \`$where\`" "$file"; then
    echo "open flaky entry for $where already exists; not adding another" >&2
    exit 0
fi
printf -- '- [ ] I-%d %s `%s` (%s): %s\n' "$n" "$kind" "$where" "$today" "$desc" >> "$file"
echo "recorded I-$n in $file"
