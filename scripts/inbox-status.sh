#!/usr/bin/env bash
# Print what is waiting in docs/inbox: ready items (kind feedback or milestone) and seeds.
set -euo pipefail
cd "$(dirname "$0")/.."
ready=(); seeds=()
for f in docs/inbox/*.md; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "README.md" ] && continue
    kind=$(sed -n '2,6p' "$f" | grep -m1 '^kind:' | awk '{print $2}' || true)
    case "$kind" in
        feedback|milestone) ready+=("$f") ;;
        seed) seeds+=("$f") ;;
    esac
done
echo "INBOX: ${#ready[@]} ready, ${#seeds[@]} seeds"
for f in "${ready[@]:-}"; do [ -n "$f" ] && echo "  ready: $f ($(grep -m1 '^schedule:' "$f" | awk '{print $2}')) $(grep -m1 '^title:' "$f" | cut -d' ' -f2-)"; done
for f in "${seeds[@]:-}"; do [ -n "$f" ] && echo "  seed: $f"; done
echo "BRANCHES: $(git for-each-ref --format='%(refname:short)' refs/heads/ | grep -vx main | tr '\n' ' ')"
