#!/usr/bin/env bash
# Stop hook. The agent may not end a turn with uncommitted work: a commit is the
# only way to run the full gate, so uncommitted work is unverified work.
set -euo pipefail
input="$(cat)"
# Prevent infinite loops: if we are already inside a stop-hook continuation, let it stop.
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ]; then
    exit 0
fi
cd "$(dirname "$0")/../.."
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi
dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then
    {
        echo "Uncommitted changes remain. Either finish the task and commit (the pre-commit gate will run),"
        echo "or if the task cannot be completed, record why in docs/QUESTIONS.md and commit that."
        echo "Do not stop with a dirty working tree."
        echo "$dirty"
    } >&2
    exit 2
fi
exit 0
