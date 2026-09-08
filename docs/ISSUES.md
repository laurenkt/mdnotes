# Issues

The queue for problems noticed outside the task at hand: flaky gates, bugs, debt. Protocol is
ADR-0016. The orchestrator drains open entries here before taking the next plan task, one
fresh subagent and one commit per entry, so nothing noticed is lost and nothing rots.

Rules:

- A task subagent that notices a problem outside its task fixes it in place only when it is
  in code the task already changes, is a few lines, and is covered by the commit's tests
  (named in the commit message). Otherwise it **records it here and does not fix it**, in the
  same commit as its task: `scripts/record-issue.sh <kind> <where> <text>`.
- Kinds: `flaky` (a gate that failed then passed; `check.sh` records these itself), `bug`
  (observed wrong behaviour against `SPEC.md`), `debt` (something that will bite: duplication,
  a missing test, a workaround).
- An entry must be one-commit sized. If the fixing subagent finds it is larger, it adds a task
  at the top of the current milestone in `PLAN.md` describing the work, marks the entry `[x]`
  with `-> M<n>.<k>`, and commits that.
- Fixing an entry means: reproduce (a test that fails), fix, mark `[x]`, commit as
  `I-<n>: <summary>`. A flaky entry is fixed by reducing variance (warm-up, iterations, isolating
  the subject), never by raising a budget (ADR-0007).
- Entries are never deleted or edited except to mark them done or redirect them to a plan task.

Format: `- [ ] I-<n> <kind> \`<where>\` (<date>): <what was seen, and how to reproduce if known>`

- [x] I-1 flaky `perf gates` (2026-09-07): the full gate failed once on the v2 spec commit and
      passed unchanged on rerun; the failing class was not captured. Add warm-up and enough
      iterations to every `*PerfTests` class that the median is stable across three consecutive
      runs on an idle machine, and make each perf test print its median so future flake entries
      carry the number.
- [x] I-2 flaky `FSEventsWatcherTests.testX1_ownerMayDropTheWatcherWhileItsHandlerRuns` (2026-09-07): crashed with signal 5 in about one of four runs of the debug suite (the unit and smoke step of scripts/check.sh) on 2026-09-07 and passed on rerun; not captured further. Reproduce by running the debug suite repeatedly.
- [x] I-3 flaky `BacklinksSmokeTests.testK6_PF6_showWithThousandsOfBacklinksBuildsOnlyTheCapAndStaysCheap` (2026-09-08): the debug suite failed once in the M6.9 pre-commit gate with 'show with 2,000 backlinks took 26.84 ms' against a 25 ms XCTAssertLessThan, on a machine busy with the human's own session, and the same tree had passed the full gate minutes earlier; a wall-clock assertion in a debug smoke test has no warm-up or median (ADR-0007 puts timing in PerfGate).
- [x] I-4 flaky `FSEventsWatcherTests.testX1_nonNotesAndSkippedPathsAreIgnored` (2026-09-08): failed once in the M6.9 pre-commit gate with XCTAssertEqual ('[sentinel.md]' is not equal to '[]') on a loaded machine; the same tree had passed the full gate minutes earlier. The sentinel's own change seems to land in the batch the test expects to be empty when FSEvents coalesces late; reproduce by running the debug suite under load.
- [x] I-5 debt `FSEventsWatcher.fold` (2026-09-08): a folder event's scan judges the disk as it is now, which can be ahead of the event stream: a note written after the event but before the callback runs is reported added by the scan and then modified by its own event in the next callback (seen in I-4 via the replayed root creation). Benign for the index, which treats the two alike, but the note is read twice and an open note is reloaded once more than needed (X-2). Reproduce with the I-4 test under load and startWatching's settle removed.
- [x] I-6 debt `scripts/check.sh EditorPerfTests PF-3 gate` (2026-09-08): Full gate for M7.1 (test-only change) failed PF-3 twice in a row at 8.0 to 8.5 ms against the 8 ms budget while load average was 19 to 26 (another session building I-5 concurrently); the retry-once rule cannot tell machine load from a regression, so a serialized or load-aware perf run may be needed. A standalone run at 14:13 with WindowServer, Claude and WhatsApp each at 50 to 66% CPU measured 13 to 18 ms; a third run with load average 7 to 12 passed PF-3 and failed PF-4 twice at 2.29 and 2.37 s against 2 s
- [ ] I-7 debt `Tests/MDNotesAppTests/WindowSnapshots.swift` (2026-09-08): V-1 snapshots capture the content view only, so a window whose content view has no opaque background (Settings) writes a transparent PNG; the dark one is white-on-clear and reads blank in a viewer. Fill windowBackgroundColor behind the view before caching so both appearances can be inspected as rendered.
