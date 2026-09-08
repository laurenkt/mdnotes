#!/usr/bin/env bash
# For the orchestrator, at the start of a tick: merge every local branch other than main whose
# changes touch only non-build paths (docs/, .claude/, CLAUDE.md, README.md, scripts/,
# .githooks/), then delete it. Branches that touch Sources/, Tests/, Package.swift or
# Resources/ are left alone with a warning: implementation happens on main only (ADR-0006).
# This is the one sanctioned merge in the repo (ADR-0017).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    echo "absorb: not on main; nothing done" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "absorb: working tree dirty; nothing done"
    exit 0
fi

merged=0
for b in $(git for-each-ref --format='%(refname:short)' refs/heads/ | grep -vx main); do
    # Already absorbed: nothing new on the branch since it was merged.
    if git merge-base --is-ancestor "$b" main; then
        continue
    fi
    base=$(git merge-base main "$b")
    build_paths=$(git diff --name-only "$base" "$b" | grep -E '^(Sources/|Tests/|Package\.swift|Resources/)' || true)
    if [ -n "$build_paths" ]; then
        echo "absorb: skipping $b, it touches build inputs:"; printf '%s\n' "$build_paths" | sed 's/^/  /'
        continue
    fi
    if git merge --no-edit -m "absorb: $b" "$b" >/dev/null 2>&1; then
        echo "absorb: merged $b"
        merged=$((merged + 1))
        # A branch with a worktree may still have a session open in it: keep both. A bare
        # branch has served its purpose.
        wt=$(git worktree list --porcelain | awk -v b="refs/heads/$b" '$1=="worktree"{w=$2} $1=="branch" && $2==b {print w}')
        if [ -z "$wt" ]; then
            git branch -d "$b" >/dev/null 2>&1 && echo "absorb: deleted $b"
        fi
    else
        git merge --abort >/dev/null 2>&1 || true
        echo "absorb: conflict merging $b; left for a human" >&2
    fi
done
echo "ABSORBED: $merged"
