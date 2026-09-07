---
description: Orchestrate one plan task in a fresh subagent, verify it landed, tag milestones. Run as `/loop /next-task`.
allowed-tools: Bash(git *), Bash(grep *), Bash(cat *), Read, Edit, Agent, PushNotification
---

You are the orchestrator. You never implement tasks yourself; every task runs in a fresh
subagent so it starts with clean context. Keep your own output to a few lines.

## 1. Find the next task

Read `docs/PLAN.md`. The next task is the first line matching `- [ ] M<n>.<k>`.

- If there is none: report "plan complete" and, if running under `/loop`, stop the loop.
- If every remaining `[ ]` task depends on a `[?]` task (same milestone, later number, or an
  obvious dependency in its text): report which questions in `docs/QUESTIONS.md` are blocking
  and stop the loop.

Record `HEAD` before spawning: `git rev-parse HEAD`.

## 2. Spawn a subagent for exactly that task

Use the Agent tool, `subagent_type: general-purpose`, `run_in_background: false`, with this
prompt, substituting the full task line (including continuation lines):

```
You are working in /Users/laurenkt/Projects/mdnotes. Read CLAUDE.md, then docs/SPEC.md, then
the task below. Do exactly this one task from docs/PLAN.md and nothing else:

<TASK LINES>

Follow the loop protocol in CLAUDE.md steps 3 to 7: read the spec IDs it cites, write the
tests it names, iterate with scripts/check.sh quick, and if the task changes how a window
looks, render the snapshots (SPEC V-1), open the PNGs with the Read tool and compare them
against the spec and the design canvas in ADR-0013 before committing. Mark the task [x] in
docs/PLAN.md and commit with a message of the form "M1.1: <summary> (<spec IDs>)". The pre-commit hook runs the
full gate; if it fails, fix the code and commit again. Do not touch other tasks. If the spec
does not decide something you need, append a question to docs/QUESTIONS.md, mark the task
[?], and commit that instead. Finish with a clean working tree. Reply with one line: the
commit hash and what landed, or the question number if blocked.
```

## 3. Verify

After the subagent returns, check all of these with git and the plan file:

- `git status --porcelain` is empty. If not, that is a hook failure: report it and stop the loop.
- `HEAD` differs from the recorded value. If not, the subagent made no commit. Count it as a
  stall. Two consecutive stalls on the same task: stop the loop and report the subagent's reply.
- The task line is now `[x]` or `[?]`. If `[?]`, report the question and continue to the next
  tick (the next task will be picked up automatically).

## 4. Milestone tag

If the task's milestone (`## M<n>` section) now has no `[ ]` or `[?]` lines, run
`git tag m<n>` if that tag does not already exist, and mention it in the report.

## 5. Notify the human's phone

Use `PushNotification` (status `proactive`, one line, under 200 characters) only for:

- A task blocked into `docs/QUESTIONS.md`: `MDNotes blocked on Q3 (M2.6): <question in a few words>. Reply here to answer.`
- A milestone tag: `MDNotes: m2 tagged, 9 tasks done, starting M3.`
- The loop stopping for any reason: plan complete, two stalls, or everything blocked.

Never notify for an ordinary task landing.

## 6. Handling a reply from the human

If the human's message answers an open question (they may reply from the phone): write the
answer into that entry's `Answer:` line in `docs/QUESTIONS.md`; if it changes product
behaviour, add a short ADR in `docs/adr/` and amend `docs/SPEC.md` accordingly; flip the task
from `[?]` back to `[ ]`; commit all of that yourself with message `Qn answered: <summary>`.
The next tick will pick the task up. Do not implement the task in the orchestrator.

## 7. Report

One or two lines: task ID, commit hash, milestone tag if any, and how many `[ ]` tasks remain.
Then let the loop schedule the next tick.
