# ADR-0006: Local-only git with mechanical gates

Status: accepted, 2026-09-06

## Decision
No remote, no CI. One commit per task on `main`, milestones tagged. `scripts/check.sh full`
is the gate: format lint, build with warnings as errors, unit and smoke tests in debug, perf
gates in release. A git pre-commit hook runs it. Claude Code hooks block hook bypass flags,
pushes, hook-path changes, history rewriting, Xcode tooling, and writes to the real notes
folder. A Stop hook refuses to end a turn with a dirty working tree.

Execution is one fresh subagent per task, driven by `/loop /next-task` from an orchestrator
session that only verifies and tags. No branches, merges, or worktrees: the plan is serial and
`PLAN.md` checkboxes would be the first merge conflict.

## Why
The agent runs unattended on a task list, and the owner reviews at milestone boundaries.
With no CI, the only defence against a red commit is making a red commit impossible locally,
and the only defence against unverified work is making a commit the sole way to finish.

## Consequences
Commits are slow (release build plus perf tests). Iteration uses `scripts/check.sh quick`.
History is append-only, so mistakes are fixed forward.
