#!/usr/bin/env bash
# For the orchestrator, after a task subagent that worked in its own worktree returns:
#   scripts/land.sh <branch>
# Lands the task branch on main keeping history linear: rebase the branch onto main, then
# fast-forward main. Refuses when main has moved by anything other than docs-only commits
# since the branch was cut, because the branch's gate result would not carry over.
# Removes the branch's worktree and the branch afterwards (ADR-0018).
set -euo pipefail
cd "$(dirname "$0")/.."
branch="${1:?branch}"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "LAND: not on main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "LAND: main checkout dirty" >&2; exit 1; }
git rev-parse -q --verify "refs/heads/$branch" >/dev/null || { echo "LAND: no branch $branch" >&2; exit 1; }

base=$(git merge-base main "$branch")
ahead=$(git rev-list --count "$base..$branch")
[ "$ahead" -gt 0 ] || { echo "LAND: $branch has no commits"; echo "STATUS: nothing"; exit 0; }

# Main may only have moved by commits that touch no build input.
main_build=$(git diff --name-only "$base" main | grep -E '^(Sources/|Tests/|Package\.swift|Resources/)' || true)
if [ -n "$main_build" ]; then
    echo "LAND: main moved on build inputs since $branch was cut; refusing to land without a gate run:" >&2
    printf '%s\n' "$main_build" | sed 's/^/  /' >&2
    echo "STATUS: refused"
    exit 1
fi

wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '$1=="worktree"{w=$2} $1=="branch" && $2==b {print w}')

# Rebase inside the worktree if there is one (the branch is checked out there), else detached.
if [ -n "$wt" ]; then
    if ! git -C "$wt" rebase --quiet main >/dev/null 2>&1; then
        git -C "$wt" rebase --abort >/dev/null 2>&1 || true
        echo "LAND: rebase of $branch onto main conflicted; left for a human" >&2
        echo "STATUS: conflict"
        exit 1
    fi
else
    tmp=$(mktemp -d)
    git worktree add --quiet "$tmp" "$branch" >/dev/null
    if ! git -C "$tmp" rebase --quiet main >/dev/null 2>&1; then
        git -C "$tmp" rebase --abort >/dev/null 2>&1 || true
        git worktree remove --force "$tmp" >/dev/null 2>&1 || true
        echo "LAND: rebase of $branch onto main conflicted; left for a human" >&2
        echo "STATUS: conflict"
        exit 1
    fi
    git worktree remove --force "$tmp" >/dev/null
fi

git merge --ff-only --quiet "$branch"
echo "LAND: $branch landed, $ahead commit(s): $(git log -1 --format=%s | cut -c1-90)"

if [ -n "$wt" ]; then
    git worktree remove --force "$wt" >/dev/null 2>&1 && echo "LAND: worktree removed"
fi
git branch -D "$branch" >/dev/null 2>&1 && echo "LAND: branch deleted"
git worktree prune
echo "STATUS: landed"
