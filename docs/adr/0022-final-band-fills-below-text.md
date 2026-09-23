# ADR-0022: A filled final band continues below the text

Status: accepted, 2026-09-23 (feedback)

## Decision
When the last section of a note is on the band fill (ED-10), the fill continues from that
section's rule down through everything below the text: the empty part of the editor under a
short note, the bottom `textContainerInset`, and the elastic overscroll area the scroll view
shows past the end. A final section on the text background is unchanged. The top of the
editor is unaffected, since the first section is always on the text background.

## Why
ADR-0021 ended the last band at the bottom of the text, so a note ending in a filled section
switched back to the text background just below its last line, and again in the overscroll.
It reads as a stripe that stops for no reason; the section it belongs to has no end.

## Consequences
The area below the text is not drawn by the layout manager. The text view has to paint the
fill down to its own bottom edge, the text view has to be at least as tall as the clip view,
and the clip view's background has to match during overscroll. The clip view's colour
follows whether the last section is filled, so an edit that adds or removes a rule updates it
along with the redraw it already triggers. Only semantic colours are used (W-6, E-8).
