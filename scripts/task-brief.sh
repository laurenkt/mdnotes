#!/usr/bin/env bash
# For a task subagent: everything it needs to start, and nothing it does not.
#   scripts/task-brief.sh M6.5      or      scripts/task-brief.sh I-3
# Prints: the item's lines, the spec bullets for every spec ID the item cites, the ADRs it
# cites, and the codebase map. Read this instead of SPEC.md.
set -euo pipefail
cd "$(dirname "$0")/.."
id="${1:?item id}"

item_lines() { # $1 file, $2 item id; the first line is "- [<state>] <id> ..."
    awk -v id="$2" '
        found && (/^- \[/ || /^## / || /^$/) { exit }
        found { print; next }
        substr($0, 1, 3) == "- [" && substr($0, 7, length(id) + 1) == id " " { found = 1; print }
    ' "$1"
}

case "$id" in
    I-*) file=docs/ISSUES.md ;;
    *)   file=docs/PLAN.md ;;
esac
lines=$(item_lines "$file" "$id")
if [ -z "$lines" ]; then echo "no item $id in $file" >&2; exit 1; fi

echo "# Item $id"
printf '%s\n' "$lines"
echo

ids=$(printf '%s\n' "$lines" | grep -oE '\b(P|L|S|C|E|X|R|D|K|T|I|W|PR|PF|TP|V)-[0-9]+\b' | sort -u -t- -k1,1 -k2,2n || true)
if [ -n "$ids" ]; then
    echo "# Spec bullets cited by the item (docs/SPEC.md)"
    for sid in $ids; do
        awk -v sid="$sid" '
            found && (/^- \*\*/ || /^## / || /^$/) { exit }
            found { print; next }
            $0 ~ "^- \\*\\*" sid "\\*\\*" { found = 1; print }
        ' docs/SPEC.md
    done
    echo
fi

adrs=$(printf '%s\n' "$lines" | grep -oE 'ADR-[0-9]{4}' | sort -u || true)
if [ -n "$adrs" ]; then
    echo "# ADRs cited"
    for a in $adrs; do
        n=${a#ADR-}
        f=$(ls docs/adr/"$n"-*.md 2>/dev/null | head -1)
        [ -n "$f" ] && { echo "## $f"; sed -n '/^## Decision/,/^## Why/p' "$f" | sed '$d'; echo; }
    done
fi

if [ -f docs/MAP.md ]; then
    echo "# Codebase map (docs/MAP.md)"
    cat docs/MAP.md
fi
