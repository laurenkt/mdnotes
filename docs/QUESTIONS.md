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

## Q5: PF-1's cold launch pays ~250 ms of macOS loading Writing Tools at the search field's first focus; what should the cold gate measure?   (task: I-11, 2026-09-15)
Context: I-11 asked for the cold launch to be profiled and made faster until PF-1 passes with margin.
Profiled with Time Profiler on the release test binary (macOS 27.0 26A428, M1 Air). Three
regressions of ours were found and fixed on the branch: `LibraryScanner` listed 20k notes through
`FileManager.contentsOfDirectory` and `URL.resourceValues` (seven times the cost of the kernel's own
`getattrlistbulk` listing, every object bridged through the Objective-C runtime whose lock the main
thread holds while a cold launch loads frameworks); `LibraryController.start` began the body reads
and download probes together with the titles publish, so the list waited on them; and
`NSWindowController.showWindow` routed through `NSDocumentController`, soft-linking QuickLookUI
(50 ms). Median launch went from 210 to 85 ms and cold from 450-600 to 300-410 ms.
What remains is the OS. `NSWindow.makeKeyAndOrderFront` makes the search field first responder
(S-1, `initialFirstResponder`); `NSTextField.selectText:` sets the field editor's selection;
`-[NSTextInputContext invalidateCharacterCoordinates]` asks `+[NSCampoLightweightUIController
isEligible]`, which soft-links WritingToolsUI, and with it 415 images (WebKit, MapKit, PDFKit,
Photos, the SwiftUI overlays): 170-250 ms of objc class and category registration on the main
thread, once per process, 168 of the 181 samples inside the delegate. Nothing public gates it:
`allowsWritingTools = false` on the field and `writingToolsBehavior = .none` on the field editor
(verified set) change nothing, and the closure is not SwiftUI's (`Bundle.load` of SwiftUI first
changed nothing). The other 85-100 ms after the delegate returns are AppKit's
`NSIATextInputActionsContext updateInputMode` (TSM input-source languages through ICU) and the first
`CATransaction` commit, run-loop blocks that drain before our publish; most of that overlaps the
scan. Our own cold main-thread work is now ~50 ms (menu 12, order-front residue ~30, reload and
first-page layout 10). Measured alternatives: `NSWritingToolsCoordinator.isWritingToolsAvailable`
called before the clock loads the same closure (247 ms) and leaves cold launch at 140-150 ms with
the list on screen; it is `@MainActor` in the Swift interface, so it cannot run off the main
thread. A `dlopen` of WritingToolsUI on a background thread with the field focused only when the
titles snapshot lands measured 406 ms cold: the objc runtime lock is held for the whole
registration and the main thread stalls on it in `NSMenu`/`NSWindow` regardless. So the 250 ms
cannot be avoided, overlapped or moved off the main thread by anything short of not focusing a
text field, which S-1 forbids and which only defers the cost to the first keystroke. With it,
cold launch has a floor of ~300 ms on this machine and PF-1's 300 ms cannot be met with margin.
Options: (1) an ADR that PF-1 measures the app's own launch path: `LaunchPerfTests` reads
`NSWritingToolsCoordinator.isWritingToolsAvailable` once before the first clock starts (public
API, main thread, in the test only), documenting the OS charge it excludes; the gate then measures
140-150 ms cold against 300 with margin, and the real first launch pays the OS its 250 ms as
every AppKit app on this macOS does. (2) an ADR raising the cold budget to cover the OS (500 ms
cold, 300 median), keeping the gate honest about the user's wait but blind to a 150 ms regression
of ours. (3) an ADR changing S-1 so the field is focused on the first keystroke instead of at
launch; the cost moves to the first keystroke and PF-1 passes at ~150 ms, but the app would drop
or delay what the user types in that first quarter second. (4) leave I-11 open and PF-1 failing
until an OS update changes the charge.
Recommendation: (1). The gate exists to catch regressions in what the app controls; a fixed OS
charge at first text focus, the same for every process, tells it nothing, and (2) would hide a
regression of our whole current budget. The branch's fixes stand on their own (median 210 -> 85 ms)
but the pre-commit gate refused them with PF-1 cold at 334 and 311 ms, so they are parked whole,
with their MAP edits, as `docs/patches/I-11-cold-launch.patch` (applies cleanly to main at
0139109; `git apply` it, delete it, and commit as the I-11 fix once the ADR has landed); I-11 is
marked `[?]` and PF-1's cold assertion stays as it is until then.
Answer: Option 1 (the human, 2026-09-15). ADR-0020 and SPEC PF-1a record it. I-11 is reopened:
apply docs/patches/I-11-cold-launch.patch, add the one-line warm-up to LaunchPerfTests before
the first clock, delete the patch, and commit as the I-11 fix. Budgets untouched.

## Q6: Which link form names a root-level note whose title other notes share?   (task: I-13, 2026-09-22)
Context: R-4's Copy Link writes `[[Title]]`, or `[[relative/path]]` without `.md` when the title
is ambiguous (K-2). For a note at the root, `foo.md`, the relative path without `.md` is `foo`,
the bare title itself. K-1 says a target is "a title or a relative path without extension" and
K-2 says a bare ambiguous title resolves to the most recently modified candidate, but neither
says which reading wins when the text is both, so with `foo.md` and `daily/foo.md` in the
library the spec gives no link that always names the root `foo`. `LinkIndex.resolve` reads a
target without `/` as a title, so Copy Link on the root `foo` copies `[[foo]]`, which lands on
`daily/foo` whenever that one was modified more recently, and flips as either is edited. The
same gap affects anyone typing a link to the root note by hand, and backlinks (K-6) follow
the same resolution.
Options: (1) a bare target that is exactly a root note's path names that note: `[[foo]]` goes
to the root `foo.md` whenever one exists, and only when none does is it an ambiguous title
(most recent candidate, styled ambiguous). No new syntax and Copy Link needs no change; it
reads K-2's "must be given as a relative path" literally, since `foo` is the root note's
relative path. Cost: an existing bare `[[foo]]` that today reaches the newer `daily/foo`
starts reaching the root note, and a root note shadows same-titled notes elsewhere, which
then need their path (as K-2 already demands). (2) a root-anchored form, `[[/foo]]`: a
leading `/` means a path from the root (K-1 amended), the resolver strips it, and Copy Link
writes it for an ambiguous root note. Additive, no existing link changes meaning, but it is a
new syntax other Markdown tools may not resolve, and hand-typed `[[foo]]` stays ambiguous.
(3) allow the extension, `[[foo.md]]`: a target ending in `.md` is a path with extension
(K-1 amended), and Copy Link writes it for an ambiguous root note. Additive and reads
naturally, but it breaks K-1's "without extension" uniformity and a title ending in `.md`
becomes unreachable by title. (4) accept the gap: amend R-4 to say an ambiguous root note's
Copy Link is `[[Title]]` and may name another note. No code, but the copied link can be wrong.
Recommendation: option 1. It needs no syntax, makes the link stable instead of following
modification times, and matches what K-2 already asks of the other candidates.
Answer: Option 1 (2026-09-23). A bare target that is exactly a root note's relative path names
  that note: `[[foo]]` resolves to the root `foo.md` whenever one exists, and only when none
  does is it an ambiguous title (most recently modified candidate, styled ambiguous). Copy
  Link on the root note keeps writing `[[foo]]`; same-titled notes elsewhere need their path.
  Backlinks (K-6) follow. Recorded in ADR-0023; K-2 and R-4 amended; task M10.28.
