# Open questions

Append-only log. When a task cannot proceed without a decision that `SPEC.md` does not make,
add an entry here, mark the task `[?]` in `PLAN.md`, and move to the next task that does not
depend on it. The human answers by editing the entry and, if needed, `SPEC.md` via an ADR.

Format:

```
## Q<n>: <one-line question>            (task: M?.?, date)
Context: what was being attempted and why the spec is insufficient.
Options: the choices seen, with a recommendation.
Answer: (left blank for the human)
```

## Q1: After Enter on a nested path (`daily/foo`), what should the list show and select?   (task: M2.6b, 2026-09-06)
Context: C-4 says the search field keeps the query "so the list still shows the new note".
That holds for a flat title: the words of `foo bar` are substrings of the title `foo bar`
(S-2). It cannot hold for a nested query: `daily/foo` creates `daily/foo.md` whose title is
`foo` (L-5) and whose body is empty, and the word `daily/foo` is a substring of neither, so
the kept query lists nothing and the new note cannot be selected in the list. The same gap
applies to C-1 opening an existing `daily/foo.md` by its path.
M2.6a ships this interim behaviour: the file and folders are created (C-2), the editor shows
the new note empty and focused, the query is kept, and the list selection is cleared because
the note is not listed. Two related rules were derived rather than decided, and are flagged
here for review: (a) C-1 also treats a query equal (ignoring case) to a note's path without
`.md` as naming that note, so `daily/foo` opens `daily/foo.md` rather than writing an empty
file over it; the exact-path note wins over other notes with the same title, and among title
matches the most recently modified opens (as K-2 does for ambiguous links). (b) C-3 also
rejects, inline, queries that cannot make a listable note: an empty segment (`a//b`, `/a`,
`a/`), a `.` or `..` segment, a segment starting with `.` (hidden, L-3), and a first segment
of `Trash` or `templates` (L-3).
Options:
  1. Match query words against the note's relative path (without `.md`) as well as its
     title, so `daily/foo` lists `daily/foo.md`. Changes S-2 and touches the index (ADR).
  2. After a nested create, replace the field's text with the new title (`foo`) so the list
     shows it. Changes C-4's "keeps the query".
  3. Accept the interim behaviour: nested notes are reachable through the editor only until
     the query changes. No spec change, but C-4 is knowingly unmet for nested paths.
  Recommendation: option 1, scoped to path-form matching only when a query word contains `/`,
  so flat queries are unchanged and PF-2 is unaffected for the common case.
Answer: Option 1 (2026-09-07). A query word containing `/` also matches the note's relative
  path without `.md`; words without `/` are unchanged. The derived C-1 (path-equal opens,
  exact path beats same-title, newest among title matches) and C-3 (unlistable segments
  rejected) rules are confirmed. Recorded in ADR-0008; S-2, C-1 and C-3 amended.

## Q2: Untracked harness files appeared during the M6.4 commit; whose are they?   (task: M6.4, 2026-09-08)
Context: M6.4 landed as 55b31fa with a clean tree. Between the pre-commit gate starting and
the commit finishing (09:03:25 to 09:03:50), five untracked files were written into the
checkout by another session: `docs/METRICS.md`, `scripts/log-metric.sh`,
`scripts/next-item.sh`, `scripts/task-brief.sh`, `scripts/verify-item.sh`. They are
orchestrator tooling, not part of M6.4, and were still being written when the M6.4
session finished. The Stop hook requires a clean tree, so this entry is committed instead.
Options:
  1. The session that wrote them commits them under its own message (recommended: they are
     its work and it knows whether they are complete).
  2. A later task session sweeps them into an unrelated commit. Not recommended: it would
     commit another session's half-written files.
  3. Delete them. Not acceptable from a task session: they are not its files.
  Recommendation: option 1. The M6.4 session left them untouched and uncommitted. M6.4
  itself is complete and needs no answer; this entry only explains the dirty tree.
Answer: Option 1 (2026-09-08). They were the harness session's orchestrator scripts, written
  while the loop was running; that session committed them itself. Leaving them alone and
  recording this was the right call. No task is affected.

## Q3: TP-3's example date letters (`YYYY`, `DD`, `dddd`) are not what a Unicode pattern means by them; which should the spec say?   (task: M9.1, 2026-09-09)
Context: TP-3 says FORMAT is a Unicode date format pattern, and M9.1 says it is handed to
`DateFormatter`; M9.1 implements exactly that (`TemplateParser`). But the letters TP-3 lists
as examples, and the TP-8 daily path `daily/{{date:YYYY}}/{{date:MM-MMMM}}/{{date:DD-dddd}}`,
read as moment.js-style tokens: under Unicode `YYYY` is the week-based year (differs from the
calendar year around New Year), `DD` is the day of the year (`252` on 9 September) and `dddd`
is the day of the month padded to four digits (`0009`), so TP-8 as written yields
`daily/2026/09-September/252-0009` rather than `.../09-Wednesday`. The Unicode spelling of the
intended path is `daily/{{date:yyyy}}/{{date:MM-MMMM}}/{{date:dd-EEEE}}`, which works today.
Not blocking: the mechanism is decided in two places and shipped; only the examples are off.
Options: (1) keep Unicode patterns and correct the examples in TP-3 and TP-8 to `yyyy`, `MM`,
`MMMM`, `dd`, `EEEE`, `HH`, `mm` (a docs fix, no ADR needed for behaviour); (2) add
moment-style aliases (`YYYY`→`yyyy`, `DD`→`dd`, `dddd`→`EEEE`) on top of Unicode via an ADR,
which makes `YYYY` and `DD` unreachable in their Unicode meaning and mixes two grammars.
Recommendation: option 1.
Answer:

## Q4: The PF-1 cold-launch assertion fails on this machine with the unchanged M10.2 tree; how does a finished task land while it does?   (task: M10.3, 2026-09-15)
Context: M10.3 is implemented and green on every gate but one: `LaunchPerfTests
.testPF1_finishLaunchingToListPopulatedAndWindowKeyUnder300msWith20kNotes` asserts the first
(cold) launch in the process under 300 ms and measured 444 to 600 ms in more than twenty
attempts across five pre-commit runs and two probe rounds between 10:00 and 11:10, with the
1-minute load average between 2.3 and 6.7 (WindowServer at 45 % and the Claude and Codex
apps busy; Spotlight workers present; no other build running). The median of the seven
launches was 200 to 220 ms every time. The same tree with the M10.2 `EditorStyler` and its
tests put back measured 530 and 552 ms cold, so the change is not the cause (I-11). The
pre-commit hook cannot be bypassed and skips the gate only for commits with no build
inputs, so the implementation could not be committed on the branch. It is preserved whole,
with its MAP and PLAN edits and its snapshot-checked commit message, as
`docs/patches/M10.3-heading-scale.patch` (`git apply docs/patches/M10.3-heading-scale.patch`
from the repository root, then delete the patch and commit as
"M10.3: headings scaled by level in EditorStyler (ED-4, ED-9, E-3, E-8)"); it applied
cleanly forward and in reverse against this tree. The branch was cut from ef8b876, before
M10.2 landed on main, so ec97c43 is cherry-picked on it as 6bbe239 and `land.sh` will refuse
the branch for main having moved on build inputs; the patch applies to main at 500030e as
well since it touches only files at their M10.2 state.
Options: (1) a human applies the patch and commits when the machine is quiet (a run of the
gate at 09:10 today passed with the same assertion); (2) make the cold-launch assertion
load-aware or give it a budget of its own by an ADR, since a single cold sample on a busy
desktop cannot tell load from a regression (I-6, I-11), then re-run the task from the patch;
(3) drop the cold-sample assertion and gate PF-1 on the median only, by an ADR.
Recommendation: option 1 now to land the work, and option 2 as the fix for the gate.
Answer: None of the three. The gate is law (CLAUDE.md, Rules): when PF-1 fails, understand
why cold launch regressed and make it faster, instead of re-running the gate or parking the
work. Recorded as I-11 (bug), which the loop drains before M10.3; M10.3 then resumes from
docs/patches/M10.3-heading-scale.patch. (Answered by the human, 2026-09-15.)
