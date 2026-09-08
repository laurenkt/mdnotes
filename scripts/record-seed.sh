#!/usr/bin/env bash
# For the orchestrator: capture a human message verbatim as an inbox seed and commit it.
#   scripts/record-seed.sh "<text>"
set -euo pipefail
cd "$(dirname "$0")/.."
text="${1:?text}"
stamp=$(date +%Y-%m-%d-%H%M%S)
f="docs/inbox/seed-$stamp.md"
{
    echo "---"
    echo "kind: seed"
    echo "title: $(printf '%s' "$text" | head -c 60 | tr '\n' ' ')"
    echo "---"
    printf '%s\n' "$text"
} > "$f"
git add "$f"
git commit -q -m "seed: $(printf '%s' "$text" | head -c 50 | tr '\n' ' ')" -- "$f"
echo "captured $f"
