---
kind: feedback
schedule: end-of-current
title: A filled final band extends through the empty area, bottom margin and overscroll below the text
---
## Tasks
- [ ] Final band fills below the text (ED-10): when the last section is filled, the band runs from
      its rule's hyphen midline to the bottom of the editor view, bottom inset included, and the
      text view is at least as tall as the clip view, so a short note's empty area is filled.
      The clip view's background matches the fill (the band colour over the text background,
      semantic colours only) while the last section is filled, so the elastic overscroll past
      the end shows it; it goes back to the text background when an edit leaves the last
      section unfilled. A final section on the text background is unchanged. Tests:
      `testED10_finalBandReachesViewBottom` (bitmap: band colour in the bottom inset rows),
      `testED10_finalBandFillsShortNoteViewport` (a two-line note ending filled, the rows
      between the last line and the clip view's bottom are band colour),
      `testED10_clipViewMatchesFilledFinalBand`, `testED10_clipViewRevertsWhenRuleRemoved`,
      `testED10_unfilledFinalSectionUnchanged`; PF-3 green. V-1: editor-bands light and dark
      with a note ending in a filled section, short and scrolled to the end.
## Spec amendments
replace ED-10 with:
- **ED-10** Sections between thematic breaks alternate backgrounds: the first section on the
  text background, the next on a subtle system fill (about 4 % label colour, adapting to
  appearance), and so on. *(ADR-0021)* A section boundary is the vertical centre of its rule's
  drawn hyphens, so a band runs from one rule's hyphen midline to the next rule's.
  *(ADR-0022)* A filled last section continues below the text without a break: through the
  empty editor area under a short note, the bottom margin and the scroll view's elastic
  overscroll. Bands span the full editor width including margins and are drawn for the
  visible rect only.
## ADR
docs/adr/0022-final-band-fills-below-text.md
