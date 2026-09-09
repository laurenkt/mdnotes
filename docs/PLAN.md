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
- [x] M2.5 Keyboard flow S-7 and S-8. Smoke test drives `keyDown` / responder chain and asserts
      first responder.
- [x] M2.6a Create on Enter: C-1 to C-4 including nested `/` paths on disk and illegal
      characters. Smoke tests for each rule. (Split from M2.6: the list and selection after a
      nested-path create or open is M2.6b.)
- [x] M2.6b Nested-path create/open in the list (C-4, S-2, C-1, ADR-0008): a query word
      containing `/` also matches the note's relative path without `.md`, counting as a title
      match for S-3, so after Enter on `daily/foo` the kept query lists and selects the new
      note. Words without `/` are unchanged. Tests: S-2 path-form match and non-match, S-3
      ordering, C-4 selection after a nested create and after C-1 opening by path; PF-2 holds.
- [x] M2.7 Autosave E-4, E-5, E-6 with a testable clock. Smoke test: edit, advance clock, file
      updated; switch note, file updated immediately.
- [x] M2.8 Undo per note (E-7). Font preference (E-8) read from `UserDefaults`.
- [x] M2.9 Launch perf: `LaunchPerfTests` measuring PF-1 (app delegate finish-launching to list
      populated with first page and window key) against the 20k library.

## M3: Watcher, external edits, rename, delete

- [x] M3.1 `FSEventsWatcher` wrapping `FSEventStreamCreate` with file-level events, coalesced,
      mapped to added / modified / removed `NoteID`s (X-1). Tests using a temp library and real
      file operations, with timeouts.
- [x] M3.2 Own-write suppression (E-6): writer records (path, mtime) and watcher drops matching
      events. Test: autosave does not trigger a reload.
- [x] M3.3 External edit rules X-2, X-3, X-4. Smoke tests for each, including the dirty-editor
      case where the editor's text overwrites disk at next autosave.
- [x] M3.4 Delete D-1, D-2 via `NSWorkspace.shared.recycle`. Smoke test asserts the file is gone
      from the library and the list updates before the watcher fires.
- [x] M3.5 Inline rename R-1, R-2 without link rewriting. Smoke tests: rename, collision, illegal.
- [x] M3.6 Preferences window: library folder chooser (PR-1 part). Changing the folder tears down
      and rebuilds the library controller.

## M4: Links, tags, highlighting

- [x] M4.1 `MarkdownScanner`: single pass producing ranges for headings, wikilinks (K-1), tags
      (T-1), inline and fenced code. Paragraph-scoped API: given a text and an edited range,
      return the paragraph range to re-scan. Tests: every token kind, code-span exclusion,
      trailing punctuation, embeds.
- [x] M4.2 `LinkIndex` and `TagIndex` (K-5, T-2), built alongside the search index and updated
      incrementally. Resolution K-2 including ambiguity. Tests: unique, ambiguous, path-qualified.
- [x] M4.3 Editor styling E-2, E-3 via `NSTextStorage` delegate on the edited paragraphs only.
      `EditorPerfTests`: PF-3 keystroke-to-redraw on a 1 MB note.
- [x] M4.4 Link opening K-3: Cmd-click and Cmd-Enter, create-if-missing. Smoke tests.
- [x] M4.5 `[[` completion popover K-4. Smoke test drives typing and asserts inserted text.
- [x] M4.6 `#` completion popover T-3 and click-to-search T-4.
- [x] M4.7 Backlinks strip K-6 with collapse persistence.
- [x] M4.8 Rename rewrites links R-3. Test: three linking notes rewritten atomically, log line
      emitted, unrelated notes untouched byte-for-byte.

## M5: Images, hotkey, preferences, polish

- [x] M5.1 Image paste and drop I-1, I-2. Tests with a generated PNG.
- [x] M5.2 Global hotkey W-3 with Carbon `RegisterEventHotKey`; recorder control in Preferences.
- [x] M5.3 Preferences window complete (PR-1): font, hotkey.
- [x] M5.4 Menu bar: standard app / edit / view menus, Cmd-L, Cmd-R, Cmd-Delete, Cmd-Shift-B
      toggle backlinks. W-4 quit-on-close.
- [x] M5.5 App icon in `Resources/AppIcon.icns`, wired by `bundle.sh`.
- [x] M5.6a Backlinks strip must not stall the main thread (K-6, PF-6): opening a note with
      1,500 backlinks freezes the app for 5 to 40 s while `BacklinksStrip.show` builds an
      `NSButton` per backlink inside an `NSStackView`. Build only as many title buttons as
      the bar can show (a small fixed cap, say 20, with the count in the summary), build none
      while collapsed, and keep `show` cheap for any count. Test: `BacklinksSmokeTests` with
      2,000 backlinks completes `show` within a few ms and lists at most the cap.
- [x] M5.6b Image paste is dead from the keyboard and the menu (I-1): with only an image on
      the clipboard `NSTextView` disables Paste, so `EditorTextView.paste(_:)` is never
      called. Override `validateUserInterfaceItem` (or `readablePasteboardTypes`) so Paste is
      enabled when `ImagePasteboard.hasImage` and the note is writable. Test:
      `ImageInsertSmokeTests` validates the Paste item against an image-only pasteboard and
      drives `paste` through `NSApp.sendAction`.
- [x] M5.6c Ambiguous wikilinks are styled like unique ones (K-2): `EditorStyler` has one
      wikilink style. Give it the snapshot's `LinkIndex` (through `EditorController`) and an
      `ambiguous` `TokenStyle` (for instance the link colour with an underline or a warning
      tint), re-styling links when a snapshot changes resolution. Test:
      `EditorStylingSmokeTests` with two notes titled `foo` asserts the token attribute.
- [x] M5.6d Read-only notes show no notice (L-8, L-7): an undecodable or not-yet-downloaded
      note is shown read-only with nothing saying why. Show a one-line notice above the editor
      (reuse the inline message label or a dedicated bar) while such a body is loaded, cleared
      on the next load. Test: `ExternalEditSmokeTests` or a new `ReadOnlyNoticeSmokeTests`
      with a fabricated non-UTF-8 file.
- [x] M5.6e Window tabbing leaks into the View menu (W-1): AppKit adds Show Tab Bar / Show All
      Tabs because the main window allows tabbing. Set `window.tabbingMode = .disallowed` in
      `MainWindowController`. Test: `MenuSmokeTests` asserts the View menu holds only ours.
- [x] M5.6 Manual acceptance pass against the checklist in `docs/ACCEPTANCE.md` (write it in this
      task: one line per spec ID, checked by hand against a copy of the real library). Any
      discrepancy becomes a new task above this line.
- [x] M5.7 Tag `v0.1.0`.

## M6: iCloud, dates, fonts, hotkey (v2 fixes)

- [x] M6.1 `DownloadRequester` in Core: given the scanner's note list and a `NoteStore`, requests
      download for every dataless note off the main thread, at most once per note per 60 s, and
      repeats on re-eviction (L-9). Injected clock and injected request function for tests.
      Tests: first pass requests all dataless, second pass within 60 s requests none, a note
      that flips readable then dataless again is requested again.
- [x] M6.2 Wire `DownloadRequester` into `LibraryController`: after the initial scan, after each
      full rescan, and on every watcher batch. Smoke test with the availability probe: dataless
      notes get requested without any note being opened.
- [x] M6.3 Eviction bar (L-10): view under the search field, count text, free-space suffix under
      2 GB, `Open Storage Settings` button, not shown during the first scan, hidden within 2 s
      of the last note becoming readable. Free space via `volumeAvailableCapacityForImportantUsage`.
      Smoke tests: shown/hidden transitions, text for 1 and N notes, button present only under
      2 GB. Snapshot per V-1.
- [x] M6.4 `RelativeDateText` in App (S-9): Today/Yesterday with time, weekday within six days,
      `d MMM` this year, `d MMM yyyy` otherwise, locale-aware, injected `now`. Tests for each
      band and for the year boundary.
- [x] M6.5 Row layout gives the date its intrinsic width and truncates the title (S-10).
      Refresh relative words on day change (`NSCalendarDayChanged`) and on window becoming
      key. Smoke test: a 60-character title and `Yesterday 09:10` in a 300 pt row leaves the
      date untruncated. Snapshot per V-1.
- [x] M6.6 Fonts (E-8, E-2): remove `EditorFontFamily` and delete the stored key on launch;
      prose `systemFont`, code tokens `monospacedSystemFont`; View menu Bigger/Smaller/Actual
      Size with Cmd-plus/minus/0, 9 to 36 pt, persisted in `EditorFontSize`. Remove the font
      controls from Settings. Tests: styler assigns the mono font to inline and fenced code
      only; zoom actions clamp and persist; stale family key is gone after launch.
- [x] M6.7 Window level and behaviour (W-5): `.floating`, `moveToActiveSpace`; completion popup
      and Settings above it. Smoke tests assert level and collection behaviour; completion
      popup window level is greater than the main window's.
- [x] M6.8 Hotkey toggle and close-hides (W-3, W-4): visible-and-active hides, otherwise shows
      and focuses search; Cmd-W and the close button hide; Dock click reopens
      (`applicationShouldHandleReopen`); `applicationShouldTerminateAfterLastWindowClosed`
      false. Smoke tests drive `fire()` twice and assert visibility, then reopen.
- [x] M6.9 Manual acceptance pass for M6 against `docs/ACCEPTANCE.md` (append a v2 section, one
      line per changed spec ID); discrepancies become tasks above this line.

## M7: Window and Settings redesign

- [x] M7.1 Snapshot helper in TestSupport or AppTests (V-1): render a window's content view at
      2x in light and dark to `build/snapshots/<name>-<appearance>.png`. Test: writes two
      files for the main window.
- [x] M7.2 Main window layout per W-6: title bar with title, search field inset 8/10 pt on a
      `windowBackgroundColor` strip, hairline `separatorColor` beneath, list, split, editor,
      backlinks. Remove any non-semantic colours. Smoke test asserts frames and insets;
      snapshot inspected against direction B on the canvas.
- [x] M7.3 Snippets strip markdown (S-6): `BodySnippet` drops heading markers, wikilink
      brackets and labels' pipes, embed syntax entirely, code fences, emphasis markers. Tests
      for each construct and for PF-2 unaffected (snippet work stays in the index build).
- [x] M7.4 Settings window per PR-1: title `Settings`, `Settings…` Cmd-comma, fixed size,
      `NSGridView` with right-aligned captions, Notes folder row, Global shortcut row, 20 pt
      margins. Smoke test asserts style mask, title, grid rows. Snapshot inspected.
- [x] M7.5 Menu audit: View menu holds Bigger/Smaller/Actual Size and Backlinks; Window menu
      standard; File menu gains `New from Template` placeholder submenu (filled in M9). Smoke
      test on menu titles and key equivalents.
- [x] M7.6 Manual acceptance pass for M7; discrepancies become tasks above this line.

## M8: Thumbnails

- [x] M8.1 `ThumbnailCache` in App (PF-8): background queue, two concurrent jobs,
      `CGImageSource` downsampling to a requested pixel size, LRU bounded at 50 MB, keyed by
      path and mtime, completion on main. Tests: hit, miss, eviction on size, invalidation on
      mtime change, never blocks the calling thread.
- [x] M8.2 First-image resolution: given a body, find the first `![[target]]` and resolve it
      to an image file via the link resolver (K-1, S-11). Stored on the index snapshot as an
      optional path. Tests: none, one, first-of-several, unresolvable.
- [x] M8.3 Row thumbnails (S-11): 34 pt square at the row's right, drawn only when cached,
      requested on row display, click selects the note. `ListPerfTests` re-run with 10 % of
      synthetic notes embedding a generated PNG (extend `SyntheticLibrary`). Snapshot inspected.
- [x] M8.4 Editor attachment plumbing (E-9, ADR-0012): one accessor that returns the view's
      text without attachment characters, used by save, copy, search, link and tag parsing and
      styler ranges. Tests: round trip with attachments present leaves the file byte-identical.
- [x] M8.5 Inline thumbnails (E-9): attachment on the line below a resolving embed, 240 by 160
      max, click opens in default app, removed when the embed stops resolving, loaded via
      `ThumbnailCache`. `EditorPerfTests` re-run on a 1 MB note containing 50 embeds. Snapshot
      inspected.
- [x] M8.6 Manual acceptance pass for M8; discrepancies become tasks above this line.

## M9: Templates

- [x] M9.1 `TemplateParser` in Core (TP-2, TP-3): header block, `path`, tokens `{{date:FORMAT}}`
      (Unicode patterns via `DateFormatter`), `{{title}}`, `{{cursor}}`; unknown tokens left
      literal. Tests for each token, missing header, missing path, cursor removal and offset.
- [x] M9.2 `TemplateStore` (TP-1, TP-7): lists `templates/*.md` by name, updated by the watcher.
      Tests: add, remove, rename a template file.
- [x] M9.3 Instantiation (TP-4): expand path, apply C-3 checks, open-if-exists, else create with
      folders and expanded body, caret at cursor. Tests: existing path opens without writing,
      new path creates, illegal path refused.
- [x] M9.4 Template mode in the search field (TP-5): `@` prefix, list shows templates with
      expanded path as snippet, Enter with remaining words as title, inline prompt when title
      is required, `@` alone lists all. Smoke tests for each rule and for Escape.
- [x] M9.5 `File > New from Template` submenu (TP-6) built from `TemplateStore`, prompting
      inline when a title is needed. Smoke test on menu contents and action.
- [ ] M9.6 Manual acceptance pass for M9 and the whole of v2 against `docs/ACCEPTANCE.md`;
      discrepancies become tasks above this line.
- [ ] M9.7 Tag `v0.2.0`.

## M10: Halfway editor: in-place markdown styling, rich paste, rules and banding

- [ ] M10.1 `MarkdownScanner` grows to the full block and inline set (ED-1): emphasis (`**`, `__`,
      `*`, `_` at word boundaries, `~~`), standard links `[t](u)`, images `![a](u)`,
      autolinks `<u>` and bare http(s) URLs, list items (bullet, ordered, task, nesting by
      two spaces), blockquote prefixes, pipe-table rows and separator rows, thematic breaks
      per ED-8, setext headings per ED-9. Tokens carry marker ranges separately from content
      ranges. Tests: one test per construct, code-span and fenced-block exclusion, word-boundary
      underscore, nesting depth, blank-line-before rule, setext under text.
- [ ] M10.2 Marker dimming and emphasis traits in `EditorStyler` (ED-2, ED-3): markers in tertiary
      label colour; bold, italic and strikethrough traits on content; nothing inside code.
      Tests: attributes per token; markers and content styled separately.
- [ ] M10.3 Heading scale (ED-4): 1.4 / 1.25 / 1.1 / 1.0 times the body size, bold; `#` and setext
      underline dimmed; scales with Cmd-plus. Restyle stays paragraph-scoped (E-3). Tests:
      font size per level; a heading edit relays out only its paragraph.
- [ ] M10.4 Lists (ED-5): hanging indent via paragraph style so wrapped lines align under the item
      text, two spaces per nesting level, markers dimmed; ordered markers too. Tests: head
      indent per level; wrapped line x-origin equals text start.
- [ ] M10.5 Task items (ED-6): `[ ]` / `[x]` set in the monospaced font at body size; done items in
      secondary colour; a plain click on the box toggles space and x as one undoable edit that
      autosaves. Tests: equal advance widths; click toggles; undo restores; file updated.
- [ ] M10.6 Blockquotes and tables (ED-7): blockquote paragraphs hanging-indented with `>` dimmed,
      nested `>` nests; pipe-table lines in the monospaced font, separator row dimmed. Tests:
      attributes and indents.
- [ ] M10.7 Horizontal rule extension (ED-8): a custom `NSLayoutManager` draws faded hyphens from the
      end of the typed rule to the trailing edge, unselectable, visible rect only. Tests: rule
      token ranges; drawn extension excluded from selection and copy; snapshot per V-1.
- [ ] M10.8 Section banding (ED-10): the layout manager fills alternate sections between rules with
      a subtle system fill across the full editor width, the rule line first in its band,
      visible rect only, recomputed from the scanner's rule list. Tests: band ranges for
      0, 1, 3 rules and for a rule at document start; snapshot per V-1 in light and dark.
- [ ] M10.9 Link state (ED-11): missing wikilink targets get a dotted underline and the tooltip
      "Cmd-click to create"; existing in link colour; ambiguous unchanged. Standard links,
      autolinks and bare URLs styled as links. Tests: attributes per state; restyle when a
      target appears or disappears.
- [ ] M10.10 Cmd-hover and browser opening (ED-12, K-3): holding Cmd over any link shows the
      pointing-hand cursor and a solid underline; Cmd-click or Cmd-Enter on a standard link or
      URL opens it with `NSWorkspace`. Tests: cursor and underline after simulated
      flagsChanged over a link; open action receives the URL.
- [ ] M10.11 `HTMLToMarkdown` in Core (ED-13): walks tidy-parsed HTML and emits headings, emphasis,
      links, lists with nesting, task items, code, blockquotes, pipe tables, remote images,
      paragraphs and line breaks; everything else as plain text. Fixtures: Mail, Safari,
      Notes, Google Docs exports. Tests: one per fixture, byte-exact expected markdown.
- [ ] M10.12 `RTFToMarkdown` fallback (ED-13): attributed-string traits, links and list markers to
      markdown when no HTML is present. Fixture: Pages and TextEdit RTF.
- [ ] M10.13 Rich paste wiring (ED-14): `EditorTextView` converts HTML, else RTF, else plain;
      Cmd-Shift-V (Paste and Match Style) pastes plain; image data still goes to `i/` (I-1).
      `PastePerfTests`: PF-9, 200 KB of HTML under 100 ms. Smoke tests per pasteboard type.
- [ ] M10.14 `EditorPerfTests` extended (PF-3): the 1 MB note now contains every construct, with
      banding and rule extensions drawn; keystroke-to-redraw stays under 8 ms.
- [ ] M10.15 Manual acceptance pass for M10 against `docs/ACCEPTANCE.md` (one line per ED bullet);
      discrepancies become tasks above this line.
- [ ] M10.16 Tag `v0.3.0`.
