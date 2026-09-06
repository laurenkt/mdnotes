#!/usr/bin/env bash
# PreToolUse hook for Bash. Blocks commands that would defeat the guardrails.
# Exit 2 = block, with the reason on stderr fed back to the agent.
set -euo pipefail
cmd="$(jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0

deny() { echo "BLOCKED by .claude/hooks/guard-bash.sh: $1" >&2; exit 2; }

case "$cmd" in
    *--no-verify*)            deny "git --no-verify bypasses the pre-commit gate. Fix the failure instead." ;;
    *"git push"*)             deny "this repo is local-only; there is no remote to push to." ;;
    *"core.hooksPath"*)       deny "git hooks path must stay at .githooks." ;;
    *"MDNOTES_SKIP_PERF"*)    deny "perf gates may not be skipped from the shell; use scripts/check.sh quick during iteration and let pre-commit run the full gate." ;;
    *xcodebuild*|*xcodegen*|*"open "*.xcodeproj*|*"generate-xcodeproj"*)
                              deny "no Xcode projects: this is a pure SwiftPM package (docs/adr/0002)." ;;
    *"git reset --hard"*|*"git checkout -- "*|*"git restore "*|*"git clean"*)
                              deny "destructive git operations are not allowed; make a new commit that fixes things." ;;
    *"git commit --amend"*)   deny "history is append-only; make a new commit." ;;
    *"git rebase"*|*"git filter-branch"*)
                              deny "history is append-only." ;;
    *"git merge"*|*"git branch"*|*"git worktree"*|*"git checkout -b"*|*"git switch"*)
                              deny "single linear main only: no branches, merges, or worktrees (docs/adr/0006)." ;;
    *"rm -rf docs"*|*"rm -rf .claude"*|*"rm -rf .githooks"*|*"rm -rf scripts"*)
                              deny "guardrail files may not be deleted." ;;
esac

# Never let the agent touch the user's real notes library.
case "$cmd" in
    *"Documents/MDnotes"*)
        case "$cmd" in
            *"ls "*|*"cat "*|*"head "*|*"grep "*|*"find "*|*"wc "*|*"stat "*|*"du "*) exit 0 ;;
            *) deny "the real notes library (~/Documents/MDnotes) is read-only for the agent. Use a temp copy or the synthetic library." ;;
        esac
        ;;
esac
exit 0
