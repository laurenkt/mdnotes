# Acceptance checklist

One line per spec ID in `SPEC.md`, checked by hand against the built app. A discrepancy
becomes a task in `PLAN.md`; the task IDs are named in the notes. Re-run this pass before a
release tag; the setup and the driving scripts it needs are described at the end.

Result key: **pass**, **fail** (task named), **gate** (enforced by `scripts/check.sh full`,
not checkable by hand), **n/a by hand** (why), **blocked** (question in `QUESTIONS.md`).

## Pass of 2026-09-16 (M10.15, v6)

Build: debug `swift test` via `scripts/check.sh quick` at commit 900fd81 (code as of aa7d07f,
M10.14), macOS 27.0 (26A428): 904 tests green (403 core, 501 app), the 9 perf gates skipped in
the debug run and run by the full gate at commit. No app was launched, as in the M7.6 to M9.7
passes: the human's instance runs on the real library, so the editor was inspected through the
nine V-1 snapshot pairs the M10 smoke tests write (`build/snapshots/editor-{markers,headings,
lists,quotes-tables,links,tasks,rules,bands,link-hover}-{light,dark}.png`, 1600 × 1200 px for an
800 × 600 pt content view, opened and compared against W-6, E-8 and direction B on the ADR-0013
canvas, with band, rule and hairline pixels sampled by a script over `NSBitmapImageRep.colorAt`
and the editor's frames printed by a throwaway headless test at the same size, deleted before
the commit); the scanner and the HTML converter by hand from a probe compiled against the
`MDNotesCore` sources (`swiftc -swift-version 6 Sources/MDNotesCore/*.swift main.swift`); and
the click, hover, opening and paste paths, which a snapshot cannot drive, through their tests,
which send real key, mouse and `flagsChanged` events and read a private pasteboard
(`TaskItemSmokeTests`, `LinkHoverSmokeTests`, `LinkOpeningSmokeTests`, `PasteSmokeTests`,
`RTFToMarkdownTests`, `HTMLToMarkdownTests`, `MarkdownScannerTests`, `EditorStylingSmokeTests`,
`RuleExtensionSmokeTests`, `SectionBandSmokeTests`, `MenuSmokeTests`). Scope: ED-1 to ED-15,
PF-9, the E-2 and K-3 amendments ADR-0019 made, and V-1. Every other ID stands as recorded in
the v5 pass and the whole-of-v2 roll-up.

Summary: 19 IDs; 17 pass, 1 fail (M10.14a, ED-10), 1 gate (PF-9). One task was added; four
observations outside the spec are recorded after the table.

| ID    | Result | Notes |
|-------|--------|-------|
| ED-1  | pass | Probe over one line holding every inline construct: `**bold**` and `__bold__` bold, `*it*` and `_it_` italic, each with its delimiter runs as markers and the word as content; `snake_case_word` no emphasis (underscores only at word boundaries) and `2*3*4` an italic `3`, as CommonMark's flanking rules have it; `~~gone~~` strikethrough; `[[Note]]`, `[[a\|b]]` (target `a`, label `b`) and `![[i.png]]` (an embed, `![[` the marker); `#tag`; a code span whose `*y*` yields nothing; `[t](https://e.com)` with `[` and `](https://e.com)` as markers and `t` as content; `![a](…)` an image; `<https://e.org>` an autolink with the brackets as markers; `https://e.net/p` a bare URL ending before the full stop. Blocks: `# H1` (marker `#`); setext levels 1 and 2 spanning the text line and its underline (ED-9); `- a`, `  - b`, `    1. c` at levels 0, 1 and 2 with `- ` and `1. ` as markers; `- [ ] open` and `- [x] done` each a list item plus a task box whose markers are the brackets and content the space or the `x`; `+ ` and `* ` items; `> q1` level 1 and `> > q2` level 2 with each `>` a marker; a table row, a separator row and a data row with the pipes as markers; `---` after a blank line a thematic break; a fence whose `# not a heading **nor bold**` yields nothing. The 22 `testED1_*` (one per construct) green. |
| ED-2  | pass | Every snapshot, light and dark: `**`, `*`, `~~`, `[[` and `]]`, `[` and `](url)`, `<` and `>`, the `#` runs, `-`, `1.` and `10.`, `>`, the table pipes and the setext `====` and `----` are in the faint grey of `tertiaryLabelColor` (the only marker colour in `EditorStyler`), at the surrounding size: the `#` of `# Level one heading` and the `====` under `Setext level one` at the heading's size, the pipes at the mono size, the `**` inside a table cell in the mono font. The exceptions ED-2 does not list keep their own colours: the tag's `#` purple with its name, code backticks in the code colour, the task box's brackets in label colour (`dimsMarkers`). |
| ED-3  | pass | `editor-markers`: **bold**, *italic* and ~~struck~~ traits on the content only, the delimiters plain; `**bold**` inside a table cell and a done item likewise; nothing inside `` `code` `` (the probe's code span yields no emphasis token, `testED3_*` and `testK3_linksInCodeSpansAndFencedBlocksAreNotLinks` show the styler and the opener agree). |
| ED-4  | pass | `editor-headings`: `# Level one heading` bold at 18.2 pt (13 × 1.4; the test asserts the size), `##` at 16.25, `###` at 14.3, `####` at 13 bold, the setext pair the same as levels 1 and 2 with the underline dimmed at the heading's size; body text, `**bold**` and `` `code` `` beside them at 13 pt. Bigger, Smaller and Actual Size move every level with the base size, and a heading edit lays out no more than a plain keystroke does (`testED4_*` with an `NSLayoutManagerDelegate` recorder). |
| ED-5  | pass | `editor-lists`: the wrapped second line of each bullet, nested (two spaces per level) and ordered item starts under the first word of the item text, `10.` hanging a little further than `2.`, the task item hanging past its box; the paragraph after the lists wraps to the leading edge; markers dimmed. `testED5_*`: head indent per level for bullet, ordered and task items, a wrapped line's x-origin equal to the item text's, indents following the font size, a typed marker gaining the indent and the line after an item not. |
| ED-6  | pass | `editor-tasks`: `[ ]` and `[x]` in the mono font at 13 pt, `Buy milk` and `Post the letter` starting at the same x after them, after `-` and after `1.`/`2.` alike; the plain paragraph's `[x]` left in prose; a done item's content in secondary label colour through its wrap, an open item's in label colour. The toggle, which a snapshot cannot drive: `testED6_*` send real mouse-down and mouse-up at each of the box's three characters through `EditorTextView` over a real library, the character flips between space and `x`, the caret and focus stay, a click elsewhere places the caret, the toggle is one undo step apart from typing and autosaves after the delay with the file matching the view. |
| ED-7  | pass | `editor-quotes-tables`: the quoted paragraph's second line under the quoted text, `> >` hanging further, `> -` under the item text rather than under the bullet or the quote marker, every `>` dimmed; the table in the mono font with the separator row `\|-------\|------:\|` dimmed end to end and `**bold**`, `` `code` `` and `[[Wikilink]]` in cells keeping their styling; the paragraph between wraps to the leading edge. `testED7_*`: indents per prefix as typed, a table in a quote, both following the font size, a typed separator making a table of the line above. |
| ED-8  | pass | `editor-rules`, light and dark: `---`, `* * *` and `___` each followed by faded hyphens in the marker colour from the typed characters' end to about 780 pt (the container's trailing edge less the last partial hyphen; sampled at 2x: hyphen pixels to x 1560, band colour from 1566), the typed characters dimmed and left in the text, the `---` under `Setext heading` a heading underline with no extension (ED-9). The extension is not text: `testED8_*` show `EditorController.text` and the storage length unchanged, a click on it landing the caret at the rule's end, the caret stepping straight to the next line, select-all and copy on a private pasteboard giving exactly the file's text, and a rule typed hyphen by hyphen gaining the mark at the third and losing it when prose follows or the blank line before it goes. |
| ED-9  | pass | Probe: `text\n---` is a level-2 heading spanning `text` and `---` with `---` the marker; `text\n\n---` a thematic break; `---` on line one a break; `--` nothing. `editor-headings`: `Setext level one` and `two` at the ED-4 level 1 and 2 sizes with the underline dimmed at that size; `editor-rules`: the heading under `___` keeps its `---` as a dimmed underline. |
| ED-10 | **fail** (M10.14a) | `editor-bands`, light and dark: sections alternate, the first on the text background, the second (from the `---` line to the `* * *` line) and the fourth (from `___` to the bottom of the text, the empty last line included) on `quaternarySystemFill`, the third back on the text background, the break line first in its band; `testED10_*` show the bands whole for any range they cross and painted only for the glyph range drawn. Sampled: the light band is rgb(248,248,248) on white, the dark rgb(36,36,36) on rgb(30,30,30). But the band does not span the full editor width: on a banded line (y 550 pt) the pixels are text background from x 0 to 7 pt, band colour from 8 to 791 pt and text background again from 792 to 800, while the text view's frame at the same 800 × 600 pt is x 0 to 800 (headless probe: `editorScrollView`, its clip view and `textView` all 800 pt wide at x 0, `textContainerInset` 8 × 8). The fill stops at the text container and leaves the 8 pt margin either side unbanded, though `drawBackground` widens its rect to the view's `bounds`; the hairline above the list reaches x 0 on the same image, so the strips are visible. ED-10 says "including margins". M10.14a. |
| ED-11 | pass | `editor-links`, light and dark: `[[Bar]]` and `[[daily/foo]]` in link colour; `[[Not yet written]]` and `[[missing]]` in link colour with a dotted underline under the target only and the tooltip `Cmd-click to create` (`EditorStyler.missingLinkToolTip`, over the whole link in `testED11_*`); `[[foo]]`, which two notes share, in `systemOrange` per K-2 with neither; `[standard link]` in link colour with its URL dimmed, `<https://example.org>` and the bare `https://example.net` in link colour; `![alt](…)` in `editor-link-hover` unstyled. A target arriving, going or becoming shared restyles only the changed links without an edit, including through a real library via `apply` (`testED11_*`, `restyleLinks`). |
| ED-12 | pass | `editor-link-hover`: with Cmd held and the pointer over `[standard link](https://example.com/a)`, a solid underline runs under the whole link, brackets and URL included, the dotted ED-11 underline under `[[Not yet]]` beside it untouched. The pointing hand is `NSCursor.current` in `testED12_*` (real `flagsChanged` through the window, `mouseMoved` and `mouseExited` to the view): over the whole range of every kind of link, not over an image, code, prose or empty space, not with Cmd plus another modifier; the I-beam back when Cmd goes, the pointer leaves the link or the view; the underline a temporary attribute of the layout manager, never in the storage, no edit and no undo step. |
| ED-13 | pass | Probe over a page with `<head>` style, script and title, `<h1>`, `<b>`/`<strong>`/`<i>`/`<em>`/`<s>`/`<del>`, a `font-weight:bold` span, a `<font>`, a link, `<code>`, `<br>`, nested `<ul>`, an `<ol>`, checkbox items, `<pre><code class="language-swift">`, nested `<blockquote>`s, a `<table>`, an http image and a `data:` image, `<hr>` and `<div>` lines: `# Title`; `**bold**`, `**strong**`, `*it*`, `*em*`, `~~gone~~`, `~~del~~`, `**styled**`, `font` as text, `[link](https://e.com/x)`, `` `code` ``; `Line one` / `line two`; `- one`, `- two`, `  - nested`; `1. first`, `2. second`; `- [x] done`, `- [ ] open`; a `swift` fence; `> quoted`, `>`, `> > deeper`; a padded pipe table with the first row as header; `![pic](https://e.com/i.png)` and nothing for the `data:` image; `---`; `div line` / `another`; nothing from the style, script or title; a bare `<b>just</b> a <i>fragment</i>` converts; an empty string is nil. The four HTML fixtures (Mail, Safari, Notes, Google Docs) and the two RTF ones (TextEdit's Cocoa writer, Pages) are byte-exact in `HTMLToMarkdownTests` and `RTFToMarkdownTests` (48 `testED13_*` in all: tables, task items, nested lists, code, quotes, remote-only images, edge whitespace, split runs, list markers with nesting and numbering). `PasteSmokeTests` drive `EditorTextView.paste(_:)` from a private pasteboard: HTML converted and inserted at the caret as one undoable, redoable, autosaved edit; HTML preferred over RTF; HTML holding no text falling through to RTF and then the string; RTF alone converted; a string alone pasted verbatim; a selection replaced. |
| ED-14 | pass | `Edit > Paste and Match Style` is ⌘⇧V sending `NSTextView.pasteAsPlainText(_:)` (the P-2 menu table in `MenuSmokeTests`); `testED14_*`: the plain string pasted with HTML and RTF alongside, the item reaching the editor down the responder chain, image data on the pasteboard going to `i/` and embedding at the caret under either paste (I-1), Paste enabled for HTML, RTF or a string alone and reading no data to decide, nothing pasted while no note is shown. Conversion under PF-9. |
| ED-15 | pass | Nothing in the list crept in: every marker stays visible in every snapshot and the file is the text (E-1); `EditorTextView`, `EditorStyler` and `EditorLayoutManager` create no `NSButton` or other control (grep); no `URLSession` under `Sources/`, so a remote image is never fetched and `![alt](url)` stays text (`editor-link-hover`), a `link(isImage: true)` token no styler case styles; tables are mono text with no editing aid; no preview pane (W-2 unchanged). |
| PF-9  | gate | `PastePerfTests` under the full gate at commit: `HTMLToMarkdown.markdown(fromHTML:)` over 200 KB of generated page HTML holding every ED-13 construct, warm-up plus median, on the main thread as `paste(_:)` runs it. |
| E-2   | pass | The text under every snapshot is the fixture's markdown byte for byte and `EditorController.text` and the storage length are unchanged by rules and bands (`testED8_*`, `testED10_*`); styling changes traits (ED-3), size (ED-4), family (ED-6, ED-7, E-8), colour, underline (ED-11, ED-12), paragraph head indents (ED-5, ED-7) and background drawing (ED-8, ED-10) and nothing else; the 21 `testE2_*` and the E-9 round-trip tests green; the restyle after an edit is still scoped to the affected paragraphs (E-3, `testED4_*`, `testED5_*`, `testED7_*`). |
| K-3   | pass | `testK3_*` (21): Cmd-Return with the caret inside, and Cmd-click on, a standard link, an autolink (the URL without its brackets) or a bare URL hand the URL to the injectable `openURL` (`NSWorkspace.open` by default) and open or create no note; both ends of the URL count as inside; an image and a URL in code are not links; a URL the system will not open, or a destination that is no URL, is reported under the field and never reaches the opener; wikilinks resolve, create at the root with folders as Enter would, or are refused, as before; unsaved edits are written to the note left first. |
| V-1   | pass | `writeWindowSnapshots` wrote the nine M10 pairs at 1600 × 1200 px for an 800 × 600 pt content view, light and dark differing (the text and bands on `textBackgroundColor`, the strip on `windowBackgroundColor`); thirty-eight files in all this run, every earlier pair re-written. Against W-6 and direction B: the same inset field, hairline, list and editor; prose still the system font at 13 pt with code in the monospaced font (E-8); the only `NSColor`s in `Sources/` are `windowBackgroundColor`, `textBackgroundColor`, `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `linkColor`, `systemPurple`, `systemOrange` and `quaternarySystemFill` (grep); nothing is custom-drawn but the ED-8 hyphens and ED-10 bands the spec asks for. The one thing that reads wrong is ED-10's margins (M10.14a). |

Observations outside the spec:

- The band fill measures 2.7 % of label colour (248 on 255 light, 36 on 30 dark) where ED-10
  says "about 4 %". `quaternarySystemFill` is the nearest semantic fill and the rules allow
  no literal colour, so it is recorded here rather than as a discrepancy; `tertiarySystemFill`
  would be the next step up if the human wants the bands more visible.
- Links, tags, emphasis and code inside a done task item keep their own colours where ED-6
  says the item's content is in secondary label colour; ED-11 says links are in link colour,
  and the M10.5 tests pin the resolution. Not counted a discrepancy.
- A rule line directly under another rule line (`* * *` under `---` with no blank line
  between) is not a thematic break by ED-8's blank-line rule and scans as a list item (`* `
  then `* *`); CommonMark would make it a second rule. The spec's rule is what shipped.
- `___`'s underscores sit on the baseline while the extension's hyphens sit at the hyphen's
  height, so the extension does not continue the underscores' own line; ED-8 asks for
  hyphens. `---` and `* * *` read as one line.

## Release pass of 2026-09-09 (M9.7, `v0.2.0`)

Build: `scripts/bundle.sh` at commit 176e032 (I-9), macOS 26.2; `scripts/info-plist.sh` now
defaults to 0.2.0, the plist reports `CFBundleShortVersionString` and `CFBundleVersion` 0.2.0
(`plutil -p`), `plutil -lint` is clean and the bundle is ad-hoc signed (`codesign -dv`:
`Signature=adhoc`, identifier `dev.laurenkt.mdnotes`). No app was launched, as in the M7.6 to
M9.6 passes: the human's instance runs on the real library. `scripts/check.sh quick` on the
same commit: 745 tests green, the 8 perf gates skipped in the debug run and run by the full
gate in the commit that carries this tag. Scope: the one ID whose code changed since the M9.6
pass, V-1 (I-9 touched the snapshot helper and its test only; `git diff --stat 73d5372..176e032`
names `WindowSnapshotTests.swift` and `WindowSnapshots.swift` and nothing under `Sources/`).
Every other ID stands as recorded in the v5 pass and the whole-of-v2 roll-up below, which
re-checked the v2, v3, v4 and v5 sections on code that has not changed since.

| ID  | Result | Notes |
|-----|--------|-------|
| V-1 | pass | `template-list-light.png` and `template-list-dark.png` from this run, opened and compared: both now show the inactive grey band on row 4 (`meeting`), so the observation the v5 pass recorded as I-9 is closed; the rest of the pair reads as v5 described it (the `@` field, hairline, five 46 pt rows with the semibold name and the expanded path as the secondary snippet, no date or square, the editor below empty, light and dark differing on `windowBackgroundColor`). Twenty-two files in all this run: the helper's own `selected-row` pair (`testV1_*` in `WindowSnapshotTests`, I-9) joins the twenty of v5. |

Release decision: `v0.2.0` is tagged with Q3 open (TP-3 and TP-8: the spec's example date
letters `YYYY`, `DD`, `dddd` are not what a Unicode pattern means by them). The result key above
admits a blocked entry in a release pass; the v5 pass and the roll-up record TP-8 as pass on the
mechanism and blocked on the spec's own example only; the behaviour shipped is the one TP-3 and
M9.1 both decide (Unicode patterns via `DateFormatter`) and the intended daily path is reachable
today with the Unicode spelling Q3 gives. No task is open above M9.7 in `PLAN.md` and `ISSUES.md`
has no open entry. Q3 is the human's to answer; its answer, a docs fix under the recommended
option, ships in a later tag.

## Pass of 2026-09-09 (M9.6, v5)

Build: debug `swift test` via `scripts/check.sh quick` at commit 1be6a68 (code as of a6afbc5,
M9.5), macOS 26.2: 744 tests green, the 8 perf gates skipped in the debug run and run by the full
gate at commit. No app was launched: the human's instance was running on the real library, so
template mode's window was inspected through the V-1 snapshot `TemplateModeSmokeTests` writes
(`build/snapshots/template-list-{light,dark}.png`, opened and compared against W-6 and direction
B on the ADR-0013 canvas), the menu through `MenuSmokeTests` over a real `AppDelegate` launch, and
the parser, the store, the query grammar and instantiation both through their 86 tests
(`TemplateParserTests`, `TemplateStoreTests`, `TemplateQueryTests`, `TemplateInstantiationTests`,
`TemplateListSmokeTests`, `TemplateInstantiateSmokeTests`, `TemplateModeSmokeTests`, the `testTP*`
in `MenuSmokeTests` and `FSEventsWatcherTests`) and by hand, from a probe compiled against the
`MDNotesCore` sources (`swiftc Sources/MDNotesCore/*.swift probe.swift`) over a temp library in
the local time zone (Europe/London, en_GB, 05:26 BST on Wednesday 9 September 2026). Scope: the
eleven IDs M9.1 to M9.5 cite, plus L-3 and TP-8, which TP-1 and ADR-0014 name. Every other ID
stands as recorded in the M8.6, M7.6, M6.9, v0.1.0 and M5.6 passes and is re-checked in the
roll-up below.

Summary: 13 IDs; 12 pass, 0 fail, 1 pass on the mechanism and blocked on Q3 for the spec's own
example (TP-8, non-blocking). No task was added; one observation on the V-1 helper is recorded as
I-9 (see V-1).

| ID   | Result | Notes |
|------|--------|-------|
| TP-1 | pass | Probe: a `templates/` holding `colon.md`, `Daily.md`, `existing.md`, `headless.md`, `meeting.md`, `trash.md`, `notes.txt`, `.hidden.md` and `sub/nested.md` lists `colon, Daily, existing, headless, meeting, trash`: names are the file names without `.md`, sorted case-insensitively, the `.txt`, the hidden file and the nested one left out. `LibraryScanner.scan` of the same root lists `Alpha.md` and `daily/Beta.md` only, so no template is a note (L-3), and `TemplateStore.name(forRelativePath:)` names `templates/meeting.md` and nothing under `templates/sub/` or outside the folder. `testTP1_templatesAreListedByNameAfterStartAndAreNotNotes` shows the same through `LibraryController.templateNames` and the snapshot. |
| TP-2 | pass | Probe: a header with `path` and an `other:` key parses to the path and the body after the closing fence; `no header`, an unclosed header and a header without `path` are refused with `This template has no header: it must start with a “---” line.`, `This template's header is not closed with a “---” line.` and `This template's header has no “path”.` The `template-list` snapshot lists `headless` with the first of those as its snippet, and Enter on it (`testTP2_enterOnATemplateThatDoesNotParseIsRefusedWithItsOwnReason`) or choosing it from the menu (`testTP2_choosingATemplateThatDoesNotParseIsRefusedInlineAndCreatesNothing`) puts the same line under the field and creates nothing. |
| TP-3 | pass | Probe in the local zone: `{{date:yyyy-MM-dd}}` gives `2026-09-09`, `MMMM` `September`, `EEEE` `Wednesday`, `HH` `05` (local, not UTC's 04), `mm` `26`; `{{title}}` is the title in path and body; `{{cursor}}` is removed from the body and marks the caret (`# Standup 05:26\n\ntail\n`, offset 17) and is literal text in a path; `{{nope}}` and `{{date}}` are left as written. The letters TP-3 lists as examples are not all what a Unicode pattern means by them: `YYYY` gives `2026` today but is the week-based year, `DD` gives `252` (day of the year) and `dddd` `0009`; Q3 (non-blocking) asks which the spec should say and is left to the human, not resolved here. |
| TP-4 | pass | Probe: `meeting` with the title `Standup` creates `meetings/2026-09-09/Standup.md`, both folders made, body `# Standup\n\n\n`, caret offset 11 where `{{cursor}}` was; the same again reports the note found, no cursor, and the file is unchanged; `Daily` with no title creates `daily/2026-09-09.md` holding `# Wednesday\n`; `existing`, whose path is `daily/Beta`, opens the existing `daily/Beta.md` and leaves `beta\n` in it. The write goes through the same `NoteStore.create` as C-2 (atomic, E-5). `TemplateInstantiateSmokeTests`: the note is listed and opened with the editor focused and the caret at the cursor or, without one, at the end; instantiating twice writes nothing the second time. |
| C-3  | pass | Probe: `colon` with the title `Plan` (`Plan: notes`) is refused with `“:” cannot be used in a note name.`, `meeting` with no title (an empty last segment) with `A folder or note name cannot be empty.`, the title `a/../b` with `“..” is not a folder name.`, and `trash` (`Trash/x`) with `“Trash” is reserved and cannot hold notes.`; nothing was created in any case (the root held exactly the four expected notes afterwards). `testC3_everyRuleRefusesTheExpandedPathAndNamesIt` covers every rule; `testC3_enterOnATemplateWhoseExpandedPathIsIllegalIsRefusedInline` shows the line under the field. |
| TP-5 | pass | `template-list` snapshot, light and dark, 800 × 600 pt: `@` in the field lists the five templates in place of the notes, the name in the row's semibold title face and the expanded path as the secondary snippet (`daily/2026-09-09`, `daily/Beta`, `meetings/2026-09-09/{{title}}` with the token left where the title will go, `{{title}}: notes`, and the TP-2 reason for `headless`), no date and no thumbnail square, the editor below empty. Probe of the grammar: `@` and `@ ` give an empty filter and every name; `@Meet` filters to `meeting` and `Weekly-meeting` (S-2: case-folded substring, order kept); `@meeting Standup with  two   spaces` gives the title `Standup with two spaces`; `hello @x` and an empty query are not template mode. `TemplateModeSmokeTests` (19) drive the rest through the real field editor: every keystroke reloads the rows, Enter acts on the first row or the selected one with the remaining words as the title (`meetings/2026-09-09/Standup.md`), an existing path is opened without a write, `“meeting” needs a title: type it after the name, as in @meeting My title.` is shown with nothing created, `No template is called “…”.` with no match, and Escape from the field or the list clears the query and leaves the mode (S-7). |
| TP-6 | pass | `MenuSmokeTests` over a real `AppDelegate` launch: File › `New from Template` is a submenu without a shortcut holding a disabled `No Templates` row over a library with none; opened over one with templates (`TemplateMenuDelegate.menuNeedsUpdate`) it holds one row per name in the library's order, each sending `newFromTemplate(_:)` down the responder chain with the name as `representedObject`, enabled only with a library open; a template written to disk (`weekly`) is a row the next time it opens and a removed one (`headless`) is gone, through the real watcher (TP-7). Choosing `daily` with focus in the editor creates and opens `daily/2026-09-09.md` (`# Wednesday\n`), editor focused, query left as it was; again opens the same note and writes nothing. Choosing `meeting` writes nothing and puts `@meeting ` in the field with the caret after the space, the `meeting` row selected and the title ask under the field; typing `Standup` clears the ask and Enter creates `meetings/2026-09-09/Standup.md`. `MainWindowController.newFromTemplate` ends in the same `instantiateTemplate` as TP-5. |
| TP-7 | pass | `FSEventsWatcherTests` report templates by name as they are added, changed, renamed and removed, and every template in a `templates/` folder that arrives or goes; `TemplateListSmokeTests` (real watcher): each of those reaches `LibraryController.templateNames` with no snapshot publish; `testTP7_relistedTemplatesReachTheRowsOnShow` shows rows in template mode following, and the TP-6 test the submenu. A batch naming only templates leaves the index alone (`LibraryChanges.affectsIndex`), so the note path of X-1 is untouched. |
| TP-8 | pass (mechanism), **blocked** Q3 (example) | `@daily` with `path: daily/{{date:yyyy-MM-dd}}` creates today's note once and opens it every time after (TP-4, `testTP4_instantiatingTwiceOpensTheNoteMadeTheFirstTimeAndWritesNothing`), which is the daily note ADR-0014 wanted. The path as TP-8 spells it expands today to `daily/2026/09-September/252-0009` rather than `…/09-Wednesday`; the Unicode spelling `daily/{{date:yyyy}}/{{date:MM-MMMM}}/{{date:dd-EEEE}}` gives the intended path. Q3 is the human's to answer. |
| S-2  | pass | Template names filter by the same rule as notes: `TemplateQuery.names(matching:)` folds case and matches a substring, keeping the given order (`testS2_filterMatchesNamesByCaseInsensitiveSubstring`, `testS2_orderIsKeptAsGiven`; `@Meet` above). Note search is untouched: `SearchIndexTests`, `WordSplitterTests` and `SearchSmokeTests` green. |
| S-7  | pass | `testTP5_escapeInTheFieldLeavesTemplateModeAndClearsTheQuery` and `testTP5_escapeInTheListLeavesTemplateModeAndReturnsToTheField`; Down from the field selects a template row and Enter on it instantiates it (`testTP5_enterActsOnTheSelectedTemplate`); the note-mode flow is as before (`KeyboardFlowSmokeTests`, `testS7_searchItemFocusesTheSearchFieldWithCommandL` green). |
| L-3  | pass | See TP-1: `templates/` is skipped by the scanner and never indexed, a note-mode query never lists a template (`testTP1_templatesAreNeverNotes`), and a first segment of `templates` is refused on creation (C-3). |
| V-1  | pass | `writeWindowSnapshots` wrote `template-list` at 1600 × 1200 px for an 800 × 600 pt content view, light and dark differing, on `windowBackgroundColor`; twenty files in all this run. Against W-6 and direction B: the same inset field, hairline, 46 pt rows, semibold title and secondary snippet as the note list; a template row simply has no date and no square, and nothing is custom-drawn. Observation: the test selects row 4 (`meeting`) on the same run-loop turn as the capture, and the light file shows no highlight on that row while the dark one, captured second, shows the inactive grey band; recorded as I-9 against the helper. The rows themselves are laid out alike in both. |

## Roll-up of 2026-09-09 (M9.6, whole of v2)

Same build as the v5 pass. Every ID the v2, v3, v4 and v5 sections list, re-checked on the
current code: the snapshots of the run above were all opened again (`main-window`, `note-list`,
`note-list-thumbnails`, `editor-fonts`, `editor-thumbnails`, `eviction-bar`, `settings`,
`template-list`, light and dark), the tests each earlier pass leaned on ran green in the same
run, and `git diff --stat` from each pass's commit says which files behind an ID have changed
since it was checked. Summary: 43 IDs; 33 pass, 0 fail, 5 gate, 4 n/a by hand, 1 blocked (TP-8,
Q3). Nothing has regressed; two edges have closed since they were recorded (S-11, E-9 via I-8).

| ID   | Result | Notes |
|------|--------|-------|
| L-3  | pass | v5. |
| L-7  | n/a by hand | Still needs an evicted iCloud file; `NoteStoreTests`, `ReadOnlyNoticeSmokeTests` green, `ReadOnlyNoticeBar.swift` unchanged since M6.9. |
| L-9  | n/a by hand | `DownloadRequester.swift` unchanged since M6.9; `DownloadRequesterTests`, `DownloadRequestSmokeTests` green. |
| L-10 | n/a by hand | `eviction-bar` snapshot, light and dark, reads as in M6.9 (`2 notes not downloaded from iCloud. Search is incomplete. · 985 MB free`, Open Storage Settings) between the strip and the hairline; `EvictionBar.swift` unchanged; `EvictionBarSmokeTests` green. |
| S-2  | pass | v5. |
| S-6  | pass | `note-list` snapshot: title, right-aligned date, one secondary snippet line, 46 pt rows; `BodySnippet.swift` unchanged since M7.6; `BodySnippetTests`, `NoteListSmokeTests` green. |
| S-7  | pass | v5. |
| S-9  | pass | `RelativeDateText.swift` unchanged since M6.9; `Today 04:23` and `14 Nov 2023` in the `note-list` snapshot; `NoteListSmokeTests` day-change and key-window tests green. |
| S-10 | pass | `note-list` and `note-list-thumbnails` snapshots: the sixty-character title ends in an ellipsis with the date whole, and before the square where there is one. `NoteRowView` has changed since M8.6 (template rows, I-8); `NoteListSmokeTests` width tests green. |
| S-11 | pass | `note-list-thumbnails` snapshot as M8.6 saw it (square on `A sixty…` and `Photo`, none on `Missing` and `Plain`, an empty one on `Broken`). Since M8.6, I-8 makes an image that arrives, changes or goes under `i/` on its own fill, refresh and empty the square through the real watcher (`ImageChangeSmokeTests`, `testS11_*`), closing the edge the v4 pass recorded. |
| C-3  | pass | v5; `CreateSmokeTests`, `NoteCreationTests` green. |
| E-2  | pass | `editor-fonts` snapshot: heading semibold, link blue, tag purple, code secondary and monospaced, prose in the base font; `EditorStyler.swift` unchanged since M8.6; `EditorStylingSmokeTests`, `EditorAttachmentSmokeTests` green. |
| E-3  | gate | `EditorPerfTests` under the full gate at commit; the scope tests in `EditorStylingSmokeTests` and `EditorAttachmentSmokeTests` green. |
| E-4  | pass | `AutosaveSmokeTests`, `testE9_saveWithAttachmentsWritesOnlyTheFilesText` green. `EditorController` changed since M8.6 only by `placeCaret` (TP-4), which moves the selection and is no edit: `TemplateInstantiateSmokeTests` see the created file equal to the editor's text. |
| E-5  | pass | `AtomicWriter.swift` unchanged; `AtomicWriterTests`, `AutosaveSmokeTests` green; TP-4 creation is the same atomic write as C-2. |
| E-8  | pass | `editor-fonts` snapshot: system font 13 pt, monospaced code at the same size; `EditorFontPreference.swift` unchanged since M6.9; `EditorFontSmokeTests` (clamping, persistence, stale family key) green; no font control in the `settings` snapshot. |
| E-9  | pass | `editor-thumbnails` snapshot, light and dark, as M8.6 described it (240 × 160 pt below `![[one.png]]`, nothing for `missing.png`, `tiny` at 19 pt and `tall` at the 160 pt cap stacked, none for the code-span embed). Since M8.6, I-8 replaces or drops a thumbnail whose file changes or goes on disk and adds one whose file arrives (`ImageChangeSmokeTests`, `testE9_*`), closing the other v4 edge; `EditorThumbnailSmokeTests` green. |
| K-1  | pass | `FirstImageTests`, `LinkIndexTests`, `MarkdownScannerTests` green; the `Pics` row's snippet keeps the code-span embed as text. |
| K-3  | pass | `LinkOpeningSmokeTests`, `testE9_linkAndTagLookupsTakeStorageIndicesPastAttachments` green; `linkTarget(at:)` unchanged since M8.6. |
| I-2  | pass | `testE9_aClickOnAThumbnailOpensTheImageWithTheDefaultApplication` green; `openThumbnail` unchanged since M8.6. |
| I-3  | pass | `EditorThumbnails.swift:329` is still the one caller of `addAttachment` in `Sources/` (grep); `testE9_anAttachmentThatIsNotAThumbnailIsLeftAlone` green. |
| T-4  | pass | `TagCompletionSmokeTests` (click searches the tag) and the storage-index test green; `clickInEditor` unchanged since M8.6. |
| W-2  | pass | `main-window`, `editor-fonts`, `eviction-bar` and `template-list` snapshots: strip, bar when shown, hairline, list, divider, editor, top to bottom; `MainView.swift` unchanged since M7.6; `LayoutSmokeTests` green. |
| W-3  | pass | `HotKey.swift`, `GlobalHotKey.swift`, `HotKeyRecorder.swift` unchanged since M6.9; `AppDelegate` changed only to hand the template submenu its delegate; `HotKeySmokeTests` (default ⌃⌘N, registration, toggle) green. |
| W-4  | pass | File › Close is still the one `performClose` item (grep), ⌘W; the five `testW4_*` (close, close button, Dock reopen, hotkey reopen, quit writes edits) green. |
| W-5  | pass | `WindowLevelSmokeTests` (`.floating`, `moveToActiveSpace`, panel and Settings above) green; `windowLevel` and `overlayLevel` unchanged. |
| W-6  | pass | `main-window` snapshot matches the M7.6 description: field spanning x 10 to 470 on the window-background strip, 8 pt above and below, one-pixel hairline, then the list; the only `NSColor`s in `Sources/` are still `windowBackgroundColor`, `secondaryLabelColor`, `linkColor` and `systemPurple` (grep); `testW6_titleBarShowsTheWindowTitle` green. |
| P-2  | pass | `testP2_launchInstallsTheMenuBarWithTheStandardMenusAndNoSaveItem` green over the whole table; the M9.5 rows are built in code by `MainMenu.fillTemplatesMenu`; no `.storyboard`, `.xib` or SwiftUI import under `Sources/`. |
| PR-1 | pass | `settings` snapshot, light and dark: `Notes folder:` and `Global shortcut:` right-aligned, the path middle-truncated with `Choose…`, the recorder at ⌃⌘N, 20 pt margins, nothing else; `PreferencesWindowController.swift` unchanged since M7.6; `PreferencesSmokeTests` green. |
| PF-2 | gate | `ListPerfTests`, `IndexPerfTests` under the full gate at commit, thumbnails on. |
| PF-3 | gate | `EditorPerfTests` under the full gate at commit, 50 thumbnails on show. |
| PF-4 | gate | `IndexPerfTests` under the full gate at commit; `BodySnippet.scanCharacters` still caps the read. |
| PF-6 | pass | Template listing, parsing, expansion and the instantiation write all run on the library queue with completions on main (`LibraryController.instantiate`, `listTemplates`; `TemplateInstantiateSmokeTests` show the write lands asynchronously); `ThumbnailCache` and `locateEmbed` as in M8.6. |
| PF-8 | gate | `ThumbnailCacheTests`, `testPF8_thumbnailsAreDecodedOffTheMainThreadOnceAndSharedWithTheList` green; `ThumbnailCache.swift` unchanged since M8.6; the 50 MB bound asserted by `ListPerfTests` under the full gate. |
| TP-1 to TP-7 | pass | v5. |
| TP-8 | pass (mechanism), **blocked** Q3 | v5. |
| V-1  | pass | v5; every snapshot re-inspected this run, light and dark pairs differing, on `windowBackgroundColor` (I-7). |

## Pass of 2026-09-08 (M8.6, v4)

Build: debug `swift test` at commit 5482186 (code as of 152a506, M8.5), macOS 26.2. No app was
launched: the human's instance was running on the real library, so every window was inspected
through the V-1 snapshots the smoke tests write (`build/snapshots/{note-list-thumbnails,
editor-thumbnails}-{light,dark}.png`, opened and compared against W-6 and direction B on the
ADR-0013 canvas), the cache, the resolver and the attachment plumbing through their tests
(`ThumbnailCacheTests`, `FirstImageTests`, `EditorAttachmentSmokeTests`,
`EditorThumbnailSmokeTests`, `RowThumbnailSmokeTests`, 55 tests, all green) and by reading the
code paths each ID names. Scope: the fifteen IDs M8.1 to M8.5 cite, plus I-3 (v2), which those
tasks realise. Every other ID stands as recorded in the M7.6, M6.9, v0.1.0 and M5.6 passes.

Summary: 16 IDs; 14 pass, 0 fail, 2 gate. No task was added; one edge outside the tests is
recorded as I-8 (see the notes on S-11 and E-9).

| ID   | Result | Notes |
|------|--------|-------|
| S-11 | pass | `note-list-thumbnails` snapshot, light and dark: the rows `A sixty character title…` and `Photo` end in a 34 pt square (68 px at 2x, x 858 to 926) vertically centred on the 46 pt row, filled with the image cropped to its centre square, the long title truncated with an ellipsis before it while the date keeps its place on the title line; `Missing` (embed names no file) and `Plain` (no embed) keep the date at the trailing edge with no square. The square is reserved by `NoteRowView.configure` from `Entry.firstImagePath`, filled only by `showThumbnail(_:for:)` when the cache has the image, and `testS11_clickOnTheThumbnailIsKeptByTheTableWhichSelectsTheRow` shows a click on it selects the row. Resolution is the first embed that names an existing file with an image extension (`ImageStore.firstImage`, `FirstImageTests`: none, one, first of several, unresolvable, first skipped for the next that resolves, embed in code ignored). Edge recorded as I-8: the watcher reports only `.md` files, so an image that arrives, changes or goes under `i/` on its own leaves the row as it was until the note itself changes. |
| K-1  | pass | `![[target]]` is an embed and resolves to a non-note file: `ImageStore.relativePath(forEmbed:)` looks under the root and `i/`, never at notes; `testK1_embedInsideCodeIsNotAnEmbed` shows a spelling inside a code span produces no image, and the `editor-thumbnails` snapshot's `Pics` row shows the body's code-span embed left as text in the snippet with the row's thumbnail coming from the real embed. |
| I-2  | pass | A plain click on an inline thumbnail opens the file it shows with the default application through the same `openFile` a Cmd-click on the embed uses (`MainWindowController.openThumbnail`); `testE9_aClickOnAThumbnailOpensTheImageWithTheDefaultApplication` delivers a real mouse-down and mouse-up at the attachment character's centre, sees `i/one.png` opened, the caret left where it was, and, when the system refuses, `“one.png” could not be opened.` under the search field. |
| E-9  | pass | `editor-thumbnails` snapshot, light and dark, 800 × 640 pt: `![[one.png]]` stays as blue link text with a 240 × 160 pt thumbnail (480 × 320 px) on the line directly below it, flush with the text's left edge; `![[missing.png]]` has nothing below it; `![[tall.png]] and ![[tiny.png]]` on one line get two thumbnails stacked below, `tiny.png` at its natural 19 pt (never enlarged), `tall.png` 40 pt wide at the 160 pt height cap, proportions kept; the code-span embed gets none. `EditorThumbnailSmokeTests`: editing the embed so it stops resolving removes the thumbnail and undo brings it back, deleting the embed leaves none behind, typing a new one adds it once the image is known, fencing it into code removes it, the saved file never holds one, a foreign attachment is left alone. Copy across an attachment writes the file's text (`EditorTextView.writeSelection`), adding and removing is neither an edit nor undoable, and search reads the file's text (the index folds bodies from disk and from `EditorController.text`), so the attachment is outside copy, undo and search. Nothing is reserved until the image arrives: `EditorThumbnails.request` adds the run in the cache's completion. The I-8 edge applies here too: an image that changes on disk keeps its old thumbnail until an edit touches the paragraph. |
| I-3  | pass | The only inline rendering is `ThumbnailAttachment` below an embed (E-9) and the row square (S-11); `EditorThumbnails` is the one maker of display-only runs, `testE9_anAttachmentThatIsNotAThumbnailIsLeftAlone` shows it touches no other attachment, and no other code path calls `addAttachment`. |
| E-2  | pass | The embed text stays visible and editable above its thumbnail in both snapshots; `testE9_stylingLandsOnTheShiftedStorageRangesAndNotOnTheRuns` shows the styler's ranges land on the text past an attachment and never on the run, and `testE9_roundTripWithAttachmentsPresentLeavesTheFileByteIdentical` (also for a file holding its own U+FFFC) shows the file is exactly the text. |
| E-3  | pass | `testE9_restyleAfterAnEditBelowAnAttachmentUsesTheFilesParagraphs`: the restyle after an edit is scoped to the paragraphs in the file's text, mapped back to the storage; `EditorThumbnails.reconcile` likewise takes `MarkdownScanner.paragraphRange` around the edit and, for a paragraph holding no `![[`, attachment or fence, returns on the string alone (`mayAffectThumbnails`). |
| E-4  | pass | `testE9_saveWithAttachmentsWritesOnlyTheFilesText` and `testE9_theSavedFileNeverHoldsAThumbnail`: the autosave writes `EditorController.text`; `testE9_addingAndRemovingAttachmentsIsNeitherAnEditNorUndoable` shows a thumbnail arriving does not start the 300 ms delay. |
| E-5  | pass | The round trip with attachments present is byte-identical, written through the same `AtomicWriter` as before; nothing in M8 touches the write path beyond what text it is given. |
| K-3  | pass | `testE9_linkAndTagLookupsTakeStorageIndicesPastAttachments`: `linkTarget(at:)` maps the caret's storage index to the file's before parsing, so Cmd-Return and Cmd-click on a link below a thumbnail open the right target. |
| T-4  | pass | Same test for `tag(at:)`; `MainWindowController.clickInEditor` tries the thumbnail first and the tag second, so a plain click on `#tag` below a thumbnail (the `after #tag` line in the snapshot) still searches the tag, and `testE9_aClickOnAThumbnailOpensTheImageWithTheDefaultApplication` shows a click on text is left to the text view. |
| PF-8 | pass | `ThumbnailCache`: a concurrent queue with at most `concurrentJobs` = 2 in flight and the rest waiting in order (`testPF8_requestReturnsAtOnceAndAtMostTwoJobsRun`), `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize` (never a full decode), entries keyed by path and modification date (a changed date invalidates, a missing or undecodable file caches nothing), LRU eviction to 50 MB with an over-bound image delivered but not kept, completions on main for hits and misses. The main thread draws only `cachedImage(for:pixelSize:)` (a lock, no file) and `NoteListController.showThumbnail` requests when that is nil; `testPF8_thumbnailsAreDecodedOffTheMainThreadOnceAndSharedWithTheList` shows one `ThumbnailCache` behind list and editor, no decode on main, and a reload or note switch served from the cache. PF-2 and PF-3 run with thumbnails on (`ListPerfTests` over 20k notes with 10 % embedding a PNG, `EditorPerfTests` on a 1 MB note with 50 embeds' thumbnails shown). |
| PF-6 | pass | `ImageStore.firstImage` runs where bodies are folded, on the library queue; `LibraryController.locateEmbed` looks the file up on that queue and completes on main; every cache job runs on `MDNotes.ThumbnailCache`; the main thread only takes the cache's lock and draws. |
| PF-2 | gate | `ListPerfTests` under `scripts/check.sh full`, now with row thumbnail lookups and requests inside the measured keystroke and asserting thumbnails were generated within the 50 MB bound. |
| PF-3 | gate | `EditorPerfTests` under `scripts/check.sh full`, now with 50 thumbnails on show and `reconcileNow` inside the measured keystroke. |
| V-1  | pass | `writeWindowSnapshots` wrote `note-list-thumbnails` at 960 × 800 px for a 480 × 400 pt content view and `editor-thumbnails` at 1600 × 1280 px for 800 × 640 pt, light and dark, the pairs differing; both sit on `windowBackgroundColor` (I-7). Against W-6 and direction B: the search field, hairline, 46 pt rows, semibold title, right-aligned date and secondary snippet are as the v3 pass saw them; the square sits inside the row's trailing inset over the selection highlight as well; only semantic colours, no custom drawing. |

Observations outside the spec: a row whose first embed names a file with an image extension
that ImageIO cannot decode (`Broken` in the `note-list-thumbnails` snapshot) reserves the
square and leaves it empty, with the date moved in beside it; the spec decides resolution by
"an existing image file" and says nothing about undecodable bytes, so it is not counted a
discrepancy. Two embeds on one line get their thumbnails in the order the images arrive
(`tiny.png` above `tall.png` in the snapshot), not the order of the embeds; the spec does not
order them. The list and the editor ask the cache for the same image at two pixel sizes
(136 px and 480 px at 2x) and it is downsampled once per size; the spec keys the cache by
path and date and says nothing against a size in the key.

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
5. When no app can be launched (the M7.6 to M9.6 passes), inspect windows through the V-1
   snapshots the smoke tests write (`scripts/check.sh quick`, then `build/snapshots/*.png`),
   and check pure logic by hand with a probe compiled straight against the core sources:
   `swiftc -swift-version 6 Sources/MDNotesCore/*.swift probe.swift -o probe` puts the probe in
   the same module, so nothing need be public, and it can run `TemplateParser`, `TemplateStore`,
   `NoteStore.instantiate`, `BodySnippet` and the rest over a temp library in the real time zone.
