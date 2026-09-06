---
description: Orchestrate one plan task in a fresh subagent, verify it landed, tag milestones. Run as `/loop /next-task`.
allowed-tools: Bash(git *), Bash(grep *), Bash(cat *), Read, Agent
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

Follow the loop protocol in CLAUDE.md steps 3 to 6: read the spec IDs it cites, write the
tests it names, iterate with scripts/check.sh quick, mark the task [x] in docs/PLAN.md, and
commit with a message of the form "M1.1: <summary> (<spec IDs>)". The pre-commit hook runs the
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

## 5. Report

One or two lines: task ID, commit hash, milestone tag if any, and how many `[ ]` tasks remain.
Then let the loop schedule the next tick.
