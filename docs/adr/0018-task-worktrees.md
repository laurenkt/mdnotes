# ADR-0018: Each task runs in a fresh worktree off main and lands by rebase and fast-forward

Status: accepted, 2026-09-08

## Decision
The orchestrator spawns every task subagent with worktree isolation. The subagent works and
commits, through the gate, on its own branch cut from the current `main`. When it returns,
`scripts/land.sh` refuses unless `main` has moved only by docs-only commits since the cut,
rebases the branch onto `main`, fast-forwards `main`, and removes the worktree and branch.
The orchestrator itself never leaves the main checkout. History stays linear (ADR-0006).

## Why
The main checkout was shared by the task in flight, conversation sessions and the human,
and a subagent regularly found files that were not its own. Isolating each task removes that
class of problem, keeps the main checkout always clean and inspectable, and leaves a failed
task as a branch to look at rather than a half-edited tree. Rebase is safe because between
items `main` receives only docs-only commits (metrics, absorbed inbox files, seeds), which
cannot change a gate result; the inbox apply step runs between items for that reason.

## Consequences
Each task pays a cold build in its worktree: SwiftPM caches are path-keyed, so a fresh
worktree rebuilds debug, release and tests from scratch, a few minutes per task. Perf gates
stay serial. Read-only helper agents still run in the main checkout. `land.sh` is the only
sanctioned rebase; the Bash guard keeps blocking rebase and worktree commands typed by agents.
