---
description: Orchestrate one plan task or issue in a fresh subagent, verify it landed, tag milestones. Run as `/loop /next-task`.
allowed-tools: Bash(scripts/next-item.sh:*), Bash(scripts/verify-item.sh:*), Bash(scripts/log-metric.sh:*), Bash(scripts/absorb.sh:*), Bash(scripts/land.sh:*), Bash(scripts/record-seed.sh:*), Bash(git add:*), Bash(git commit:*), Edit, Agent, PushNotification
---

You are the orchestrator. You never implement anything; every item runs in a fresh subagent.
Keep your context small: do not read PLAN.md, ISSUES.md, SPEC.md or source files. The
scripts below print exactly what you need. Keep your own output to two lines.

## 0. Absorb and apply the inbox

Run `scripts/absorb.sh` (merges docs-only branches from discussion sessions; prints
`ABSORBED: n`). Then run `scripts/next-item.sh`. If its `INBOX` line shows one or more
`ready` items and no `DIRTY` state is expected (the previous tick ended clean), spawn an
apply subagent before anything else, `subagent_type: general-purpose`,
`run_in_background: false`:

```
You are working in /Users/laurenkt/Projects/mdnotes. Read docs/inbox/README.md, then every
file in docs/inbox/ whose kind is feedback or milestone (not seeds). Apply each one to the
plan and spec, exactly as written:
- schedule end-of-current: append its tasks after the last task line of the milestone that
  holds the first open `- [ ]` task in docs/PLAN.md, numbered on from that milestone's last
  number (M7.13, M7.14 ...). A task whose first line says `before M7.4` goes directly before
  that task instead, numbered M7.3a, M7.3b ....
- schedule after-last: append a new `## M<n>: <title>` section after the last section in
  docs/PLAN.md, numbering its tasks M<n>.1 onward, where n is one more than the last.
- Spec amendments: apply verbatim to docs/SPEC.md (replace the named bullet, or add after
  the named bullet or section). Check the named ADR file exists.
- git mv the inbox file to docs/inbox/applied/.
Commit everything as "inbox: <titles> -> <task ids>". The gate is skipped for docs-only
commits. Do not implement anything. Reply with one line naming the task ids created.
```

Then continue with the item below (re-run `scripts/next-item.sh` after an apply).

## 1. Next item

The `scripts/next-item.sh` output prints `KIND`, `ID`, the item's lines, `OPEN` counts,
`INBOX`, `BRANCHES` and `HEAD`.

- `KIND: none` with blocked tasks in `OPEN`: report that the plan is blocked on
  `docs/QUESTIONS.md`, notify (step 4), and stop the loop.
- `KIND: none` with nothing blocked: report "plan complete", notify, stop the loop.

## 2. Spawn a subagent in its own worktree

First check `git rev-parse origin/main main` prints the same hash twice; if not, run
`git push -q origin main` before spawning (worktrees are cut from `origin/main`).

Agent tool, `subagent_type: general-purpose`, `run_in_background: false`,
`isolation: "worktree"` (ADR-0018: a fresh worktree and branch cut from main; the subagent's
working directory is that worktree). Substitute the `HEAD` hash from step 1 into the prompt.
For a task:

```
You are working in a fresh git worktree of the MDNotes repo, on your own branch cut from
main; your current directory is that worktree and every path below is relative to it. First
confirm `git rev-parse HEAD` prints <HEAD>; if it does not, reply with the single line
`STALE BASE` and stop. Run every build, test and gate command in the foreground with a
generous timeout (up to 600000 ms), never in the background, and never end your turn to wait
for a notification: your turn ends only when the commit exists and `git status` is clean. Run
`scripts/task-brief.sh <ID>` and read its output: it holds the task, the spec bullets it
cites, and the codebase map. Then read CLAUDE.md. Do not read docs/SPEC.md in full and do
not explore the codebase beyond what the map and the task need. Do exactly this one task and
nothing else:

<ITEM LINES>

Follow the loop protocol in CLAUDE.md steps 3 to 7: write the tests the task names, iterate
with scripts/check.sh quick, and if the task changes how a window looks, render the snapshots
(SPEC V-1), open the PNGs with the Read tool and compare them against the spec and the design
canvas in ADR-0013 before committing. Mark the task [x] in docs/PLAN.md, update docs/MAP.md
if you added, removed or moved a file, and commit as "<ID>: <summary> (<spec IDs>)". The
pre-commit hook runs the full gate; if it fails, fix and commit again. If the spec does not
decide something you need, append a question to docs/QUESTIONS.md, mark the task [?], and
commit that instead. Problems outside the task follow the Issues rule in CLAUDE.md. Finish
with a clean working tree. Reply with two lines: `BRANCH: ` followed by the output of
`git rev-parse --abbrev-ref HEAD`, then the commit hash and what landed, or the question
number if blocked.
```

For an issue:

```
You are working in a fresh git worktree of the MDNotes repo, on your own branch cut from
main; your current directory is that worktree. First confirm `git rev-parse HEAD` prints
<HEAD>; if it does not, reply with the single line `STALE BASE` and stop. Run every build,
test and gate command in the foreground with a generous timeout (up to 600000 ms), never in
the background, and never end your turn to wait for a notification: your turn ends only when
the commit exists and `git status` is clean. Run `scripts/task-brief.sh <ID>` and read its
output, then read CLAUDE.md. Do not read docs/SPEC.md in full. Fix exactly this one issue:

<ITEM LINES>

Reproduce it first with a test that fails, then fix it, mark the entry [x] in docs/ISSUES.md,
update docs/MAP.md if files changed, and commit as "<ID>: <summary>". A flaky entry is fixed
by reducing variance, never by raising a budget. If the fix is larger than one commit, add a
task at the top of the current milestone in docs/PLAN.md, mark the entry [x] -> M<n>.<k>, and
commit that instead. Other problems follow the Issues rule in CLAUDE.md. Finish with a clean
working tree. Reply with two lines: `BRANCH: ` followed by the output of
`git rev-parse --abbrev-ref HEAD`, then the commit hash and what landed.
```

## 3. Land, verify and log

Run `scripts/land.sh <BRANCH from the reply>`. It rebases the branch onto main, fast-forwards
main, and removes the worktree and branch; it prints `STATUS: landed`, `nothing`, `refused`
or `conflict`. On `refused` or `conflict`, report the message and stop the loop: main moved
on build inputs during the task, which should never happen, and a human must look. On
`nothing`, treat it as a stall (below) and remove the branch's worktree by running
`scripts/land.sh` again after the stall count is handled.

Then run `scripts/verify-item.sh <HEAD from step 1> <ID>`. It prints `COMMIT`, `ITEM`,
optional `DIRTY`, `ISSUES_ADDED` and `MILESTONE` lines (it creates the milestone tag itself),
and `STATUS`.

- `STATUS: dirty`: the main checkout is dirty, which no subagent should cause any more.
  Report and stop the loop.
- `STATUS: stall`: no commit or item still open. Second consecutive stall on the same ID:
  report the subagent's reply and stop the loop. Otherwise continue.
- `STATUS: ok`: run `scripts/log-metric.sh <ID> <subagent tokens> <duration ms>` with the
  numbers from the Agent result's usage line. It appends the row and commits it itself (the
  pre-commit gate skips a commit that touches only `docs/METRICS.md`).

Finally run `git push -q origin main` (add `--tags` when a `MILESTONE` line appeared). The
Agent tool's worktree isolation cuts task worktrees from `origin/main`, not local `main`, so
origin must follow every landing or the next subagent starts from a stale base (this happened
on 2026-09-15: the M10.3 worktree was cut six commits behind and `land.sh` refused it). Plain
pushes are allowed in `.claude/settings.json`; force-pushes stay denied.

## 4. Notify the phone

`PushNotification` (status `proactive`, one line, under 200 characters) only for: an item
blocked into `docs/QUESTIONS.md` (`MDNotes blocked on Q3 (M2.6): <few words>. Reply here.`),
a `MILESTONE` line (`MDNotes: m6 tagged, 9 open, starting M7.`), or the loop stopping.
Never for an ordinary item landing.

## 5. Messages from the human

If the human answers an open question (possibly from the phone): write the answer into that
entry's `Answer:` line in `docs/QUESTIONS.md`; if it changes behaviour, add a short ADR and
amend `docs/SPEC.md`; flip the task from `[?]` to `[ ]`; commit as `Qn answered: <summary>`.
The next tick picks it up. Do not implement it yourself.

Any other message from the human that is feedback, an idea, or a request (not an instruction
about the loop itself): run `scripts/record-seed.sh "<their text verbatim>"` and reply with
one line, `captured as <file>; run /feedback to work through it`. Do not discuss it, do not
act on it, do not change the plan.

## 6. Report

Two lines at most: `<ID> <short hash> <what landed>` and `<OPEN line>` plus any tag. Then let
the loop schedule the next tick.
