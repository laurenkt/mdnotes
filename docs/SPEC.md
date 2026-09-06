# MDNotes Specification

Normative. Every requirement has an ID. Tasks in `PLAN.md` reference these IDs, and tests
name the ID they cover. If behaviour here is ambiguous, do not guess: write the question in
`QUESTIONS.md` and move to another task. Change this file only through an ADR.

MDNotes is a native macOS reimplementation of the Notational Velocity / nvALT workflow over a
folder of markdown files. Its one non-negotiable property is that it feels instant.

## 1. Platform

- **P-1** macOS 26.0 or later. Swift 6 language mode, strict concurrency, warnings are errors.
- **P-2** AppKit, constructed entirely in code. No storyboards, xibs, or SwiftUI (ADR-0001).
- **P-3** Pure SwiftPM package. No `.xcodeproj` is ever created or committed (ADR-0002).
- **P-4** Not sandboxed. Ad-hoc signed. Personal use.
- **P-5** Three modules: `MDNotesCore` (Foundation only, no AppKit), `MDNotesApp` (AppKit,
  headlessly testable), `MDNotes` (a `main.swift` and nothing else).

## 2. Library

- **L-1** The library is one root folder. Default `~/Documents/MDnotes`; changeable in
  Preferences; remembered across launches.
- **L-2** Notes are files with the `.md` extension, found by walking the root recursively.
- **L-3** These are skipped entirely: hidden files and folders (leading `.`), the `Trash/` folder,
  the `.obsidian/` folder, and the `templates/` folder (reserved for v2).
- **L-4** A note's identity is its path relative to the root with `/` separators, including
  extension, e.g. `daily/2026/06-sunday.md`.
- **L-5** A note's title is its filename without the `.md` extension. There is no other title source.
- **L-6** Non-`.md` files (images, txt, json) are never listed as notes but may be link targets.
- **L-7** The root is iCloud-synced. A file may be an evicted placeholder. The indexer must never
  block the main thread waiting for a download; an unavailable file is indexed by title only and
  its body indexed when it becomes readable.
- **L-8** Files are read and written as UTF-8. A file that fails UTF-8 decoding is listed by title,
  shown read-only with a notice, and never written back.

## 3. Search and list

- **S-1** One search field at the top of the window. It is both the search box and the new-note box.
- **S-2** The query is split on whitespace into words. A note matches when every word is a
  case-insensitive substring of the title or the body. Order of words is irrelevant.
- **S-3** Result order: notes whose title contains all words first, then the rest; within each
  group, most recently modified first. Empty query lists all notes by modified date.
- **S-4** `#tag` is matched as an ordinary word. No special tag syntax in the query.
- **S-5** The list updates on every keystroke. See performance budget PF-2.
- **S-6** A list row shows title, modified date, and a single-line body snippet. Rows are
  uniform height.
- **S-7** Keyboard flow: Down arrow from the search field selects the first row. Up from the first
  row returns to the search field. Escape clears the query and returns to the search field.
  Cmd-L focuses the search field from anywhere.
- **S-8** Selecting a row loads the note into the editor without stealing focus from the list.
  Tab or Enter on a selected row moves focus to the editor.

## 4. Creation

- **C-1** Enter in the search field with a non-empty query: if a note's title equals the query
  (case-insensitive), open it and focus the editor. Otherwise create it.
- **C-2** Creation writes `<query>.md` at the root. If the query contains `/`, the segments before
  the last `/` are folders under the root, created as needed. The query is trimmed.
- **C-3** Characters illegal in filenames (`:` and `/` within a segment, NUL) are rejected with an
  inline message; nothing is created.
- **C-4** After creation the new note is selected, the editor is focused and empty, and the search
  field keeps the query so the list still shows the new note.

## 5. Editor

- **E-1** `NSTextView` backed by TextKit. Plain text model; the file on disk is exactly the text
  in the view.
- **E-2** Light syntax styling only: ATX headings, `[[wikilinks]]`, `#tags`, fenced and inline code.
  Styling never changes text content or layout metrics beyond font weight/colour.
- **E-3** Re-styling after an edit is scoped to the affected paragraphs, not the whole document.
  See PF-3.
- **E-4** Autosave: write 300 ms after the last edit, and immediately on note switch, window
  focus loss, and quit. No Save menu item.
- **E-5** Writes are atomic: temp file in the same directory, then rename. Modification date
  reflects the write.
- **E-6** The app ignores file-system events caused by its own writes.
- **E-7** Undo works per note and survives switching away and back within a session.
- **E-8** Font family and size are preferences. Default: system monospaced, 13 pt.

## 6. External changes

- **X-1** An FSEvents watcher covers the root. Additions, deletions, renames and modifications
  update the index and list without user action, within 500 ms.
- **X-2** If the open note changes on disk and the editor has no unsaved edits, the editor
  reloads the new content, preserving selection where possible.
- **X-3** If the open note changes on disk while the editor has unsaved edits, the editor's text
  wins: it is written over the disk version at the next autosave. No conflict copy is made.
- **X-4** If the open note is deleted on disk, the editor is cleared and the list selection moves
  to the next row. Unsaved edits are kept in the editor buffer and re-saved only if the user
  types again, which recreates the file.

## 7. Rename and delete

- **R-1** Double-click on a title, or Cmd-R with a row selected, edits the title inline in the list.
- **R-2** Committing a rename renames the file within its folder. Title collisions and illegal
  characters are rejected inline.
- **R-3** After a rename, every `[[old title]]` or `[[old/path]]` in other notes that resolved to
  this note is rewritten to reference the new title. Each affected file is written atomically.
  The rewrite is logged to stderr with file count.
- **D-1** Cmd-Delete with a row selected moves the file to the macOS Trash via
  `NSWorkspace.recycle`. No confirmation. Selection moves to the next row.
- **D-2** A rename or delete is reflected in the list immediately, not only after the watcher fires.

## 8. Links

- **K-1** A wikilink is `[[target]]` or `[[target|label]]`. Target is a title or a relative path
  without extension. `![[target]]` is an embed and is treated as a link to a non-note file.
- **K-2** Resolution: if exactly one note has that title, that is the target. If several do, the
  target must be given as a relative path (`[[daily/2026/foo]]`); a bare ambiguous title resolves
  to the most recently modified candidate and is styled as ambiguous.
- **K-3** Cmd-click, or Cmd-Enter with the caret inside a link, opens the target. If no note
  resolves, one is created at the root with that title (C-2 rules) and opened.
- **K-4** Typing `[[` opens a completion popover listing titles matched with the S-2 rules on the
  text typed since `[[`. Enter inserts the title and closing `]]`. Escape dismisses.
- **K-5** A link index maps each note to its outgoing targets and each target to its incoming
  notes. It is updated incrementally on every save and watcher event.
- **K-6** Backlinks strip: a collapsible bar below the editor lists titles of notes linking to
  the open note. Clicking one opens it. Hidden when there are none. Collapse state is remembered.

## 9. Tags

- **T-1** A tag is `#` followed by one or more of `[A-Za-z0-9_/-]`, preceded by start of line or
  whitespace, and not inside a code span or fenced block. Trailing punctuation is excluded.
- **T-2** A tag index maps tags to notes and is maintained with the link index (K-5).
- **T-3** Typing `#` in the editor opens a completion popover of known tags, filtered by prefix.
- **T-4** Clicking a tag in the editor (plain click) sets the search field to that tag.

## 10. Images

- **I-1** Pasting or dropping image data or an image file into the editor writes it to `i/`
  under the root as `<yyyyMMdd-HHmmss>.<ext>` and inserts `![[<name>]]` at the caret.
- **I-2** Cmd-click on an image link opens the file with the default application.
- **I-3** No inline rendering of images in v1.

## 11. Window and hotkey

- **W-1** Exactly one window. Frame and split position persist across launches.
- **W-2** Layout: search field across the top, note list below it, editor below the list,
  backlinks strip below the editor. The list/editor split is draggable.
- **W-3** A global hotkey (default Ctrl-Cmd-N, changeable in Preferences) activates the app,
  brings the window forward, focuses the search field and selects its contents. Implemented
  with Carbon `RegisterEventHotKey`; no Accessibility permission required.
- **W-4** Closing the window quits the app.

## 12. Preferences

- **PR-1** A Preferences window with: library folder, editor font, global hotkey. Nothing else in v1.

## 13. Performance

Budgets are measured against the synthetic library from `MDNotesTestSupport` at 20,000 notes
(five of them 1 MB), in release builds, on the development machine. They are enforced by tests
whose class names end in `PerfTests`; `scripts/check.sh full` runs them and a failure blocks
the commit. Constants live in `PerfGate.Budget`; change them here first, then there.

| ID   | Metric                                                     | Budget |
|------|------------------------------------------------------------|--------|
| PF-1 | Cold launch to window interactive with list populated       | 300 ms |
| PF-2 | Search field keystroke to list reload complete              | 16 ms  |
| PF-3 | Editor keystroke to re-styled redraw on a 1 MB note         | 8 ms   |
| PF-4 | Full index build of 20k notes, background, UI responsive    | 2 s    |
| PF-5 | Memory after full index of 20k notes                       | 200 MB |

- **PF-6** All file I/O and indexing happens off the main thread. The main thread only touches
  in-memory index snapshots.
- **PF-7** The index is rebuilt from disk on launch; no on-disk cache in v1. PF-1 therefore
  requires the list to become interactive before indexing completes, populated progressively.

## 14. Out of scope for v1

Templates and daily notes (nested folders are supported so this can come later), rendered
markdown preview, tag browser sidebar, multiple windows, sandboxing, notarisation, sync
of any kind beyond what the file system does, plugins, encryption, non-`.md` note types.
