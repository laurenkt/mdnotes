---
description: Grill the human about a niggle or small change, then queue it for the end of the current milestone. Usage: /feedback [topic]. No topic: work through phone seeds.
allowed-tools: Bash(scripts/*), Bash(git add:*), Bash(git commit:*), Bash(git log:*), Bash(git status:*), Bash(grep:*), Bash(cat:*), Bash(ls:*), Read, Write, AskUserQuestion, Agent
---

You are running a feedback interview. The outcome is one or more files in `docs/inbox/`,
committed at once. You never edit `docs/PLAN.md`, `docs/SPEC.md` or any source file: the
orchestrator applies inbox items at a safe point. This session may be in a worktree; that is
fine, its commits are absorbed.

## Topic

If `$ARGUMENTS` is empty, run `scripts/inbox-status.sh` and take the seeds it lists, one at a
time, oldest first; read each seed file for the verbatim text. Otherwise the topic is
`$ARGUMENTS`.

## Interview

Follow the grilling protocol, adapted to this human's preference: exactly one
`AskUserQuestion` per turn, never several; before each question lay out the tradeoffs in
prose when the choice is technical; put your recommended option first with "(Recommended)".
Facts are your job: before asking anything, read `docs/MAP.md`, grep `docs/SPEC.md` for the
bullets the topic touches, and open the files the map points at. Never ask the human for
something you can look up. Do not run the app.

Work the design tree until the frontier is empty: what exactly is wrong or wanted, what the
spec currently says, which spec bullets change and to what, what the acceptance test is,
what is out of scope. Then present the shared understanding as a short summary, including
any assumption you made, and ask for confirmation with one final `AskUserQuestion`.

## Outcome

On confirmation, for each distinct change write `docs/inbox/<YYYY-MM-DD>-<slug>.md`:

```
---
kind: feedback
schedule: end-of-current
title: <one line>
---
## Tasks
- [ ] <task text in PLAN.md style: what, spec IDs, the test it must add>
## Spec amendments
replace S-6 with:
- **S-6** <full new bullet text>
add after S-11:
- **S-12** *(v2)* <full bullet text>
## ADR
docs/adr/00NN-<slug>.md
```

Rules for the outcome:

- Tasks are one commit each and name the test they add. A task may say `before M7.4` on its
  first line if it must precede a planned task; otherwise it lands at the end of the
  milestone holding the next open task.
- A change to product behaviour needs a spec amendment and a short ADR (Decision, Why,
  Consequences), written now to `docs/adr/` with the next free number. Pure bug fixes
  against existing spec need neither; cite the existing IDs.
- Never propose changing a perf budget.
- If the topic is a feature rather than a niggle, say so and tell the human to run
  `/milestone <name>` instead; write nothing.

Commit only the files you created, by path, so nothing else in the checkout is touched:

```
git add docs/inbox/<file>.md docs/adr/<file>.md
git commit -m "feedback: <title>" -- docs/inbox/<file>.md docs/adr/<file>.md
```

If you consumed a seed, `git mv` it to `docs/inbox/applied/` in the same commit. Then
report in two lines: what was queued and where it will land.
