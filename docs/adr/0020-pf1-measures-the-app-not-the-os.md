# ADR-0020: PF-1 measures the app's own launch path; the test warms Writing Tools before the clock

Status: accepted, 2026-09-15 (Q5)

## Decision
`LaunchPerfTests` reads `NSWritingToolsCoordinator.isWritingToolsAvailable` once, on the main
thread, before the first launch clock starts. The PF-1 budget (300 ms cold, `PerfGate.Budget`)
is unchanged, and the gate keeps asserting the first (cold) launch in the process. The
warm-up lives in the test only; the app does not pre-load anything.

## Why
On macOS 27.0 (26A428) the first time any text field becomes first responder, AppKit
soft-links WritingToolsUI and 415 further images and registers their Objective-C classes on
the main thread: 170 to 250 ms, once per process, ungated by `allowsWritingTools` or
`writingToolsBehavior`, and not movable off the main thread because the runtime lock is held
for the whole registration (a background `dlopen` measured 406 ms cold). S-1 focuses the
search field at launch, so every cold launch pays it. On macOS 26.2 the same launch measured
207 to 211 ms in total; after the OS change it measured 444 to 600 ms with no source change.

I-11 profiled the rest and fixed three regressions of ours (the scanner's `FileManager`
listing, body reads starting with the titles publish, QuickLookUI via `NSDocumentController`):
median launch 210 to 85 ms, our cold main-thread work now ~50 ms. With the OS charge included
the cold floor is ~300 ms on an M1 Air, so PF-1 could not pass with margin whatever we do.

The gate exists to catch regressions in what the app controls. A fixed OS charge, identical
for every AppKit process, tells it nothing; raising the budget to cover it would hide a
regression the size of our whole current launch. Warming the OS path in the test keeps the
budget honest about our code (140 to 150 ms cold against 300).

## Consequences
The user's real first launch on macOS 27.0 is roughly 250 ms slower than PF-1 reports; the
spec says so under PF-1. If a later macOS removes the charge, the warm-up becomes a no-op and
can be deleted. If Apple gates it publicly, prefer the gate in the app and drop the warm-up.
