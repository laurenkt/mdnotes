# Plan

Ordered task list for the autonomous loop. Protocol is in `CLAUDE.md`. Each task is one commit.
A task is done when its listed tests exist and pass under `scripts/check.sh full`.

Legend: `[ ]` todo, `[x]` done, `[?]` blocked (see `QUESTIONS.md`). Spec IDs refer to `SPEC.md`.

## M0: Skeleton

- [x] M0.1 Package manifest with Core / App / executable / TestSupport / test targets. (P-3, P-5)
- [x] M0.2 `scripts/check.sh`, `scripts/bundle.sh`, `scripts/setup.sh`, git pre-commit hook,
      Claude Code hooks and settings.
- [x] M0.3 Empty main window launches; headless smoke test constructs it.
- [x] M0.4 Synthetic library generator and `PerfGate` helper in TestSupport.
- [x] M0.5 SPEC, PLAN, ADRs, CLAUDE.md, QUESTIONS.md.
- [x] M0.6 `scripts/bundle.sh` produces a launchable `build/MDNotes.app`; add a test that the
      Info.plist it generates is valid (`plutil -lint`).

## M1: Core index and search (no UI)

- [x] M1.1 `LibraryScanner`: recursive walk of a root, applying L-2, L-3, L-4, L-5, L-6. Returns
      `[NoteID]` plus modification dates. Tests: synthetic library counts, skip rules, nested paths.
- [x] M1.2 `NoteStore`: read a note's body as UTF-8 with L-7 and L-8 handling (dataless files
      via `URLResourceValues.ubiquitousItemDownloadingStatus`; invalid UTF-8 flagged). Tests
      with a fabricated non-UTF-8 file.
- [x] M1.3 `SearchIndex`: in-memory, immutable snapshot type + a builder. Holds lowercase title and
      body per note. `query(_:)` implements S-2, S-3, S-4. Tests: word order, case, title-first
      ordering, empty query, tag words.
- [x] M1.4 `IndexPerfTests`: PF-4 (full build of 20k under 2 s) and PF-2 at the core level
      (query over 20k under 4 ms, leaving 12 ms for the table). PF-5 memory via `task_info`
      resident size.
- [x] M1.5 Incremental update API on the index: `applying(changes:)` for added / modified /
      removed IDs, building a new snapshot without a full rescan. Tests: each change kind.
- [x] M1.6 `AtomicWriter`: E-5 semantics. Test: interrupted write leaves the old file intact.
- [x] M1.7 `WordSplitter` and the case-folding used everywhere, shared with link/tag parsing.

## M2: Window, list, editor, create, autosave

- [x] M2.1 Layout: search field, `NSTableView` list, `NSTextView` editor in an `NSSplitView`,
      backlinks strip placeholder. Persisted frame and split (W-1, W-2). Smoke test: views exist
      and are laid out at a given size.
- [x] M2.2 `LibraryController`: owns the scanner, store, and index; publishes snapshots to the
      main thread (PF-6). Progressive population during initial scan (PF-7). Smoke test with
      synthetic library: list count reaches N.
- [x] M2.3 List data source and row view (S-6). Selection loads the editor (S-8). Smoke test:
      select row, editor text equals file body.
- [x] M2.4 Search field wiring: every keystroke re-queries and reloads the table (S-1, S-5).
      `ListPerfTests`: PF-2 keystroke-to-reload measured around the real controller path with
      20k notes.
- [ ] M2.5 Keyboard flow S-7 and S-8. Smoke test drives `keyDown` / responder chain and asserts
      first responder.
- [ ] M2.6 Create on Enter: C-1 to C-4 including nested `/` paths and illegal characters. Smoke
      tests for each rule.
- [ ] M2.7 Autosave E-4, E-5, E-6 with a testable clock. Smoke test: edit, advance clock, file
      updated; switch note, file updated immediately.
- [ ] M2.8 Undo per note (E-7). Font preference (E-8) read from `UserDefaults`.
- [ ] M2.9 Launch perf: `LaunchPerfTests` measuring PF-1 (app delegate finish-launching to list
      populated with first page and window key) against the 20k library.

## M3: Watcher, external edits, rename, delete

- [ ] M3.1 `FSEventsWatcher` wrapping `FSEventStreamCreate` with file-level events, coalesced,
      mapped to added / modified / removed `NoteID`s (X-1). Tests using a temp library and real
      file operations, with timeouts.
- [ ] M3.2 Own-write suppression (E-6): writer records (path, mtime) and watcher drops matching
      events. Test: autosave does not trigger a reload.
- [ ] M3.3 External edit rules X-2, X-3, X-4. Smoke tests for each, including the dirty-editor
      case where the editor's text overwrites disk at next autosave.
- [ ] M3.4 Delete D-1, D-2 via `NSWorkspace.shared.recycle`. Smoke test asserts the file is gone
      from the library and the list updates before the watcher fires.
- [ ] M3.5 Inline rename R-1, R-2 without link rewriting. Smoke tests: rename, collision, illegal.
- [ ] M3.6 Preferences window: library folder chooser (PR-1 part). Changing the folder tears down
      and rebuilds the library controller.

## M4: Links, tags, highlighting

- [ ] M4.1 `MarkdownScanner`: single pass producing ranges for headings, wikilinks (K-1), tags
      (T-1), inline and fenced code. Paragraph-scoped API: given a text and an edited range,
      return the paragraph range to re-scan. Tests: every token kind, code-span exclusion,
      trailing punctuation, embeds.
- [ ] M4.2 `LinkIndex` and `TagIndex` (K-5, T-2), built alongside the search index and updated
      incrementally. Resolution K-2 including ambiguity. Tests: unique, ambiguous, path-qualified.
- [ ] M4.3 Editor styling E-2, E-3 via `NSTextStorage` delegate on the edited paragraphs only.
      `EditorPerfTests`: PF-3 keystroke-to-redraw on a 1 MB note.
- [ ] M4.4 Link opening K-3: Cmd-click and Cmd-Enter, create-if-missing. Smoke tests.
- [ ] M4.5 `[[` completion popover K-4. Smoke test drives typing and asserts inserted text.
- [ ] M4.6 `#` completion popover T-3 and click-to-search T-4.
- [ ] M4.7 Backlinks strip K-6 with collapse persistence.
- [ ] M4.8 Rename rewrites links R-3. Test: three linking notes rewritten atomically, log line
      emitted, unrelated notes untouched byte-for-byte.

## M5: Images, hotkey, preferences, polish

- [ ] M5.1 Image paste and drop I-1, I-2. Tests with a generated PNG.
- [ ] M5.2 Global hotkey W-3 with Carbon `RegisterEventHotKey`; recorder control in Preferences.
- [ ] M5.3 Preferences window complete (PR-1): font, hotkey.
- [ ] M5.4 Menu bar: standard app / edit / view menus, Cmd-L, Cmd-R, Cmd-Delete, Cmd-Shift-B
      toggle backlinks. W-4 quit-on-close.
- [ ] M5.5 App icon in `Resources/AppIcon.icns`, wired by `bundle.sh`.
- [ ] M5.6 Manual acceptance pass against the checklist in `docs/ACCEPTANCE.md` (write it in this
      task: one line per spec ID, checked by hand against a copy of the real library). Any
      discrepancy becomes a new task above this line.
- [ ] M5.7 Tag `v0.1.0`.
