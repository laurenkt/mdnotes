# MDNotes Specification

Normative. Every requirement has an ID. Tasks in `PLAN.md` reference these IDs, and tests
name the ID they cover. If behaviour here is ambiguous, do not guess: write the question in
`QUESTIONS.md` and move to another task. Change this file only through an ADR.

MDNotes is a native macOS reimplementation of the Notational Velocity / nvALT workflow over a
folder of markdown files. Its one non-negotiable property is that it feels instant.

Version 2 (ADR-0009 to ADR-0015, 2026-09-07) amends this document in place. Rules marked
*(v2)* are new or changed; superseded v1 text is removed rather than struck through.

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
  the `.obsidian/` folder, and the `templates/` folder (section 15).
- **L-4** A note's identity is its path relative to the root with `/` separators, including
  extension, e.g. `daily/2026/06-sunday.md`.
- **L-5** A note's title is its filename without the `.md` extension. There is no other title source.
- **L-6** Non-`.md` files (images, txt, json) are never listed as notes but may be link targets.
- **L-7** The root is iCloud-synced. A file may be an evicted placeholder. The indexer must never
  block the main thread waiting for a download; an unavailable file is indexed by title only and
  its body indexed when it becomes readable.
- **L-8** Files are read and written as UTF-8. A file that fails UTF-8 decoding is listed by title,
  shown read-only with a notice, and never written back.
- **L-9** *(v2)* Proactive download (ADR-0009). At launch, after every full scan, and on every
  watcher event, the app requests a download (`startDownloadingUbiquitousItem`) for every note
  that is dataless, off the main thread, at most once per note per 60 s. When a downloaded note
  becomes dataless again (re-eviction), the request is repeated. The body is indexed as soon as
  the file becomes readable (L-7). There is no on-disk body cache (PF-7 stands).
- **L-10** *(v2)* Eviction bar (ADR-0009). While one or more notes are dataless, a thin bar
  directly under the search field reads `N notes not downloaded from iCloud. Search is
  incomplete.` If the boot volume has under 2 GB free it appends `· 985 MB free` and the bar
  carries an `Open Storage Settings` button (`x-apple.systempreferences:com.apple.settings.Storage`).
  The bar is not dismissable and disappears within 2 s of the last note becoming readable. It
  is not shown during the first scan; only once the scan has completed and dataless notes remain.

## 3. Search and list

- **S-1** One search field at the top of the window. It is both the search box and the new-note box.
- **S-2** The query is split on whitespace into words. A note matches when every word is a
  case-insensitive substring of the title or the body. Order of words is irrelevant. A word
  that contains `/` also matches as a substring of the note's relative path without `.md`
  (`daily/foo` matches `daily/foo.md`); such a path match counts as a title match for S-3
  (ADR-0008).
- **S-3** Result order: notes whose title contains all words first, then the rest; within each
  group, most recently modified first. Empty query lists all notes by modified date.
- **S-4** `#tag` is matched as an ordinary word. No special tag syntax in the query.
- **S-5** The list updates on every keystroke. See performance budget PF-2.
- **S-6** A list row shows title, modified date, and a single-line body snippet. Rows are
  uniform height. *(v2)* The snippet is plain text: heading markers, wikilink brackets, embed
  syntax, code fences and emphasis markers are stripped; a `![[image]]` embed contributes
  nothing to the snippet.
- **S-9** *(v2)* Date format, Notes style: `Today 11:53` and `Yesterday 09:10` (time in the
  user's locale format); a weekday name (`Mon`) within the last six days; `3 Sep` within the
  current year; `3 Sep 2025` otherwise. Relative words refresh on day change and on the list
  becoming visible.
- **S-10** *(v2)* The date sits right-aligned on the title line and is never truncated. The
  title yields width to it and truncates with an ellipsis. The date label is given its
  intrinsic width unconditionally.
- **S-11** *(v2)* A note whose body contains an image embed (K-1, `![[...]]`) that resolves to
  an existing image file shows a 34 pt square thumbnail of the first such image at the right
  end of the row. Clicking it selects the note like any other part of the row. Thumbnails are
  produced off the main thread, cached by path and modification date, and a row is drawn
  without one until it is ready (PF-8).
- **S-7** Keyboard flow: Down arrow from the search field selects the first row. Up from the first
  row returns to the search field. Escape clears the query and returns to the search field.
  Cmd-L focuses the search field from anywhere.
- **S-8** Selecting a row loads the note into the editor without stealing focus from the list.
  Tab or Enter on a selected row moves focus to the editor.
- **S-12** *(ADR-0021)* Keyboard focus order: Tab in the search field moves focus to the list,
  selecting the first row if none is selected (S-7), and does nothing when the list is empty.
  Tab in the list moves to the editor (S-8). In the editor Tab inserts a tab. Shift-Tab moves
  back: editor to list, list to search field; in the search field it does nothing. Ctrl-Tab in
  the editor moves focus to the search field.

## 4. Creation

- **C-1** Enter in the search field with a non-empty query: if a note's title, or its relative
  path without `.md`, equals the query (case-insensitive), open it and focus the editor.
  Otherwise create it. An exact-path match wins over other notes with the same title; among
  title-only matches the most recently modified opens (ADR-0008).
- **C-2** Creation writes `<query>.md` at the root. If the query contains `/`, the segments before
  the last `/` are folders under the root, created as needed. The query is trimmed.
- **C-3** Characters illegal in filenames (`:` and `/` within a segment, NUL) are rejected with an
  inline message; nothing is created. So are queries that cannot make a listable note: an
  empty segment (`a//b`, `/a`, `a/`), a `.` or `..` segment, a segment starting with `.`, and
  a first segment of `Trash` or `templates` (L-3, ADR-0008).
- **C-4** After creation the new note is selected, the editor is focused and empty, and the search
  field keeps the query so the list still shows the new note.

## 5. Editor

- **E-1** `NSTextView` backed by TextKit. Plain text model; the file on disk is exactly the text
  in the view.
- **E-2** *(v3, ADR-0019)* Styling never changes the text: every markdown marker stays
  visible and editable. Styling may change font traits, size and family, colour,
  underline, paragraph indents and background drawing as section 17 specifies; the file on
  disk is exactly the text in the view (E-1).
- **E-3** Re-styling after an edit is scoped to the affected paragraphs, not the whole document.
  See PF-3.
- **E-4** Autosave: write 300 ms after the last edit, and immediately on note switch, window
  focus loss, and quit. No Save menu item.
- **E-5** Writes are atomic: temp file in the same directory, then rename. Modification date
  reflects the write.
- **E-6** The app ignores file-system events caused by its own writes.
- **E-7** Undo works per note and survives switching away and back within a session.
- **E-8** *(v2, ADR-0010)* Prose is set in the system font (`NSFont.systemFont`); inline and
  fenced code in the system monospaced font (`NSFont.monospacedSystemFont`) at the same size.
  There is no font family preference; the v1 `EditorFontFamily` default is deleted on first
  launch of v2. Size is 13 pt by default, adjustable with Cmd-plus, Cmd-minus and Cmd-0 (View
  menu: Bigger, Smaller, Actual Size) between 9 and 36 pt, persisted in `EditorFontSize`.
- **E-9** *(v2, ADR-0012)* An image embed `![[target]]` whose target resolves to an existing
  image file is followed, on the line directly below it, by a thumbnail attachment of that
  image. *(ADR-0021)* It is drawn aspect-locked at the largest size that is no bigger than the
  image's own point size (pixels over its DPI scale), the width of the text area excluding
  margins, and the height of the editor's visible area; it is never scaled up, and it refits
  when the editor is resized or the font size changes. The embed text stays visible and
  editable; the attachment is display-only, is not part of the file, is excluded from copy,
  undo and search, and disappears when the embed text is edited so that it no longer resolves.
  Clicking the thumbnail opens the image with the default application. Thumbnails load off the
  main thread and are cached (PF-8); the line reserves its height only once the image size is
  known, so typing above or below is never blocked.

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
- **R-4** *(ADR-0021)* Right-clicking a note row opens a context menu that acts on the clicked
  row without changing the selection: Rename (inline edit of that row, R-1 to R-3), Show in
  Finder (reveals the file, selected, in Finder), Copy Link (puts `[[Title]]` on the
  pasteboard as plain text, or `[[relative/path]]` without `.md` when the title is ambiguous,
  K-2), a separator, and Move to Trash (D-1; the selection moves to the next row only if the
  trashed row was selected). Template rows (TP-5) have no menu.
- **D-1** Cmd-Delete with a row selected moves the file to the macOS Trash via
  `NSWorkspace.recycle`. No confirmation. Selection moves to the next row.
- **D-2** A rename or delete is reflected in the list immediately, not only after the watcher fires.

## 8. Links

- **K-1** A wikilink is `[[target]]` or `[[target|label]]`. Target is a title or a relative path
  without extension. `![[target]]` is an embed and is treated as a link to a non-note file.
- **K-2** Resolution: if exactly one note has that title, that is the target. If several do, the
  target must be given as a relative path (`[[daily/2026/foo]]`); a bare ambiguous title resolves
  to the most recently modified candidate and is styled as ambiguous.
- **K-3** *(v3)* Cmd-click, or Cmd-Enter with the caret inside a link, opens the target. For a
  wikilink with no resolving note, one is created at the root with that title (C-2 rules) and
  opened. For a standard link, image `![alt](url)` *(ADR-0021)*, autolink or bare URL (ED-1)
  the URL opens with the default application; a relative image URL resolves against the
  note's folder.
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
- **I-3** *(v2)* Inline thumbnails in the editor per E-9; row thumbnails per S-11. Nothing
  else is rendered inline.

## 11. Window and hotkey

- **W-1** Exactly one window. Frame and split position persist across launches.
- **W-2** Layout: search field across the top, note list below it, editor below the list,
  backlinks strip below the editor. The list/editor split is draggable.
- **W-3** *(v2, ADR-0011)* A global hotkey (default Ctrl-Cmd-N, changeable in Settings)
  toggles the window: if the window is visible and the app is active, the window is hidden
  (ordered out, app stays running); otherwise the app activates, the window is shown on the
  current Space, and the search field is focused with its contents selected. Implemented with
  Carbon `RegisterEventHotKey`; no Accessibility permission required.
- **W-4** *(v2, ADR-0011)* Closing the window (Cmd-W or the close button) hides it; it does not
  quit. Clicking the Dock icon or pressing the hotkey shows it again. Cmd-Q quits.
- **W-5** *(v2, ADR-0011)* The window level is always `.floating` and its collection behaviour
  is `moveToActiveSpace`, so it stays above other apps' windows whenever visible and follows
  the user between Spaces. Sheets, popovers and the completion popup must still appear above it.
- **W-6** *(v2, ADR-0013)* Visual design follows direction B of the design canvas: a standard
  title bar with the window title, then the search field in the content area with 8 pt vertical
  and 10 pt horizontal insets on a window-background strip, a hairline separator (`separatorColor`)
  beneath it, then the list, the draggable split, the editor and the backlinks strip. The
  search field is a standard `NSSearchField` with its default bezel; no control is custom-drawn
  and no view sets a colour that is not a semantic `NSColor`.

## 12. Settings

- **PR-1** *(v2, ADR-0013)* The window is titled `Settings`, opened by `Settings…` (Cmd-comma)
  in the app menu, fixed size, non-resizable, non-miniaturisable, one pane, no toolbar. Its
  content is an `NSGridView` form with right-aligned captions and 20 pt margins: `Notes folder`
  with the path and a `Choose…` button; `Global shortcut` with the recorder. Nothing else.

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
- **PF-7** The index is rebuilt from disk on launch; no on-disk cache. PF-1 therefore
  requires the list to become interactive before indexing completes, populated progressively.
- **PF-1a** *(ADR-0020)* PF-1 measures the app's own launch path. `LaunchPerfTests` warms the
  OS's Writing Tools soft-link (`NSWritingToolsCoordinator.isWritingToolsAvailable`) once
  before the first clock starts, because macOS 27.0 charges every process 170 to 250 ms of
  main-thread class registration the first time a text field takes focus (S-1). The user's
  real first launch pays that on top of the PF-1 number.
- **PF-8** *(v2)* Thumbnail generation (S-11, E-9) runs on a background queue with at most two
  concurrent jobs, uses `QLThumbnailGenerator` or `CGImageSource` downsampling, and caches
  results in memory keyed by path and modification date (bounded, LRU, 50 MB). The main thread
  only draws cached images. PF-2 and PF-3 are measured with thumbnails enabled on a synthetic
  library where 10 % of notes embed an image.
- **PF-9** *(v3)* Converting 200 KB of pasted HTML to markdown (ED-13) completes on the main
  thread in under 100 ms. Enforced by `PastePerfTests`.

## 14. Out of scope

Rendered markdown preview, tag browser sidebar, multiple windows, sandboxing, notarisation,
sync of any kind beyond what the file system does, plugins, encryption, non-`.md` note types,
an on-disk body cache.

## 15. Templates *(v2, ADR-0014)*

- **TP-1** A template is any `.md` file directly inside `templates/` under the root. Its name
  is its filename without extension. Templates are never listed as notes or searched (L-3).
- **TP-2** A template may begin with a header block: a first line `---`, one or more
  `key: value` lines, and a closing `---`. Recognised keys: `path` (required for the template
  to be usable). Unknown keys are ignored. A template without a header, or without `path`, is
  listed but refused with an inline message naming the problem.
- **TP-3** Tokens, replaced at creation time, in both `path` and the body:
  `{{date:FORMAT}}` where FORMAT is a Unicode date format pattern (`YYYY`, `MM`, `MMMM`, `DD`,
  `dddd`, `HH`, `mm`), evaluated in the local time zone; `{{title}}`, the title words typed
  after the template name (TP-5); `{{cursor}}`, body only, marks the caret position and is
  removed. An unknown token is left as literal text.
- **TP-4** The expanded `path` is a relative path without extension, subject to C-3 rules. If
  `<path>.md` exists, it is opened and nothing is written. Otherwise folders are created as
  needed and the file is written with the expanded body, then opened with the caret at
  `{{cursor}}` or at the end.
- **TP-5** A search-field query whose first character is `@` is template mode. The word after
  `@` filters templates by name with the S-2 rules; the list shows matching templates (name,
  and the expanded `path` as the snippet) instead of notes. Enter acts on the selected
  template, or the first, with the remaining words of the query as `{{title}}`. If the path
  needs `{{title}}` and none was given, an inline message asks for one and nothing is created.
  `@` alone lists all templates. Escape leaves template mode as it clears any query.
- **TP-6** `File > New from Template` lists templates by name; choosing one behaves as TP-5
  with no title, prompting inline in the search field when `{{title}}` is required.
- **TP-7** The template list updates with the watcher (X-1) like notes do.
- **TP-8** A daily note is not a feature. It is a template such as
  `path: daily/{{date:YYYY}}/{{date:MM-MMMM}}/{{date:DD-dddd}}`, reached by `@daily`.

## 16. Visual verification *(v2, ADR-0015)*

- **V-1** Every task that changes what a window looks like renders the affected window to a
  PNG in `build/snapshots/` from its smoke test (`NSView.bitmapImageRepForCachingDisplay` on
  the real view hierarchy at 2x, light and dark appearance), and the implementing agent looks
  at that PNG and compares it against W-6, PR-1 and the design canvas before committing. The
  commit message states what was checked. Snapshots are build products, not committed.

## 17. Editor markdown rendering *(v3, ADR-0019)*

The editor is a halfway point between editor and preview: markdown structure is styled in
place, and every marker that produced the styling stays visible and editable.

- **ED-1** `MarkdownScanner` recognises, outside code spans and fenced blocks: ATX headings;
  setext headings (ED-9); emphasis `**x**`, `__x__` (bold), `*x*`, `_x_` (italic; underscore
  forms only at word boundaries), `~~x~~` (strikethrough); wikilinks and embeds (K-1);
  standard links `[text](url)`, images `![alt](url)`, autolinks `<url>` and bare `http(s)://`
  URLs; list items `- `, `* `, `+ `, `<n>. ` with nesting by two leading spaces per level;
  task items `- [ ]` and `- [x]`; blockquote prefixes `> ` (nesting by repetition); pipe-table
  rows and separator rows; thematic breaks (ED-8); inline and fenced code. Each token carries
  its marker ranges and its content range separately.
- **ED-2** Markers (`#`, `*`, `_`, `~`, `>`, link brackets and URLs, table pipes, setext
  underlines) are shown in tertiary label colour at the surrounding size. *(ADR-0021)* List
  markers (`-`, `*`, `+`, `<n>.`) and a thematic break's typed characters are shown in
  secondary label colour at the surrounding size, so bullets, numbers and rules stay legible.
- **ED-3** Emphasis content gets the bold, italic or strikethrough trait. Never inside code.
- **ED-4** Heading content is bold at 1.4, 1.25, 1.1 and 1.0 times the body size for levels
  1, 2, 3 and 4 or more, following the Cmd-plus size (E-8). Re-styling stays paragraph-scoped.
- **ED-5** List items use a hanging indent equal to the marker width plus one nesting indent
  per level, so wrapped lines align under the item text. Markers dimmed (ED-2).
- **ED-6** Task boxes `[ ]` and `[x]` are set in the monospaced font at body size so both
  have the same width. Done items' content is in secondary label colour. A plain click on the
  box toggles the character between space and `x` as a single undoable edit, autosaved (E-4).
- **ED-7** Blockquote paragraphs get a hanging indent per `>` level with the markers dimmed.
  Pipe-table lines are set in the monospaced font; the separator row is dimmed.
- **ED-8** A thematic break is a line of three or more `-`, `*` or `_` (spaces allowed) that
  follows a blank line or starts the document, per CommonMark. The typed characters stay
  text, in secondary label colour (ED-2). *(ADR-0021)* Faded hyphens in quaternary label
  colour are drawn on the rule's baseline across the full width of the editor view, margins
  included: from the view's leading edge to the typed characters, and from their end to the
  view's trailing edge. The extension is not text: it cannot be selected, copied or reached by
  the caret.
- **ED-9** A line of `=` or `-` directly under a paragraph line is a setext heading underline
  (level 1 or 2) per CommonMark, styled per ED-4 with the underline dimmed. This means `---`
  under text is a heading, not a rule.
- **ED-10** Sections between thematic breaks alternate backgrounds: the first section on the
  text background, the next on a subtle system fill (about 4 % label colour, adapting to
  appearance), and so on. *(ADR-0021)* A section boundary is the vertical centre of its rule's
  drawn hyphens, so a band runs from one rule's hyphen midline to the next rule's (the last
  band to the bottom of the text). Bands span the full editor width including margins and are
  drawn for the visible rect only.
- **ED-11** Wikilinks whose target resolves are in link colour; those with no resolving note
  keep link colour with a dotted underline and the tooltip "Cmd-click to create"; ambiguous
  targets stay per K-2. Standard links, autolinks and bare URLs are styled as links.
- **ED-12** While Cmd is held and the pointer is over any link (wikilink, embed, standard link,
  image `![alt](url)`, autolink, bare URL), the cursor is the pointing hand and the link shows
  a solid underline. Released Cmd restores the I-beam. *(ADR-0021)* With no modifier held, the
  pointer over an inline thumbnail (E-9), a tag (T-4) or a task box (ED-6) is the pointing
  hand, since a plain click acts on them; no underline is shown. This is the cursor the user
  sees in the running app: the text view's own cursor handling must not restore the I-beam
  while either holds.
- **ED-13** Paste conversion: when the pasteboard carries HTML, it is converted to markdown by
  walking the parsed document: headings, bold, italic, strikethrough, links, bulleted and
  numbered lists with nesting, task items, inline code and code blocks, blockquotes, tables as
  pipe tables, images as `![alt](url)`, paragraphs and line breaks. Everything else (fonts,
  colours, sizes, spans, scripts) contributes only its text. With no HTML but RTF, the same
  set is derived from the attributed string. With neither, plain text is pasted.
- **ED-14** Cmd-Shift-V pastes the plain-text form regardless of pasteboard contents. Image
  data on the pasteboard is still handled per I-1. Conversion is bounded by PF-9.
- **ED-15** Out of scope: hiding markers, WYSIWYG editing, real checkbox controls, rendered
  preview, table editing aids, downloading remote images, CommonMark edge cases beyond ED-1.
- **ED-16** *(ADR-0021)* With a non-empty selection, the editor's context menu offers Quote and
  Code Block above the standard items. Both act on whole lines: every line the selection
  touches. Quote prefixes each with `> `; if every touched non-blank line already starts with
  `> `, it removes that prefix instead. Code Block puts a ```` ``` ```` fence line before the
  first touched line and after the last; if the touched lines are a fenced block or lie inside
  one, it removes that block's fences instead. Each is one undoable edit, autosaved (E-4).
  Other formatting transforms are out of scope.
- **ED-17** *(ADR-0021)* Return in the editor inserts a line break followed by the leading
  spaces and tabs of the line the caret is on (those before the caret, if it is within them),
  as one undoable edit. List markers, blockquote prefixes and task boxes are not continued.
