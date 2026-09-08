# Acceptance checklist

One line per spec ID in `SPEC.md`, checked by hand against the built app. A discrepancy
becomes a task in `PLAN.md`; the task IDs are named in the notes. Re-run this pass before a
release tag; the setup and the driving scripts it needs are described at the end.

Result key: **pass**, **fail** (task named), **gate** (enforced by `scripts/check.sh full`,
not checkable by hand), **n/a by hand** (why), **blocked** (question in `QUESTIONS.md`).

## Pass of 2026-09-08 (M7.6, v3)

Build: debug `swift test` at commit 2509653 (code as of 2bd76de, M7.5), macOS 26.2. No app was
launched: the human's instance was running on the real library, so every window was inspected
through the V-1 snapshots the smoke tests write (`build/snapshots/{main-window,note-list,
editor-fonts,eviction-bar,settings}-{light,dark}.png`, opened and compared against W-6, PR-1
and direction B on the ADR-0013 canvas), the menu bar through `MainMenu` and the M7.5 audit
test, and the snippet rules by calling `BodySnippet.make` on markdown bodies from a script
linked against the built `MDNotesCore`. Scope: the eleven IDs M7.1 to M7.5 cite. Every other
ID stands as recorded in the M6.9, v0.1.0 and M5.6 passes.

Summary: 11 IDs; 8 pass, 0 fail, 2 gate, 1 n/a by hand. No task was added.

| ID   | Result | Notes |
|------|--------|-------|
| P-2  | pass | The menu bar is `MainMenu.make()`: app, File, Edit, Note, View and Window menus, every item built in code and targetless; `testP2_launchInstallsTheMenuBarWithTheStandardMenusAndNoSaveItem` checks all 24 titles and shortcuts as one table, and no `.storyboard`, `.xib` or SwiftUI import exists under `Sources/`. |
| S-6  | pass | `BodySnippet.make`: `# Hub\nSee [[Kubernetes operator\|the operator]] and [[Glossary]].` gives `Hub See the operator and Glossary.`; a leading `![[20260101-120000.png]]` contributes nothing; a `swift` fence gives `let answer = 42 after the fence` with both fence lines gone; `**bold** and _emphasised_ but snake_case, 2 * 3 and * a bullet` keeps the underscore, the product and the bullet; inline code is left as written; a body that is only an embed or only `### ` gives an empty snippet. The `note-list` snapshot shows one line per row in the secondary colour under the title, cut with an ellipsis. |
| E-8  | pass | The `editor-fonts` snapshot, light and dark: heading, prose, link and tag in the system font at 13 pt, inline and fenced code in the monospaced font at the same size, no family control anywhere. View menu: `Bigger` ⌘+, `Smaller` ⌘-, `Actual Size` ⌘0 above the backlinks item; `EditorFontSmokeTests` drives the clamping and persistence the M6.9 pass checked by hand. |
| W-2  | pass | Top to bottom in the `main-window` and `editor-fonts` snapshots: search strip, hairline, list, split divider, editor; the `eviction-bar` snapshot puts the bar between the strip and the hairline (L-10). `LayoutSmokeTests` asserts the order at a given size and that the divider drags and persists. |
| W-4  | pass | File › Close is the only `performClose` item, ⌘W; the five `testW4_*` smoke tests hide on close and the close button, keep the process, reopen from the Dock and the hotkey, and quit with edits written. The M6.9 pass drove the same by hand; M7.5 only moved the item from the Window menu into the new File menu. |
| W-6  | pass | `main-window` snapshot at 480 × 320 pt: a standard `NSSearchField` with its default bezel on a `windowBackgroundColor` strip, 8 pt above and below, 10 pt each side (the field spans x 10 to 470), a one-pixel `separatorColor` hairline beneath, then the list. Dark is the same layout on the dark window colour. The title bar is outside the content-view render; `testW6_titleBarShowsTheWindowTitle` covers the visible `MDNotes` title, and `tabbingMode` is `.disallowed`. Against direction B: same 28 pt title bar, inset field, hairline, 46 pt rows with a semibold 13 pt title, the date right-aligned on the title line and a secondary-colour snippet beneath. The only `NSColor`s in `Sources/` are `windowBackgroundColor`, `secondaryLabelColor`, `linkColor` and `systemPurple`. |
| PR-1 | pass | `settings` snapshot, 480 × 100 pt: two `NSGridView` rows, captions `Notes folder:` and `Global shortcut:` right-aligned to one trailing edge, the path (middle-truncated) with a `Choose…` button, the recorder showing ⌃⌘N, 20 pt margins on every side, nothing else. The window is titled `Settings`, style mask `[.titled, .closable]` (no resize, no minimise, no toolbar), and `Settings…` ⌘, sits in the app menu. The M6.9 fail (titled `Preferences`, captions `Library folder`/`Global hotkey`) is gone. |
| TP-6 | n/a by hand | M7.5 lands only the placeholder: File › `New from Template` opens a submenu holding one disabled `No Templates` row (`testTP6_fileMenuHoldsANewFromTemplatePlaceholderSubmenuAndClose`). Listing templates and creating from one is M9.5's; this pass will check it there. |
| V-1  | pass | `writeWindowSnapshots` wrote twelve files: `main-window` 960 × 640 px for a 480 × 320 pt content view, `note-list` 960 × 800, `editor-fonts` 1600 × 1200, `settings` 960 × 200, `eviction-bar` and `transparent-content` likewise, each in light and dark, and the light and dark files differ. The content view sits on `windowBackgroundColor` (I-7). `build/` is ignored by git. |
| PF-2 | gate | `ListPerfTests`, `IndexPerfTests` under `scripts/check.sh full`; `testPF2_snippetIsStrippedWhenTheIndexIsBuiltNotWhenRead` shows the stripping happens in the build, never in a query. |
| PF-4 | gate | `IndexPerfTests` under `scripts/check.sh full`; `BodySnippet` reads at most 2,048 UTF-16 units of a body, so a 1 MB note costs the same as a short one. |

Observation outside the spec: the `note-list` snapshot's selected row is drawn in the
inactive (grey) highlight because a headless window is never key; in the running app the
row takes the accent colour, as the M5.6 pass saw.

## Pass of 2026-09-08 (M6.9, v2)

Build: `scripts/bundle.sh` at commit 1b017f4 (M6.8), macOS 26.2. Library: a nine-note stand-in
(a heading, links, a tag, inline and fenced code in `Hub`; a 95-character title; notes dated
today, yesterday, three days ago, 1 March, July 2025 and January 2024 via `touch -t`), launched
with `-LibraryRoot`. The human's own instance was running on the real library throughout, so
this one also took `-GlobalHotKeyKeyCode 45 -GlobalHotKeyModifiers 1310720` (the default
Ctrl-Cmd-N in the argument domain) to keep the two hotkeys apart, and the defaults domain was
exported before and re-imported afterwards. System Events cannot tell two processes of one name
apart, so the window was read and driven through the AX API by pid (`AXUIElementCreateApplication`,
`CGEvent.postToPid`, the HID tap for the hotkey, a `rapp` Apple event for the Dock click).
Screen capture is not granted to the terminal, so what has to be seen rather than read was
checked in the V-1 snapshots the smoke tests write (`build/snapshots/{eviction-bar,note-list,
editor-fonts,settings}-light.png`). Scope: the eleven IDs M6.1 to M6.8 cite. Every other ID
stands as recorded in the M5.6 and v0.1.0 passes.

Summary: 11 IDs; 7 pass, 1 fail (M7.4, already planned), 3 n/a by hand.

| ID   | Result | Notes |
|------|--------|-------|
| L-7  | n/a by hand | Needs an evicted file in an iCloud container; `NoteStoreTests` and `DownloadRequestSmokeTests` cover it with the injected availability probe. |
| L-9  | n/a by hand | Same: no dataless note can be fabricated outside iCloud. `DownloadRequesterTests` (once per note per 60 s, repeat on re-eviction) and `DownloadRequestSmokeTests` (after scan and after every watcher batch) cover it. |
| L-10 | n/a by hand | Same. The `eviction-bar` snapshot shows the bar directly under the search field reading "2 notes not downloaded from iCloud. Search is incomplete. · 985 MB free" with an Open Storage Settings button; `EvictionBarSmokeTests` covers the transitions and the 2 GB threshold. |
| S-9  | pass | Rows read `Today 11:56`, `Yesterday 11:56`, `Sat` (three days ago), `1 Mar`, `15 Jul 2025`, `2 Jan 2024`; 24-hour time from the en_GB locale. Refresh on day change and key window is not waitable by hand; `NoteListSmokeTests` drives both. |
| S-10 | pass | At 925 pt the date labels are 65, 85, 20, 31, 63 and 62 pt wide (their intrinsic widths); at 400 pt they keep those widths and the title labels shrink from 815 to 290 pt. The `note-list` snapshot shows the title ending in an ellipsis with the date whole at the right. |
| E-2  | pass | AX runs: `# Hub` in `.SFNS-Bold 13`, links in the link colour (0.00/0.41/0.85), `#idea` purple, inline and fenced code in the secondary colour, everything else the base font at the same size; the file was unchanged by styling. |
| E-8  | pass | Prose `.AppleSystemUIFont 13`, code `.AppleSystemUIFontMonospaced-Regular 13`. Cmd-plus went to 14 (`EditorFontSize` 14 in the domain), Cmd-minus back to 13, Cmd-0 from 15 to 13; thirty Cmd-plus stopped at 36 and forty Cmd-minus at 9; View › Bigger, Smaller and Actual Size did the same. An `EditorFontFamily = Menlo` written before launch was gone once the app was up. |
| W-3  | pass | With the Finder active and `hub` in the field, Ctrl-Cmd-N activated the app, showed the window and focused the field with `hub` selected; a second press hid the window (process alive); a third showed it again with the query intact. No Accessibility prompt. |
| W-4  | pass | Cmd-W and the close button each ordered the window out with the process still running; a reopen event (what the Dock click sends) brought it back with focus still in the field. Text typed into `Hub` followed by Cmd-Q at once: the process was gone within 100 ms and the file held the text. |
| W-5  | pass | The main window is at CG layer 3 (`.floating`) and stayed on screen and above the Finder's, Safari's and Calendar's windows while the Finder was active. The `[[` completion panel (layer 4) and the Settings window (layer 4) both sit above it. Following the active Space is not observable by hand; `WindowLevelSmokeTests` asserts `moveToActiveSpace`. |
| PR-1 | **fail** (M7.4) | Cmd-comma opens it: fixed size (AXSize not settable, zoom and minimize disabled), no toolbar, one `NSGridView` with right-aligned captions, a Choose… button and the hotkey recorder, and the font controls M6.6 removed are gone. But the window and its title bar read `Preferences`, not `Settings`, and the captions are `Library folder:` and `Global hotkey:` where PR-1 says `Notes folder` and `Global shortcut`. M7.4 already carries the retitle. |

Observation outside the spec: after the hotkey hides the window the app is no longer the active
application (AppKit deactivates an app with no windows on screen), so the next press takes the
"show" branch as W-3 intends; nothing in the spec says which app should be active afterwards.

## Release pass of 2026-09-07 (M5.7, `v0.1.0`)

Build: `scripts/bundle.sh` at commit 96d28d4 (M5.6e); the plist reports 0.1.0 and the bundle
is ad-hoc signed. Library: a stand-in (two notes titled `foo`, a Latin-1 note, a note with
1,500 backlinks, an image-only clipboard), launched with `-LibraryRoot` and driven as the M5.6
pass was; the defaults domain was removed afterwards. Scope: the five IDs whose code changed
since the M5.6 pass (M5.6a to M5.6e). Every other ID stands as recorded in that pass, and the
gate IDs ran green under `scripts/check.sh full` in the commit that carries this tag.

| ID  | Result | Notes |
|-----|--------|-------|
| L-8 | pass | The Latin-1 note shows "This note is not valid UTF-8 and is shown read-only." above the editor; Tab then typing changed nothing; the file's bytes and date were untouched; the notice was gone when the next note loaded. |
| K-2 | pass | `[[foo]]` with `foo.md` and `archive/foo.md` both present is set in the warning tint (AX foreground 1.00/0.55/0.16, systemOrange); the unique `[[Hub]]` is in the link colour (0.00/0.41/0.85). |
| K-6 | pass | Opening the note with 1,500 backlinks: Down to the editor and the field answering over AX in 0.24 s, osascript spawn included, no beachball. The strip reads "20 of 1500 backlinks" and shows as many of the 20 title buttons as fit (12 at the default width, newest first); Cmd-Shift-B collapses it to "1500 backlinks" with no buttons and back again; clicking `link 1500` opened that note. |
| I-1 | pass | With a PNG and nothing else on the clipboard, Edit › Paste was enabled with the editor focused; Cmd-V and Edit › Paste each wrote `i/<yyyyMMdd-HHmmss>.png` byte-identical to the source and inserted `![[<name>]]` at the caret; the file held the text at the next read. |
| W-1 | pass | The View menu holds Hide Backlinks and Enter Full Screen only; Show Tab Bar / Show All Tabs are gone. |

Release decision: `v0.1.0` is tagged with M2.6b open (Q1: C-4 after a nested-path create).
The result key above admits a blocked entry in a release pass, `PLAN.md` puts no dependency
between M5.7 and M2.6b, the behaviour shipped is the interim one M2.6a landed and Q1 records,
and the bundle already reports 0.1.0. Q1 is the human's to answer; its answer ships in a
later tag.

## Pass of 2026-09-07 (M5.6)

Build: `scripts/bundle.sh` at commit 9d2d2a9 (M5.5), macOS 26.2. Library: a stand-in shaped
like the real one (1,521 `.md` files, nested `daily/<year>/` and `projects/` folders, `i/`,
non-note files, `Trash/`, `.obsidian/`, `templates/`, a hidden note, a non-UTF-8 note, a
1 MB note, two notes titled `foo`, a note with 1,500 backlinks), because the real library at
`~/Documents/MDnotes` is read-only to the agent and could not be copied by it. The app was
launched with `-LibraryRoot <stand-in>` so the stored preference was untouched, driven
through System Events and the accessibility API, and quit at the end; the defaults domain
it wrote (`dev.laurenkt.mdnotes`) was removed afterwards. A human should repeat the pass
once against a copy of the real library.

Summary: 67 spec IDs; 53 pass, 4 fail (M5.6a to M5.6d), 10 gate or n/a by hand. C-4 passes for
flat titles and is blocked on Q1 for nested paths. M5.6e comes from an observation under W-1,
which passes.

### 1. Platform

| ID  | Result | Notes |
|-----|--------|-------|
| P-1 | pass | `Package.swift` platforms `.macOS("26.0")`, `LSMinimumSystemVersion` 26.0, tools 6.2, `treatAllWarnings(as: .error)`. |
| P-2 | pass | No storyboards, xibs or SwiftUI under `Sources/`; every view is built in code. |
| P-3 | pass | `find . -name '*.xcodeproj' -o -name '*.xcworkspace'` finds nothing. |
| P-4 | pass | `codesign -dv build/MDNotes.app`: `Signature=adhoc`, no team; `--entitlements` prints none. |
| P-5 | pass | `grep -l "import AppKit" Sources/MDNotesCore` finds nothing; `Sources/MDNotes/main.swift` is `import MDNotesApp` and `App.run()`. |

### 2. Library

| ID  | Result | Notes |
|-----|--------|-------|
| L-1 | pass | Default root is `~/Documents/MDnotes` (`LibraryController.defaultRoot`). Preferences › Choose… picked a second folder: the list showed its notes at once (the query was kept), the label showed the new path, and a relaunch without `-LibraryRoot` opened it. |
| L-2 | pass | 1,516 rows for 1,521 files: every `.md` under the root and its subfolders, minus the 5 skipped by L-3. Nested notes list under their file names (`07-monday`). |
| L-3 | pass | `Trash/old.md`, `.obsidian/hidden note.md`, `templates/daily.md`, `.hidden note.md` and `.git/HEAD.md` are not listed; searching their bodies finds nothing. |
| L-4 | pass | `foo.md` and `archive/foo.md` are two rows, each its own note; renaming `archive/foo` stayed in `archive/`. |
| L-5 | pass | `Cafe notes.md` whose first line is `# Café notes` lists as `Cafe notes`; a note whose H1 differs from its file name lists by file name. |
| L-6 | pass | `readme.txt`, `data.json`, `attachment.txt` and `i/*.png` are never rows; searching their contents finds nothing. |
| L-7 | n/a by hand | Needs an evicted file in an iCloud container, which the stand-in cannot fabricate; `NoteStoreTests` cover it with an injected availability probe. |
| L-8 | **fail** (M5.6d) | The Latin-1 note lists by title, shows with U+FFFD in place of the bad bytes, takes no typing, and is byte-identical on disk afterwards. But nothing tells the user why: no notice is shown anywhere. |

### 3. Search and list

| ID  | Result | Notes |
|-----|--------|-------|
| S-1 | pass | One `NSSearchField` across the top, placeholder "Search or create"; Enter in it creates (C-1). |
| S-2 | pass | `operator kubernetes` and `KUBERNETES OPERATOR` list the same rows; `golang` finds body-only matches; `golang pancakes` (no note has both) lists nothing. |
| S-3 | pass | `foo`: the two title matches first, newest (`archive/foo`) above the root one, then the body matches newest first. Empty query: newest first. |
| S-4 | pass | `#kubernetes` lists the tagged notes as an ordinary substring match. |
| S-5 | pass | Typing `deploy` one key at a time: 1512, 1504, 1470, 1277, 1277, 1277 rows, each visible before the next key. |
| S-6 | pass | Each row exposes title, date (`01/01/2026, 15:00`, `Today, 09:57`) and a one-line snippet; every row is 46 pt. |
| S-7 | pass | Down from the field selects row 1 and focuses the list; Up from row 1 returns to the field; Escape from the field, the list and the editor clears the query and focuses the field; Cmd-L from the editor focuses the field with its text selected. |
| S-8 | pass | Down/Up through rows loads each note with focus staying in the list; Tab and Enter on a row focus the editor. |

### 4. Creation

| ID  | Result | Notes |
|-----|--------|-------|
| C-1 | pass | `travel PARIS` + Enter opened `Travel Paris` and focused the editor; an unknown title created it. |
| C-2 | pass | `Acceptance new note` wrote that file at the root; `projects/acc nested` wrote `projects/acc nested.md`; `newdir/sub/acc deep` made both folders; ` acc trimmed2 ` wrote `acc trimmed2.md`. |
| C-3 | pass | `acc:bad` + Enter showed "“:” cannot be used in a note name." under the field, created nothing, and the message went with the next keystroke. |
| C-4 | pass (flat), **blocked** Q1 (nested) | After a flat create the new note is the one selected row, the editor is focused and empty, and the field still holds the query. After a nested create the editor is focused and empty but the list is empty and nothing is selected: M2.6b, Q1. |

### 5. Editor

| ID  | Result | Notes |
|-----|--------|-------|
| E-1 | pass | After every check the file's bytes equalled the editor's text (`cat` against the AX value). |
| E-2 | pass | AX attributed runs: headings in the semibold face at the same size, `[[links]]` in the link colour, `#tags` purple, inline and fenced code in the secondary colour, everything else the base font; the file is unchanged by styling. |
| E-3 | gate | `EditorPerfTests` (PF-3). By hand: typing in the 1 MB note shows no lag. |
| E-4 | pass | Typed text was on disk 600 ms later; on note switch, on activating the Finder and on Cmd-Q the file held the text by the time the next command read it. No File menu, no Save item. |
| E-5 | pass | Each save gave the file a new inode (temp file then rename), no temp file was left behind, and the modification date was the save time. |
| E-6 | n/a by hand | An autosave produced no reload, caret move or log line, but a reload would be invisible anyway; `OwnWritesTests` and `AutosaveSmokeTests` cover it. |
| E-7 | pass | Typed in A, switched to B, typed, Cmd-Z undid B's edit only; back in A, Cmd-Z undid A's edit and Cmd-Shift-Z redid it. |
| E-8 | pass | Default run is `.AppleSystemUIFontMonospaced-Regular 13`. Preferences: size 15 restyled the editor at once, family Menlo gave `Menlo-Regular`, System Monospaced 13 restored it. |

### 6. External changes

| ID  | Result | Notes |
|-----|--------|-------|
| X-1 | pass | A file written, rewritten, `mv`'d and `rm`'d from a shell reached the list in 195, 246, 188 and 203 ms respectively (including ~100 ms of AX polling). |
| X-2 | pass | With the open note clean, rewriting it on disk replaced the editor text and kept the selection (6, 5). |
| X-3 | pass | With unsaved edits, rewriting the file on disk changed nothing in the editor and the next autosave wrote the editor's text over it. |
| X-4 | pass | Deleting the open, clean note cleared the editor and selected the row that took its place. With edits made just before the deletion the text stayed in the editor; by hand the 300 ms autosave outran the watcher, so the file was rewritten before the deletion was seen, and typing again saved as usual. `ExternalEditSmokeTests` covers the deterministic case. |

### 7. Rename and delete

| ID  | Result | Notes |
|-----|--------|-------|
| R-1 | pass | Cmd-R (with focus in the field or the list), a double-click on the title, and Note › Rename Note each turned the title into a focused field; Escape reverted and refocused the list. |
| R-2 | pass | `Travel Paris` → `Travel Paris renamed` renamed the file and the list showed it 600 ms later with the same note still open; `archive/foo` → `foo archived` stayed in `archive/`; `Ideas` (a collision) and `a:b` were rejected under the field with the file untouched. |
| R-3 | pass | `Kubernetes operator` → `K8s operator` rewrote `[[Kubernetes operator]]` in `Meeting notes.md` and `daily/2026/07-monday.md`, left `Deploy checklist.md` and `Glossary.md` byte-identical, and logged `renamed Kubernetes operator.md to K8s operator.md: rewrote links in 2 notes`. The path link `[[archive/foo]]` became `[[archive/foo archived]]`. |
| D-1 | pass | Cmd-Delete (also from the search field while a row was selected) and Note › Delete Note moved the file out of the library with no prompt; the row that took its place became selected. |
| D-2 | pass | The row was gone 190 ms after the key, before the watcher could have reported (`DeleteSmokeTests` proves the ordering). |

### 8. Links

| ID  | Result | Notes |
|-----|--------|-------|
| K-1 | pass | `[[Kubernetes operator]]`, `[[Glossary\|the glossary]]`, `[[projects/mdnotes]]` and `![[20260101-120000.png]]` are all styled as links; the embed opens a file (I-2), not a note. |
| K-2 | **fail** (M5.6c) | Resolution is right: the bare `[[foo]]` resolved to the newer `archive/foo` (the rename rewrite followed it there) and `[[archive/foo]]` by path to that file. But the ambiguous link is styled exactly like a unique one; nothing marks it ambiguous. |
| K-3 | pass | Cmd-click on `[[Meeting notes]]` opened it with the editor focused; a plain click into `[[Deploy checklist]]` then Cmd-Enter opened that; Cmd-click on `[[Nonexistent note]]` created `Nonexistent note.md` at the root and opened it empty. |
| K-4 | pass | Typing `[[Dep` showed a popover listing `Deploy checklist`; Enter inserted `Deploy checklist]]`; `[[x` then Escape dismissed it leaving `[[x`. |
| K-5 | pass | A link typed and autosaved, and one appended to a file from a shell, both appeared in the target's backlinks on the next open. |
| K-6 | **fail** (M5.6a) | The strip lists backlinks newest first, a click opens the note, it is hidden for a note with none, Cmd-Shift-B collapses it to "3 backlinks" and the View item flips to Show Backlinks, and the collapsed state survived a relaunch. But opening the note with 1,500 backlinks froze the app (no AX response, beachball) for 5 to 40 s while the strip built a button per backlink. |

### 9. Tags

| ID  | Result | Notes |
|-----|--------|-------|
| T-1 | pass | `#idea.` is styled without the dot, `#idea/physics` whole, `foo#bar` and `either#one` not at all, `#tag` inside a code span and `#fenced-tag` inside a fence not at all. |
| T-2 | pass | A tag typed into a note listed in the `#` completion once the note was autosaved. |
| T-3 | pass | `#kub` showed a popover of matching tags (prefix, case-insensitive), `#` alone every tag; Enter inserted the selected one; Escape dismissed. |
| T-4 | pass | A plain click on `#meeting` set the query to `#meeting`, reloaded the list, and left focus in the editor. |

### 10. Images

| ID  | Result | Notes |
|-----|--------|-------|
| I-1 | **fail** (M5.6b) | With a PNG (and nothing else) on the clipboard, Cmd-V and Edit › Paste do nothing: `NSTextView` validates Paste against its readable text types, so the item is disabled and `EditorTextView.paste` is never reached. Drop was not driven by hand (`ImageInsertSmokeTests` covers it). |
| I-2 | pass | Cmd-click on `![[20260101-120000.png]]` opened the file in Preview. |
| I-3 | pass | The editor shows the embed as text; its AX tree holds no image. |

### 11. Window and hotkey

| ID  | Result | Notes |
|-----|--------|-------|
| W-1 | pass | One window. Moved to (500, 200) and the divider dragged to a 300 pt list; both were back after quit and relaunch. Observation, not a failure: AppKit adds Show Tab Bar / Show All Tabs to the View menu; a tab bar makes no sense for a one-window app (M5.6e). |
| W-2 | pass | Top to bottom: search field (y 137), list (162), divider (382), editor (383), backlinks strip below the editor when shown; the divider drags. |
| W-3 | pass | From the Finder, Ctrl-Cmd-N brought the window forward with the query selected in the focused field. Recording Ctrl-Cmd-M in Preferences moved the hotkey at once: the new one activated the app, the old one no longer did (the Finder took it as New Folder with Selection). No Accessibility prompt. |
| W-4 | pass | Cmd-W closed the window and the process exited within 100 ms, edits written first (E-4). |

### 12. Preferences

| ID   | Result | Notes |
|------|--------|-------|
| PR-1 | pass | The window holds exactly three rows: Library folder (path, Choose…), Editor font (family pop-up, size, stepper), Global hotkey (recorder). macOS titles the menu item Settings…. |

### 13. Performance

| ID   | Result | Notes |
|------|--------|-------|
| PF-1 | gate | `LaunchPerfTests`. By hand: a 2-note library listed 504 ms after the process was spawned, AX polling included. |
| PF-2 | gate | `ListPerfTests`, `IndexPerfTests`. By hand: no visible lag typing into 1,516 notes. |
| PF-3 | gate | `EditorPerfTests`. |
| PF-4 | gate | `IndexPerfTests`. |
| PF-5 | gate | `IndexPerfTests`. |
| PF-6 | n/a by hand | Not observable from outside; the one main-thread stall found is K-6's (M5.6a). |
| PF-7 | n/a by hand | At 1,516 notes titles and bodies arrive too close together to see; `LaunchPerfTests` measures the titles-first publish. |

### Observations outside the spec

- Two spaces typed in the search field become ". " when macOS's "Add period with
  double-space" is on; it is the system's text replacement, not the app's.
- The default hotkey Ctrl-Cmd-N is also the Finder's New Folder with Selection. While MDNotes
  runs it wins, as W-3 intends; a user who changes it gives the combination back to the Finder.

## How to run the pass

1. `scripts/bundle.sh`, then copy the library to a scratch folder and launch
   `build/MDNotes.app/Contents/MacOS/MDNotes -LibraryRoot <copy>` so the stored preference is
   not touched. Give the terminal Accessibility access if System Events asks.
2. Drive the window with `osascript` System Events (`keystroke`, `key code`, the table's rows,
   the editor's `AXValue`) and read styling with `AXAttributedStringForRange` on the editor.
   Read files with `cat`/`stat` to confirm what the app wrote.
3. Record every ID here, quit the app (Cmd-Q; since v2 Cmd-W only hides, W-4), and remove
   `defaults delete dev.laurenkt.mdnotes` if the pass launched without `-LibraryRoot`.
4. If another MDNotes is already running (the human's, on the real library), System Events
   resolves both by name and picks the wrong one: drive the pass instance through the AX API
   by pid instead, give it its own hotkey in the argument domain (`-GlobalHotKeyKeyCode`,
   `-GlobalHotKeyModifiers`) so the two do not fight over one combination, and export the
   defaults domain first (`defaults export`) so it can be put back afterwards instead of deleted.
