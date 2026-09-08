# ADR-0019: A halfway editor: markdown styled in place, markers kept, rich paste converted

Status: accepted, 2026-09-08

## Decision
The editor styles markdown structure in place while keeping every marker visible and
editable: scaled bold headings, emphasis traits, hanging-indent lists with clickable task
boxes, indented blockquotes, monospaced tables, link state and Cmd-hover affordances, and
horizontal rules drawn to the trailing edge with alternating section banding. Rich
pasteboard content (HTML, RTF) is converted to markdown on paste. CommonMark rules are
followed for rules and setext headings. Details in SPEC section 17 and the amended E-2, K-3.

## Why
Plain-text editing made pasted email and web content lose all structure, and a note's
shape (headings, lists, emphasis) was invisible while writing. The owner wants a midpoint
between editor and preview: the file stays exactly what is on screen, nothing is hidden,
but the text looks like what it means. Live-preview editors that hide markers were
rejected in ADR-0012 for their lag and undo problems; this design never changes the text
model, only attributes and background drawing. CommonMark was chosen over a custom
"--- is always a rule" reading to keep files portable, accepting that existing flashcard
separators read as setext headings until a blank line precedes them.

## Consequences
The styler now changes font size and family and paragraph indents for some tokens, so
E-2's "no layout metric changes" is replaced by "paragraph-scoped relayout only"; PF-3 is
measured on a note containing every construct. The layout manager gains background drawing
(bands, rule extensions) limited to the visible rect. A new budget PF-9 bounds paste
conversion time. The scanner grows substantially and becomes the single source of truth for
markdown structure across styling, snippets and link/tag indexes.
