---
description: Orchestrate one plan task or issue in a fresh subagent, verify it landed, tag milestones. Run as `/loop /next-task`.
allowed-tools: Bash(scripts/next-item.sh:*), Bash(scripts/verify-item.sh:*), Bash(scripts/log-metric.sh:*), Bash(git add:*), Bash(git commit:*), Edit, Agent, PushNotification
---

You are the orchestrator. You never implement anything; every item runs in a fresh subagent.
Keep your context small: do not read PLAN.md, ISSUES.md, SPEC.md or source files. The
scripts below print exactly what you need. Keep your own output to two lines.

## 1. Next item

Run `scripts/next-item.sh`. It prints `KIND`, `ID`, the item's lines, `OPEN` counts and `HEAD`.

- `KIND: none` with blocked tasks in `OPEN`: report that the plan is blocked on
  `docs/QUESTIONS.md`, notify (step 4), and stop the loop.
- `KIND: none` with nothing blocked: report "plan complete", notify, stop the loop.

## 2. Spawn a subagent

Agent tool, `subagent_type: general-purpose`, `run_in_background: false`. For a task:

```
You are working in /Users/laurenkt/Projects/mdnotes. Run `scripts/task-brief.sh <ID>` and read
its output: it holds the task, the spec bullets it cites, and the codebase map. Then read
CLAUDE.md. Do not read docs/SPEC.md in full and do not explore the codebase beyond what the
map and the task need. Do exactly this one task and nothing else:

<ITEM LINES>

Follow the loop protocol in CLAUDE.md steps 3 to 7: write the tests the task names, iterate
with scripts/check.sh quick, and if the task changes how a window looks, render the snapshots
(SPEC V-1), open the PNGs with the Read tool and compare them against the spec and the design
canvas in ADR-0013 before committing. Mark the task [x] in docs/PLAN.md, update docs/MAP.md
if you added, removed or moved a file, and commit as "<ID>: <summary> (<spec IDs>)". The
pre-commit hook runs the full gate; if it fails, fix and commit again. If the spec does not
decide something you need, append a question to docs/QUESTIONS.md, mark the task [?], and
commit that instead. Problems outside the task follow the Issues rule in CLAUDE.md. Finish
with a clean working tree. Reply with one line: commit hash and what landed, or the question
number if blocked.
```

For an issue:

```
You are working in /Users/laurenkt/Projects/mdnotes. Run `scripts/task-brief.sh <ID>` and read
its output, then read CLAUDE.md. Do not read docs/SPEC.md in full. Fix exactly this one issue:

<ITEM LINES>

Reproduce it first with a test that fails, then fix it, mark the entry [x] in docs/ISSUES.md,
update docs/MAP.md if files changed, and commit as "<ID>: <summary>". A flaky entry is fixed
by reducing variance, never by raising a budget. If the fix is larger than one commit, add a
task at the top of the current milestone in docs/PLAN.md, mark the entry [x] -> M<n>.<k>, and
commit that instead. Other problems follow the Issues rule in CLAUDE.md. Finish with a clean
working tree. Reply with one line: commit hash and what landed.
```

## 3. Verify and log

Run `scripts/verify-item.sh <HEAD from step 1> <ID>`. It prints `COMMIT`, `ITEM`, optional
`DIRTY`, `ISSUES_ADDED` and `MILESTONE` lines (it creates the milestone tag itself), and
`STATUS`.

- `STATUS: dirty`: a hook failed. Report and stop the loop.
- `STATUS: stall`: no commit or item still open. Second consecutive stall on the same ID:
  report the subagent's reply and stop the loop. Otherwise continue.
- `STATUS: ok`: run `scripts/log-metric.sh <ID> <subagent tokens> <duration ms>` with the
  numbers from the Agent result's usage line. It appends the row and commits it itself (the
  pre-commit gate skips a commit that touches only `docs/METRICS.md`).

## 4. Notify the phone

`PushNotification` (status `proactive`, one line, under 200 characters) only for: an item
blocked into `docs/QUESTIONS.md` (`MDNotes blocked on Q3 (M2.6): <few words>. Reply here.`),
a `MILESTONE` line (`MDNotes: m6 tagged, 9 open, starting M7.`), or the loop stopping.
Never for an ordinary item landing.

## 5. Replies from the human

If the human answers an open question (possibly from the phone): write the answer into that
entry's `Answer:` line in `docs/QUESTIONS.md`; if it changes behaviour, add a short ADR and
amend `docs/SPEC.md`; flip the task from `[?]` to `[ ]`; commit as `Qn answered: <summary>`.
The next tick picks it up. Do not implement it yourself.

## 6. Report

Two lines at most: `<ID> <short hash> <what landed>` and `<OPEN line>` plus any tag. Then let
the loop schedule the next tick.
