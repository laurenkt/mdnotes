# ADR-0016: An issue queue drained ahead of plan tasks, with flakes recorded automatically

Status: accepted, 2026-09-07

## Decision
`docs/ISSUES.md` is a queue of problems noticed outside the task at hand. A subagent fixes
in place only when the fix is a few lines in code the task already changes and this commit's
tests cover it; everything else is recorded, not fixed. The orchestrator drains open entries before the next plan task, one subagent
and one commit each, alternating with plan tasks when more than three are open. Entries must
be one-commit sized or be redirected to a plan task. `scripts/check.sh` retries a failed perf
gate once; a pass on retry lets the commit through and records a `flaky` entry; a second
failure fails the gate.

## Why
v1 had nowhere to put "I noticed X while doing Y". Bugs surfaced only at the acceptance pass
(M5.6a to M5.6e) and a perf flake went unrecorded. Fixing incidental problems inside
unrelated commits hides them; ignoring them lets the codebase deteriorate. A queue drained
immediately keeps the project healthy without letting nitpicks stall milestones.

Parallel worktrees were considered for this and rejected: perf gates are wall-clock
measurements on one machine, and concurrent builds and test runs would manufacture the very
flakes the queue exists to fix; merges would also need the full gate again and an agent
resolving conflicts in hot files like `PLAN.md`.

## Consequences
A flake no longer blocks a commit, so a slowly regressing budget could pass on retries for a
while; the queue entry is the alarm, and a flaky entry may only be fixed by reducing
variance, never by raising the budget. History gains `I-<n>:` commits interleaved with tasks.
