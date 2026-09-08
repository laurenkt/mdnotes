---
description: Grill the human about a new feature and, when settled, queue it as a new milestone after the last planned one. Usage: /milestone <name>. Resumes a draft proposal of that name.
allowed-tools: Bash(scripts/*), Bash(git add:*), Bash(git commit:*), Bash(git mv:*), Bash(git log:*), Bash(git status:*), Bash(grep:*), Bash(cat:*), Bash(ls:*), Read, Write, AskUserQuestion, Agent, Skill
---

You are running a milestone interview for the feature named `$ARGUMENTS`. The outcome is a
proposal draft in `docs/proposals/`, or when settled an inbox item in `docs/inbox/` plus an
ADR, all committed at once. You never edit `docs/PLAN.md`, `docs/SPEC.md` or source files;
the orchestrator applies inbox items. This session may be in a worktree.

## Start

If `docs/proposals/<slug>.md` exists, read it: it is a draft from an earlier conversation.
Summarise its settled decisions in a few lines and continue from its open questions. If not,
start fresh. Either way, read `docs/MAP.md`, the spec sections the feature touches, and the
last milestone in `docs/PLAN.md` (`grep -n '^## M' docs/PLAN.md | tail -1`) so the new one
numbers on from it.

## Interview

Grilling protocol, one `AskUserQuestion` per turn, tradeoffs in prose first, recommended
option first. Look facts up yourself; if a fact needs real exploration, use an Explore
subagent. Cover, in rounds as the tree unfolds: the problem and who it is for; scope and the
explicit non-goals; how it fits the one-field model and the "feels instant" rule; every
spec section it changes or adds; performance implications and whether any new budget is
needed (never a raised one); how it is tested headlessly; what the acceptance pass checks;
what is deferred. When the frontier is empty, present the shared understanding and confirm
with one final question.

If the human stops before the frontier is empty, or asks to pause, write or update
`docs/proposals/<slug>.md` (status `draft`, the design tree so far with settled decisions and
open questions) and commit it by path: `git commit -m "proposal: <name> draft" -- docs/proposals/<slug>.md`.

## Outcome

On confirmation write `docs/inbox/<YYYY-MM-DD>-<slug>.md`:

```
---
kind: milestone
schedule: after-last
title: M<n>: <milestone title>
---
## Tasks
- [ ] <ordered tasks, one commit each, each naming spec IDs and the test it adds; the last
      two are a manual acceptance pass and a version tag>
## Spec amendments
add section 17:
## 17. <Title> *(v3, ADR-00NN)*
- **XX-1** ...
replace K-2 with:
- **K-2** ...
## ADR
docs/adr/00NN-<slug>.md
```

Write the ADR now (Decision, Why, Consequences). If a proposal draft exists, `git mv` it to
`docs/proposals/accepted/`. Commit only the files you created or moved, by path, message
`milestone: <title>`. Report in two lines: the milestone number it will get and how many
tasks. Do not tell the human how the orchestrator works unless asked.
