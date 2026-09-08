# MDNotes

Native macOS notes app in the Notational Velocity / nvALT tradition: one folder of `.md` files,
one search-or-create field, a list, an editor. The only thing that matters is that it feels
instant. Read `docs/SPEC.md` before writing code. The plan is `docs/PLAN.md`.

## Orchestration

The human runs `/loop /next-task` in one session. That session is the orchestrator: each tick
it runs `scripts/next-item.sh`, spawns a fresh subagent for exactly that item, verifies with
`scripts/verify-item.sh` (which tags milestones), logs cost to `docs/METRICS.md`, and never
implements anything itself (`.claude/commands/next-task.md`). Fresh context per item is
deliberate: the spec, the plan and git history are the memory, not the conversation. The
orchestrator holds no state, so it can be compacted or restarted at any time with nothing
lost. The loop ends when the plan is complete or every remaining task is blocked on
`docs/QUESTIONS.md`.

## Loop protocol (what a task session does)

You are working unattended through `docs/PLAN.md`:

1. Run `scripts/setup.sh` if `git config core.hooksPath` is not `.githooks` (first run only).
2. Take the task you were given, or if none, the first `[ ]` task in `docs/PLAN.md`. Do not
   skip ahead for a more interesting task. Do not bundle tasks.
3. Orient with `scripts/task-brief.sh <ID>`: the task, the spec bullets it cites, and the
   codebase map (`docs/MAP.md`). That is your reading list. Do not read `docs/SPEC.md` in
   full and do not survey the codebase; open the files the map points at. If the spec does
   not decide something you need, append an entry to `docs/QUESTIONS.md`, mark the task
   `[?]`, commit that, and take the next task that does not depend on it. Never guess at
   product behaviour.
4. Implement. Write the tests the task names, named after the spec IDs they cover
   (`testS3_titleMatchesSortFirst`). Iterate with `scripts/check.sh quick`.
5. If the task changes what a window looks like, render it per SPEC V-1 (the snapshot helper
   writes `build/snapshots/*.png`), open the PNGs with the Read tool, and compare them with
   W-6, PR-1 and the design canvas linked in ADR-0013. Fix what looks wrong before committing
   and say in the commit message what you checked.
6. Mark the task `[x]` in `docs/PLAN.md` in the same commit. If you added, removed or moved
   a source or test file, update its line in `docs/MAP.md` in the same commit; the map is
   how the next agent avoids re-exploring the codebase.
7. Commit: `git commit -m "M2.4: search field drives list reload (S-1, S-5, PF-2)"`. The
   pre-commit hook runs `scripts/check.sh full`; a red gate means the task is not done.
   Fix forward. Never bypass the hook.
8. Stop after one task. The orchestrator tags milestones (`m<N>`) and starts the next task;
   the human reviews the tags at their leisure. Do not stop the loop at a milestone.

If a task turns out to be too large for one commit, split it in `docs/PLAN.md` (sub-tasks
M2.4a, M2.4b) in the commit that lands the first part.

## Issues (what you notice but were not asked to fix)

When you see something wrong outside your task, whether a bug against the spec, a flaky test,
or debt that will bite, decide between two things and never a third:

- **Fix it in place** if it is in code this task already changes, the fix is a few lines, and
  this commit's tests exercise it. Say so in the commit message ("also fixes: ...").
- **Record it** with `scripts/record-issue.sh <bug|debt> "<where>" "<what you saw>"` in the
  same commit as your task if it needs a file you were not going to touch, needs its own
  test to reproduce, or changes behaviour beyond your task's spec IDs.

Never leave it in a comment, and never widen the task to chase it. The orchestrator drains
the queue before the next plan task (ADR-0016). `scripts/check.sh` records perf
flakes there itself: a gate that fails once and passes on retry lets your commit through and
adds a `flaky` entry; a gate that fails twice is a regression and blocks you.

## Commands

```
scripts/check.sh quick    format lint, build, unit + smoke tests (debug). Use while iterating.
scripts/check.sh full     the above plus perf gates in release. Runs on every commit.
scripts/bundle.sh         builds build/MDNotes.app from a release build.
swift run MDNotes         runs the app unbundled.
xcrun swift-format format --in-place <file>    (a PostToolUse hook does this on every edit)
```

## Rules

- Pure SwiftPM. Never create, open, or reference an Xcode project. `xcodebuild` is blocked.
- AppKit in code only. No SwiftUI, storyboards, or xibs.
- `MDNotesCore` must not import AppKit. `MDNotes` contains only `main.swift`.
- Swift 6 strict concurrency, warnings are errors, `NeverForceUnwrap` is on. Do not add
  `unsafeFlags`, `@unchecked Sendable`, or `nonisolated(unsafe)` without an ADR.
- No third-party dependencies without an ADR. Foundation, AppKit, Carbon (for the hotkey)
  and XCTest are the whole world.
- File I/O and indexing never run on the main thread (PF-6).
- Perf budgets in `PerfGate.Budget` are law. If a gate fails, fix the code. Raising a budget
  needs an ADR and the human.
- The real library at `~/Documents/MDnotes` is read-only to you (hooks enforce it). Tests use
  `SyntheticLibrary` in a temp directory or a copy.
- History is append-only: no amend, rebase, reset, or hook bypass. Fix with a new commit.
- One linear `main`. No branches, merges, or worktrees; decline worktree isolation if offered.
- Never end a turn with a dirty working tree (a Stop hook enforces it). Commit or record a
  question and commit that.
- Product behaviour lives in `docs/SPEC.md` and changes only through an ADR in `docs/adr/`.
  Do not "improve" the spec while implementing.
- Only semantic `NSColor`s and system fonts (E-8, W-6). No literal colours, no custom drawing
  of standard controls.
- Shell heredocs that contain guarded phrases (hook bypass flags, Xcode tool names) trip the
  Bash guard. Write such text with the Write or Edit tools instead.

## Layout

```
Sources/MDNotesCore/         scanner, store, indexes, search, markdown scanner. Foundation only.
Sources/MDNotesApp/          AppDelegate, window, controllers, views. Testable without launching.
Sources/MDNotes/main.swift   the executable entry point. Nothing else goes here.
Sources/MDNotesTestSupport/  SyntheticLibrary, PerfGate.
Tests/MDNotesCoreTests/      unit tests and *PerfTests for the core.
Tests/MDNotesAppTests/       headless smoke tests and *PerfTests for the app layer.
scripts/                     check.sh, bundle.sh, setup.sh, record-issue.sh,
                             next-item.sh, verify-item.sh, task-brief.sh, log-metric.sh
.githooks/pre-commit         runs scripts/check.sh full
.claude/                     settings.json (permissions + hooks), hooks/, commands/next-task.md
docs/                        SPEC.md, PLAN.md, ISSUES.md, QUESTIONS.md, MAP.md, METRICS.md, adr/
```
