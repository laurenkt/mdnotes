# MDNotes codebase map

Read this instead of exploring. One line per file: what it owns and its key names. Keep it
current: when you add, remove or move a file, fix its line in the same commit (CLAUDE.md).
Feature IDs like `S-2` refer to `docs/SPEC.md`; `ADR-000N` to `docs/adr/`.

## Sources/MDNotes (executable entry point)

- `Sources/MDNotes/main.swift` — imports MDNotesApp and calls `App.run()`. Nothing else lives here.

## Sources/MDNotesCore (pure logic: index, search, links, tags, file store; no AppKit)

- `Sources/MDNotesCore/NoteID.swift` — note identity as root-relative `/`-separated path incl. `.md`. `NoteID`, `.relativePath`, `.title`.
- `Sources/MDNotesCore/CaseFolding.swift` — the one case fold used by every case-insensitive comparison. `CaseFolding.fold`, `areEqual`.
- `Sources/MDNotesCore/WordSplitter.swift` — splits query text into whitespace-delimited words (S-2). `WordSplitter.words`, `foldedWords`.
- `Sources/MDNotesCore/BodySnippet.swift` — one-line list-row snippet from a body (S-6). `BodySnippet.make`, `maxCharacters`, `scanCharacters`.
- `Sources/MDNotesCore/LibraryScanner.swift` — walks the root for `.md` files, skipping `Trash`/`templates`. `ScannedNote`, `LibraryScanner.scan`, `noteID(forRelativePath:)`.
- `Sources/MDNotesCore/NoteStore.swift` — reads/writes one library root; iCloud availability and dataless detection (L-7/L-8). `NoteBody`, `NoteStore.read`, `url(for:)`, `requestDownload`, `isDownloaded`.
- `Sources/MDNotesCore/AtomicWriter.swift` — temp-file-plus-rename writes so readers never see a mix (E-5). `AtomicWriter.write(_:to:)`, `Interruption` hook for tests.
- `Sources/MDNotesCore/OwnWrites.swift` — ledger of this process's own writes so the watcher ignores their echoes (E-6). `OwnWrites.record`, `contains`, `suppressing(_:store:)`.
- `Sources/MDNotesCore/FSEventsWatcher.swift` — FSEvents stream over the root, reporting changes as note ids (X-1). `FSEventsWatcher.start/stop`, `Handler`, `WatchError`, `defaultLatency`.
- `Sources/MDNotesCore/DownloadRequester.swift` — keeps a download request outstanding per evicted note, at most one per 60 s (L-9, ADR-0009). `DownloadRequester.requestDownloads`, `refreshOutstanding`, `Refresh`.
- `Sources/MDNotesCore/MarkdownScanner.swift` — single left-to-right pass yielding headings, wikilinks, embeds, tags, code ranges. `MarkdownScanner.scan`, `Token`, `Kind`, `paragraphRange`.
- `Sources/MDNotesCore/SearchIndex.swift` — immutable in-memory snapshot of all notes' searchable text (S-2/S-3/S-4, ADR-0003). `SearchIndex`, `.Entry`, `.Results`, `.Builder`, `query`, `queryTitles`.
- `Sources/MDNotesCore/SearchIndexBuild.swift` — builds snapshots from scanned notes, titles-only first for fast launch. `SearchIndex.build`, `titlesOnly`, `applying(reading:store:)`.
- `Sources/MDNotesCore/SearchIndexUpdate.swift` — applies watcher batches incrementally without a rescan (X-1). `LibraryChanges`, `SearchIndex.applying(changes:store:)`.
- `Sources/MDNotesCore/NoteReferences.swift` — links and tags extracted from one body, feeding both indexes (K-1, T-1). `LinkTarget`, `NoteReferences(scanning:)`.
- `Sources/MDNotesCore/LinkIndex.swift` — outgoing targets, backlinks, and target-to-note resolution (K-2/K-5, ADR-0005). `LinkIndex.resolve`, `outgoing`, `backlinks`, `applying`, `Resolution`.
- `Sources/MDNotesCore/TagIndex.swift` — tags-to-notes and notes-to-tags, rebuilt incrementally with LinkIndex (T-2). `TagIndex.tags(in:)`, `notes(tagged:)`, `allTags`, `applying`.
- `Sources/MDNotesCore/LinkCompletion.swift` — rules for the `[[` popover: trigger, filter text, candidate titles (K-4). `LinkCompletion.anchor`, `filterText`, `titles`, `insertion`.
- `Sources/MDNotesCore/TagCompletion.swift` — same rules for the `#` popover (T-3). `TagCompletion.anchor`, `filterText`, `tags(withPrefix:in:)`, `insertion`.
- `Sources/MDNotesCore/NoteCreation.swift` — query text to note to create, or a typed rejection (C-2/C-3). `NoteCreation.noteID(forQuery:)`, `Rejection`, `NoteStore.create`.
- `Sources/MDNotesCore/NoteRename.swift` — edited title to renamed id or rejection, plus collision check (R-2). `NoteRename.noteID(renaming:toTitle:)`, `collision`, `NoteStore.rename`.
- `Sources/MDNotesCore/LinkRewrite.swift` — pure plan for rewriting wikilinks after a rename (R-3). `LinkRewrite.plan`, `rewriting(_:replacing:)`, `Replacements`.
- `Sources/MDNotesCore/ImageStore.swift` — where pasted/dropped images go under `i/` and which file an embed names (I-1, I-2). `ImageStore.write`, `url(forEmbed:)`, `fileName`, `Failure`.

## Sources/MDNotesApp (AppKit layer: window, controllers, views; headlessly testable)

- `Sources/MDNotesApp/App.swift` — entry point called by `main.swift`; everything else stays library-side for tests. `App.run()`.
- `Sources/MDNotesApp/AppDelegate.swift` — launch: opens library root, builds window, menu, hotkey, Settings; hotkey toggle, hide-on-close, Dock reopen, termination (W-3, W-4, E-4). `AppDelegate.openLibrary`, `setHotKey`, `toggleFromHotKey`, `showMainWindow`, `hideMainWindow`, `isAppActive`.
- `Sources/MDNotesApp/MainMenu.swift` — code-built menu bar (P-2); targetless items resolved through the responder chain. `MainMenu` (App/Edit/Note/View/Window menus; View holds Bigger/Smaller/Actual Size (E-8) and the backlinks toggle).
- `Sources/MDNotesApp/MainWindowController.swift` — the single main window (W-1), floating and following the active Space (W-5): search field, list, editor wiring; commit/rename/delete/open-link/insert-image actions; View menu font size actions (E-8). `MainWindowController.attach`, `commitQuery`, `commitTitle`, `openLink`, `search`, `makeTextBigger/Smaller/ActualSize`, `validateMenuItem`, `windowLevel`, `overlayLevel`.
- `Sources/MDNotesApp/MainView.swift` — content layout per W-2/W-6: search field, eviction bar, message line, list, split, editor, backlinks. `MainView.showMessage`, `focusSearchField`, `applyEditorFont`.
- `Sources/MDNotesApp/LibraryController.swift` — owns one library: root, `NoteStore`, snapshots, background scan/index queue, watcher, CRUD. `LibraryController.start`, `apply`, `create`, `rename`, `delete`, `storeImage`, `EvictionStatus`, `Phase`.
- `Sources/MDNotesApp/LibraryRootPreference.swift` — library folder in `UserDefaults`, defaulting to `~/Documents/MDnotes` (L-1). `LibraryRootPreference`.
- `Sources/MDNotesApp/NoteListController.swift` — table data source/delegate over one `SearchIndex.Results`; inline title editing; date refresh on `NSCalendarDayChanged` and key window (S-6, S-9). `NoteListController.show`, `select`, `beginEditingTitle`, `dateText`, `refreshDates`, `now`.
- `Sources/MDNotesApp/NoteTableView.swift` — intercepts arrows/Return/Tab before `NSTableView` handles them (S-7, S-8). `NoteTableView`.
- `Sources/MDNotesApp/NoteRowView.swift` — one fixed-frame row: title, trailing date, snippet line (S-6, S-10, PF-2). `NoteRowView.configure`, `setDateText`, `beginEditingTitle`.
- `Sources/MDNotesApp/RelativeDateText.swift` — Notes-style modified dates: `Today 11:53`, `Mon`, `3 Sep` (S-9). `RelativeDateText.string`, `band`, `Band`.
- `Sources/MDNotesApp/EditorController.swift` — loads bodies off-main and applies them, autosaves, tracks edits, drives completions (S-8, E-4). `EditorController.load`, `flush`, `reloadFromDisk`, `insertEmbed`, `linkTargetAtCaret`.
- `Sources/MDNotesApp/EditorTextView.swift` — intercepts Cmd-click and Cmd-Return for link opening (K-3). `EditorTextView`, `characterIndex`.
- `Sources/MDNotesApp/EditorStyler.swift` — syntax styling of headings, links, tags, code (code in the monospaced font, E-8); paragraph-scoped restyle (E-2, E-3). `EditorStyler.restyleAll`, `restyleAfterEdit`, `restyleLinks`, `TokenStyle`, `baseFont`, `codeFont`.
- `Sources/MDNotesApp/EditorFontPreference.swift` — system font at the size in `UserDefaults`, 9 to 36 pt, and the code font at that size; zoom steps; deletes the v1 family key (E-8, ADR-0010). `EditorFontPreference.font`, `codeFont`, `size`, `bigger`, `smaller`, `resetSize`, `deleteStaleFamily`.
- `Sources/MDNotesApp/AutosaveClock.swift` — the clock the autosave delay runs on; tests substitute a manual one (E-4). `AutosaveClock`, `AutosaveTimer`, `SystemAutosaveClock`.
- `Sources/MDNotesApp/CompletionController.swift` — the shared completion popover plus per-trigger rule types (K-4, T-3). `CompletionController`, `CompletionRules`, `LinkCompletionRules`, `TagCompletionRules`.
- `Sources/MDNotesApp/BacklinksStrip.swift` — collapsible bar under the editor listing notes linking here (K-6). `BacklinksStrip.show`, `setCollapsed`, `toggleCollapsed`.
- `Sources/MDNotesApp/EvictionBar.swift` — line under the search field counting dataless notes, free space, Storage Settings button (L-10). `EvictionBar.show`, `hide`.
- `Sources/MDNotesApp/ReadOnlyNoticeBar.swift` — line above the editor explaining why the note cannot be edited (L-7, L-8). `ReadOnlyNoticeBar.show`, `hide`.
- `Sources/MDNotesApp/ImagePasteboard.swift` — an image on the pasteboard, decoded off-main into bytes (I-1). `ImageSource`, `ImagePasteboard`, `encoded()`, `Failure`.
- `Sources/MDNotesApp/HotKey.swift` — key-code + modifiers value for the global hotkey and its `UserDefaults` storage (W-3). `HotKey`, `HotKeyPreference`.
- `Sources/MDNotesApp/GlobalHotKey.swift` — Carbon `RegisterEventHotKey` registration, no Accessibility permission (W-3). `GlobalHotKey.register`, `unregister`, `RegistrationError`.
- `Sources/MDNotesApp/HotKeyRecorder.swift` — button that displays and records a new combination (W-3, PR-1). `HotKeyRecorder.beginRecording`, `showHotKey`.
- `Sources/MDNotesApp/PreferencesWindowController.swift` — Settings window: library folder, hotkey recorder, nothing else (PR-1). `PreferencesWindowController.setLibraryRoot`, `setHotKey`.

## Sources/MDNotesTestSupport (shared test helpers)

- `Sources/MDNotesTestSupport/SyntheticLibrary.swift` — deterministic fake library on disk: nesting, tags, wikilinks, `i/`, large notes. `SyntheticLibrary.generate`, `Options`, `SplitMix64`.
- `Sources/MDNotesTestSupport/PerfGate.swift` — executable perf budgets from `docs/SPEC.md`; a blown budget fails the test. `PerfGate.Budget`, `measure`, `report`, `residentMemoryMB`.

## Tests/MDNotesCoreTests (pure-logic tests, XCTest)

- `Tests/MDNotesCoreTests/NoteIDTests.swift` — note id path/title round-trips.
- `Tests/MDNotesCoreTests/CaseFoldingTests.swift` — folding and equality across scripts and diacritics.
- `Tests/MDNotesCoreTests/WordSplitterTests.swift` — query word splitting, Unicode whitespace, punctuation staying in words.
- `Tests/MDNotesCoreTests/BodySnippetTests.swift` — one-line snippet generation and its survival inside the index (S-6).
- `Tests/MDNotesCoreTests/LibraryScannerTests.swift` — root walking, `.md` filtering, skipped folders, relative-path ids.
- `Tests/MDNotesCoreTests/NoteStoreTests.swift` — reading bodies, availability probe, dataless and unwritable cases.
- `Tests/MDNotesCoreTests/AtomicWriterTests.swift` — temp-then-rename semantics, interrupted commits, no torn reads (E-5).
- `Tests/MDNotesCoreTests/OwnWritesTests.swift` — the own-write ledger the watcher consults to suppress echoes (E-6).
- `Tests/MDNotesCoreTests/FSEventsWatcherTests.swift` — real watcher over a temp library with real file ops, every wait timed out (X-1).
- `Tests/MDNotesCoreTests/DownloadRequesterTests.swift` — one request per dataless note per 60 s, repeated after re-eviction (L-9).
- `Tests/MDNotesCoreTests/MarkdownScannerTests.swift` — token kinds and ranges: headings, links, embeds, tags, inline and fenced code.
- `Tests/MDNotesCoreTests/SearchIndexTests.swift` — snapshot building, query and title-query matching, ordering (S-2, S-3).
- `Tests/MDNotesCoreTests/SearchIndexUpdateTests.swift` — incremental add/modify/remove keeping list order without a rescan (X-1).
- `Tests/MDNotesCoreTests/LinkIndexTests.swift` — outgoing links, backlinks, unique/ambiguous/path resolution (K-1, K-2, K-5).
- `Tests/MDNotesCoreTests/TagIndexTests.swift` — tag/note maps, case-insensitivity with library spelling, incremental updates (T-2).
- `Tests/MDNotesCoreTests/LinkCompletionTests.swift` — `[[` session opening, filter text, candidate titles (K-4).
- `Tests/MDNotesCoreTests/TagCompletionTests.swift` — `#` session opening, prefix filtering, candidate tags (T-3).
- `Tests/MDNotesCoreTests/NoteCreationTests.swift` — query to note id, rejections, and `NoteStore.create` writing folders (C-2, C-3).
- `Tests/MDNotesCoreTests/NoteRenameTests.swift` — title to renamed id, rejections, and renames that never overwrite (R-2).
- `Tests/MDNotesCoreTests/LinkRewriteTests.swift` — which links a rename must rewrite and how one body is rewritten (R-3).
- `Tests/MDNotesCoreTests/ImageStoreTests.swift` — image file naming under `i/` and embed-to-file lookup (I-1, I-2).
- `Tests/MDNotesCoreTests/SyntheticLibraryTests.swift` — the generator is deterministic and has the promised shape.
- `Tests/MDNotesCoreTests/IndexPerfTests.swift` — core timing gates over the 20k-note library: full index, query (PF-2, PF-4).
- `Tests/MDNotesCoreTests/IndexMemoryPerfTests.swift` — resident memory after one 20k index build; own class so it runs fresh (PF-5).

## Tests/MDNotesAppTests (headless AppKit smoke tests; real NSEvents, no UI clicks)

- `Tests/MDNotesAppTests/MainWindowFixtures.swift` — shared fixture: `makeMainWindowController(autosaveClock:)` plus a main-actor box for teardown.
- `Tests/MDNotesAppTests/WindowSnapshots.swift` — V-1 rendering helper: `writeWindowSnapshots(of:named:)` for a `MainWindowController`, `writeWindowSnapshots(ofWindow:named:)` for any window; writes `build/snapshots/<name>-{light,dark}.png` at 2x.
- `Tests/MDNotesAppTests/ManualAutosaveClock.swift` — `AutosaveClock` that only advances when a test says so; timers fire in deadline order (E-4).
- `Tests/MDNotesAppTests/AppSmokeTests.swift` — the smallest headless launch: real controllers without a running app.
- `Tests/MDNotesAppTests/LayoutSmokeTests.swift` — view stacking order at a given size, frame and split-position persistence (W-1, W-2).
- `Tests/MDNotesAppTests/MenuSmokeTests.swift` — menu items found by action, sent down the responder chain; Cmd-W and close button hide, Dock reopen, quit writes edits (W-4).
- `Tests/MDNotesAppTests/WindowLevelSmokeTests.swift` — main window `.floating` and `moveToActiveSpace`; completion panel and Settings at `overlayLevel` above it (W-5).
- `Tests/MDNotesAppTests/BundleTests.swift` — runs `scripts/info-plist.sh` directly to cover the emitted Info.plist.
- `Tests/MDNotesAppTests/SearchSmokeTests.swift` — typing in the real field editor drives the list per keystroke (S-1, S-5).
- `Tests/MDNotesAppTests/NoteListSmokeTests.swift` — list rendering, date width and title truncation, date refresh on day change/key window, selection driving the editor (S-6, S-9, S-10, S-8); list snapshot (V-1).
- `Tests/MDNotesAppTests/KeyboardFlowSmokeTests.swift` — search/list/editor focus flow via real key events (S-7, S-8).
- `Tests/MDNotesAppTests/CreateSmokeTests.swift` — Enter in the search field creating notes and its rejections (C-1 to C-4).
- `Tests/MDNotesAppTests/RenameSmokeTests.swift` — Cmd-R inline rename, Return/Escape, collisions (R-1, R-2, D-2).
- `Tests/MDNotesAppTests/DeleteSmokeTests.swift` — Cmd-Delete moving the real file to the Trash (D-1, D-2).
- `Tests/MDNotesAppTests/AutosaveSmokeTests.swift` — autosave timing, atomic write, own-write record (E-4, E-5, E-6).
- `Tests/MDNotesAppTests/UndoSmokeTests.swift` — undo through the real text view and the `undo:` action (E-7).
- `Tests/MDNotesAppTests/EditorStylingSmokeTests.swift` — styling applied by the storage delegate and its paragraph scope; the mono font on code tokens only (E-2, E-3, E-8).
- `Tests/MDNotesAppTests/EditorFontSmokeTests.swift` — system font at the stored size, size clamped to 9 to 36, View menu Bigger/Smaller/Actual Size clamping and persisting, stale family key deleted at launch, Settings without font controls; editor and Settings snapshots (E-8, PR-1, V-1).
- `Tests/MDNotesAppTests/PreferencesSmokeTests.swift` — library folder remembered, read at launch, changed via the chooser (PR-1, L-1).
- `Tests/MDNotesAppTests/HotKeySmokeTests.swift` — default Ctrl-Cmd-N, Carbon registration, show/hide toggle via `fire()` and recording (W-3, PR-1).
- `Tests/MDNotesAppTests/LinkCompletionSmokeTests.swift` — the `[[` popover driven by real key events (K-4).
- `Tests/MDNotesAppTests/TagCompletionSmokeTests.swift` — the `#` popover and click-to-search on a tag (T-3, T-4).
- `Tests/MDNotesAppTests/LinkOpeningSmokeTests.swift` — Cmd-Return and Cmd-click opening the link under the caret/pointer (K-3).
- `Tests/MDNotesAppTests/BacklinksSmokeTests.swift` — backlinks strip contents, click-to-open, hide/collapse, the title-button cap (K-6, PF-6).
- `Tests/MDNotesAppTests/LinkRewriteSmokeTests.swift` — a committed rename rewriting links on disk atomically (R-3).
- `Tests/MDNotesAppTests/ImageInsertSmokeTests.swift` — paste/drop writing under `i/` and embedding at the caret (I-1, I-2).
- `Tests/MDNotesAppTests/ExternalEditSmokeTests.swift` — disk changes behind the app's back arriving via the real watcher (X-2, X-3, X-4).
- `Tests/MDNotesAppTests/LibraryControllerSmokeTests.swift` — progressive list population and main-thread snapshot delivery (PF-6, PF-7).
- `Tests/MDNotesAppTests/DownloadRequestSmokeTests.swift` — download requests after scan and after every watcher batch (L-9).
- `Tests/MDNotesAppTests/EvictionBarSmokeTests.swift` — the eviction bar's count, free space and Storage Settings button (L-10).
- `Tests/MDNotesAppTests/ReadOnlyNoticeSmokeTests.swift` — read-only body shown with the reason line above the editor (L-7, L-8).
- `Tests/MDNotesAppTests/LaunchPerfTests.swift` — cold launch to interactive through the real `applicationDidFinishLaunching` (PF-1).
- `Tests/MDNotesAppTests/ListPerfTests.swift` — keystroke, query, reload, visible-row layout over 20k notes (PF-2).
- `Tests/MDNotesAppTests/EditorPerfTests.swift` — keystroke, paragraph restyle, redraw in a 1 MB note (PF-3, E-3).
- `Tests/MDNotesAppTests/BacklinksPerfTests.swift` — `BacklinksStrip.show` with 2,000 backlinks, expanded and collapsed, warm-up plus median in release (K-6, PF-6).

## Where things happen

- Search query path: keystroke, `MainWindowController.searchQueryDidChange`, `SearchIndex.query` (`Sources/MDNotesCore/SearchIndex.swift`), `NoteListController.show`.
- Enter in the search field: `MainWindowController.commitQuery`, `NoteCreation.noteID(forQuery:)`, `LibraryController.create`; rejections shown by `MainView.showMessage`.
- List rows and dates: `Sources/MDNotesApp/NoteListController.swift` + `NoteRowView.swift`; date strings in `RelativeDateText.swift`; snippets in `Core/BodySnippet.swift`.
- Editor styling: `Sources/MDNotesApp/EditorStyler.swift` (colours/weights/fonts) over tokens from `Sources/MDNotesCore/MarkdownScanner.swift`; scope in `restyleAfterEdit`.
- Autosave: `Sources/MDNotesApp/EditorController.swift` (`flush`) scheduled by `AutosaveClock.swift`, written by `Core/AtomicWriter.swift`, logged in `Core/OwnWrites.swift`.
- File watcher: `Sources/MDNotesCore/FSEventsWatcher.swift`, `OwnWrites.suppressing`, `LibraryController.apply`, `SearchIndex.applying(changes:store:)`.
- Links and tags: extraction in `Core/NoteReferences.swift`; maps in `Core/LinkIndex.swift` / `Core/TagIndex.swift`; opening in `MainWindowController.openLink`; rename rewrite in `Core/LinkRewrite.swift`.
- Completion popovers: `Sources/MDNotesApp/CompletionController.swift` with rules from `Core/LinkCompletion.swift` and `Core/TagCompletion.swift`.
- Global hotkey: `Sources/MDNotesApp/GlobalHotKey.swift` (Carbon), value in `HotKey.swift`, recorded by `HotKeyRecorder.swift`, wired in `AppDelegate.setHotKey`.
- Settings window: `Sources/MDNotesApp/PreferencesWindowController.swift`; backing defaults in `LibraryRootPreference.swift`, `EditorFontPreference.swift`, `HotKey.swift`.
- Menus: `Sources/MDNotesApp/MainMenu.swift`; item enablement via `MainWindowController.validateMenuItem`; app-level items in `AppDelegate.swift`.
- Images and embeds: `Sources/MDNotesApp/ImagePasteboard.swift` (decode off-main), `LibraryController.storeImage`, `Core/ImageStore.swift`; resolution via `LibraryController.locateEmbed`. Thumbnails: none yet (M8).
- iCloud download status: `Core/NoteStore.isDownloaded`/`isAvailable`, `Core/DownloadRequester.swift`, `LibraryController.EvictionStatus`, `EvictionBar.swift` / `ReadOnlyNoticeBar.swift`.
- Perf tests and budgets: budgets in `Sources/MDNotesTestSupport/PerfGate.swift`; fixtures in `SyntheticLibrary.swift`; gates in `Tests/MDNotesCoreTests/IndexPerfTests.swift`, `IndexMemoryPerfTests.swift`, `Tests/MDNotesAppTests/LaunchPerfTests.swift`, `ListPerfTests.swift`, `EditorPerfTests.swift`, `BacklinksPerfTests.swift`.
