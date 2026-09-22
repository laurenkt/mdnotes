---
kind: feedback
schedule: end-of-current
title: Darker list markers and rules, rule extension into both margins, bands meet at the rule's midline
---
## Tasks
- [ ] List markers and typed rules in secondary label colour (ED-2): `-`, `*`, `+` and `<n>.`
      list markers (task items' `- ` included) and a thematic break's typed characters set in
      `secondaryLabelColor`; every other ED-2 marker stays tertiary. Tests:
      `testED2_listMarkersSecondaryLabel` (bullet, ordered, nested, task), `testED2_ruleCharactersSecondaryLabel`,
      `testED2_otherMarkersStayTertiary`. V-1: editor snapshot light and dark, bullets and numbers
      checked legible.
- [ ] Rule extension across the whole view (ED-8): the faded hyphens are drawn in
      `quaternaryLabelColor` from the editor view's leading edge to the typed rule's first
      glyph and from its last glyph to the view's trailing edge, margins included, on the
      rule's baseline in its font; drawn from `EditorTextView`'s own pass as the bands are
      (the layout manager's glyph pass is clipped to the container); still not text. Tests:
      `testED8_extensionReachesBothViewEdges` (rendered bitmap has hyphen pixels in the left
      margin and within one hyphen of the right edge), `testED8_extensionQuaternaryLabel`,
      existing not-selectable/not-copied tests kept green. V-1: editor-rules snapshot light and
      dark, typed rule visibly darker than the extension.
- [ ] Bands meet at rule midlines (ED-10): each band edge moves from the top of the rule's line
      fragment to the vertical centre of the rule's drawn hyphens, so a filled section runs from
      one rule's hyphen midline to the next's (the last to the bottom of the text). Tests:
      `testED10_bandEdgeAtHyphenMidline` (band rect minY/maxY equal the midline of the rule
      glyphs' bounding box, for a rule at document start, mid-document and at several font
      sizes), bitmap check of the pixel rows above and below the midline. V-1: editor-bands
      light and dark.
## Spec amendments
replace ED-2 with:
- **ED-2** Markers (`#`, `*`, `_`, `~`, `>`, link brackets and URLs, table pipes, setext
  underlines) are shown in tertiary label colour at the surrounding size. *(ADR-0021)* List
  markers (`-`, `*`, `+`, `<n>.`) and a thematic break's typed characters are shown in
  secondary label colour at the surrounding size, so bullets, numbers and rules stay legible.
replace ED-8 with:
- **ED-8** A thematic break is a line of three or more `-`, `*` or `_` (spaces allowed) that
  follows a blank line or starts the document, per CommonMark. The typed characters stay
  text, in secondary label colour (ED-2). *(ADR-0021)* Faded hyphens in quaternary label
  colour are drawn on the rule's baseline across the full width of the editor view, margins
  included: from the view's leading edge to the typed characters, and from their end to the
  view's trailing edge. The extension is not text: it cannot be selected, copied or reached by
  the caret.
replace ED-10 with:
- **ED-10** Sections between thematic breaks alternate backgrounds: the first section on the
  text background, the next on a subtle system fill (about 4 % label colour, adapting to
  appearance), and so on. *(ADR-0021)* A section boundary is the vertical centre of its rule's
  drawn hyphens, so a band runs from one rule's hyphen midline to the next rule's (the last
  band to the bottom of the text). Bands span the full editor width including margins and are
  drawn for the visible rect only.
## ADR
docs/adr/0021-editor-and-list-niggles.md
