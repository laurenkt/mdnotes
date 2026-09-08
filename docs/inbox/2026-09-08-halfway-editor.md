---
kind: milestone
schedule: after-last
title: M10: Halfway editor: in-place markdown styling, rich paste, rules and banding
---
## Tasks
- [ ] `MarkdownScanner` grows to the full block and inline set (ED-1): emphasis (`**`, `__`,
      `*`, `_` at word boundaries, `~~`), standard links `[t](u)`, images `![a](u)`,
      autolinks `<u>` and bare http(s) URLs, list items (bullet, ordered, task, nesting by
      two spaces), blockquote prefixes, pipe-table rows and separator rows, thematic breaks
      per ED-8, setext headings per ED-9. Tokens carry marker ranges separately from content
      ranges. Tests: one test per construct, code-span and fenced-block exclusion, word-boundary
      underscore, nesting depth, blank-line-before rule, setext under text.
- [ ] Marker dimming and emphasis traits in `EditorStyler` (ED-2, ED-3): markers in tertiary
      label colour; bold, italic and strikethrough traits on content; nothing inside code.
      Tests: attributes per token; markers and content styled separately.
- [ ] Heading scale (ED-4): 1.4 / 1.25 / 1.1 / 1.0 times the body size, bold; `#` and setext
      underline dimmed; scales with Cmd-plus. Restyle stays paragraph-scoped (E-3). Tests:
      font size per level; a heading edit relays out only its paragraph.
- [ ] Lists (ED-5): hanging indent via paragraph style so wrapped lines align under the item
      text, two spaces per nesting level, markers dimmed; ordered markers too. Tests: head
      indent per level; wrapped line x-origin equals text start.
- [ ] Task items (ED-6): `[ ]` / `[x]` set in the monospaced font at body size; done items in
      secondary colour; a plain click on the box toggles space and x as one undoable edit that
      autosaves. Tests: equal advance widths; click toggles; undo restores; file updated.
- [ ] Blockquotes and tables (ED-7): blockquote paragraphs hanging-indented with `>` dimmed,
      nested `>` nests; pipe-table lines in the monospaced font, separator row dimmed. Tests:
      attributes and indents.
- [ ] Horizontal rule extension (ED-8): a custom `NSLayoutManager` draws faded hyphens from the
      end of the typed rule to the trailing edge, unselectable, visible rect only. Tests: rule
      token ranges; drawn extension excluded from selection and copy; snapshot per V-1.
- [ ] Section banding (ED-10): the layout manager fills alternate sections between rules with
      a subtle system fill across the full editor width, the rule line first in its band,
      visible rect only, recomputed from the scanner's rule list. Tests: band ranges for
      0, 1, 3 rules and for a rule at document start; snapshot per V-1 in light and dark.
- [ ] Link state (ED-11): missing wikilink targets get a dotted underline and the tooltip
      "Cmd-click to create"; existing in link colour; ambiguous unchanged. Standard links,
      autolinks and bare URLs styled as links. Tests: attributes per state; restyle when a
      target appears or disappears.
- [ ] Cmd-hover and browser opening (ED-12, K-3): holding Cmd over any link shows the
      pointing-hand cursor and a solid underline; Cmd-click or Cmd-Enter on a standard link or
      URL opens it with `NSWorkspace`. Tests: cursor and underline after simulated
      flagsChanged over a link; open action receives the URL.
- [ ] `HTMLToMarkdown` in Core (ED-13): walks tidy-parsed HTML and emits headings, emphasis,
      links, lists with nesting, task items, code, blockquotes, pipe tables, remote images,
      paragraphs and line breaks; everything else as plain text. Fixtures: Mail, Safari,
      Notes, Google Docs exports. Tests: one per fixture, byte-exact expected markdown.
- [ ] `RTFToMarkdown` fallback (ED-13): attributed-string traits, links and list markers to
      markdown when no HTML is present. Fixture: Pages and TextEdit RTF.
- [ ] Rich paste wiring (ED-14): `EditorTextView` converts HTML, else RTF, else plain;
      Cmd-Shift-V (Paste and Match Style) pastes plain; image data still goes to `i/` (I-1).
      `PastePerfTests`: PF-9, 200 KB of HTML under 100 ms. Smoke tests per pasteboard type.
- [ ] `EditorPerfTests` extended (PF-3): the 1 MB note now contains every construct, with
      banding and rule extensions drawn; keystroke-to-redraw stays under 8 ms.
- [ ] Manual acceptance pass for M10 against `docs/ACCEPTANCE.md` (one line per ED bullet);
      discrepancies become tasks above this line.
- [ ] Tag `v0.3.0`.
## Spec amendments
replace E-2 with:
- **E-2** *(v3, ADR-0019)* Styling never changes the text: every markdown marker stays
  visible and editable. Styling may change font traits, size and family, colour,
  underline, paragraph indents and background drawing as section 17 specifies; the file on
  disk is exactly the text in the view (E-1).
replace K-3 with:
- **K-3** *(v3)* Cmd-click, or Cmd-Enter with the caret inside a link, opens the target. For a
  wikilink with no resolving note, one is created at the root with that title (C-2 rules) and
  opened. For a standard link, autolink or bare URL (ED-1) the URL opens with the default
  application.
add after PF-8:
- **PF-9** *(v3)* Converting 200 KB of pasted HTML to markdown (ED-13) completes on the main
  thread in under 100 ms. Enforced by `PastePerfTests`.
add section 17:
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
- **ED-2** Markers (`#`, `*`, `_`, `~`, `>`, list markers, link brackets and URLs, table
  pipes, setext underlines) are shown in tertiary label colour at the surrounding size.
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
  text; the layout manager draws faded hyphens in tertiary label colour from their end to the
  trailing edge of the text container. The extension is not text: it cannot be selected,
  copied or reached by the caret.
- **ED-9** A line of `=` or `-` directly under a paragraph line is a setext heading underline
  (level 1 or 2) per CommonMark, styled per ED-4 with the underline dimmed. This means `---`
  under text is a heading, not a rule.
- **ED-10** Sections between thematic breaks alternate backgrounds: the first section on the
  text background, the next on a subtle system fill (about 4 % label colour, adapting to
  appearance), and so on. A break line is the first line of its section. Bands span the full
  editor width including margins and are drawn by the layout manager for the visible rect only.
- **ED-11** Wikilinks whose target resolves are in link colour; those with no resolving note
  keep link colour with a dotted underline and the tooltip "Cmd-click to create"; ambiguous
  targets stay per K-2. Standard links, autolinks and bare URLs are styled as links.
- **ED-12** While Cmd is held and the pointer is over any link, the cursor is the pointing
  hand and the link shows a solid underline. Released Cmd restores the I-beam.
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
## ADR
docs/adr/0019-halfway-markdown-editor.md
