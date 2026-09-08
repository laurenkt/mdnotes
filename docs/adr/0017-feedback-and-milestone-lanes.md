# ADR-0017: Feedback and milestone conversations feed an inbox the orchestrator applies

Status: accepted, 2026-09-08

## Decision
Two commands run grilling interviews in any session: `/feedback` for niggles, scheduled at
the end of the current milestone, and `/milestone` for features, scheduled as a new milestone
after the last planned one. Both write only new files: inbox items under `docs/inbox/`,
ADRs, and proposal drafts under `docs/proposals/`, committed immediately by path. The
orchestrator, at the start of each tick, absorbs docs-only branches (`scripts/absorb.sh`) and
spawns an apply subagent that merges ready inbox items into `docs/PLAN.md` and
`docs/SPEC.md`. Phone messages to the orchestrator are captured verbatim as seeds. Commits
that touch no build input skip the pre-commit gate.

## Why
The owner wants to evolve the product through conversations while the loop keeps building,
with niggles handled without interrupting the task in flight and features scheduled well
ahead. Earlier, harness sessions editing shared files in the checkout left task subagents
facing a dirty tree they rightly refused to commit. Restricting discussion sessions to new
files removes that conflict outright; it also makes docs-only worktree branches trivially
mergeable, so worktree isolation is safe for discussion (not for implementation, which
stays serial on main for the perf-gate reason in ADR-0016). Skipping the gate for docs-only
commits stops a conversation's commit from contending with a subagent's release build.

## Consequences
The orchestrator is the only writer of PLAN.md and SPEC.md. Spec amendments are applied
verbatim from inbox files, so the interview must produce final bullet text. A seed is only
text; nothing happens to it until a human grills it.
