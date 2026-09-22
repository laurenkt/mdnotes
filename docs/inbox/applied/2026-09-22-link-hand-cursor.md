---
kind: feedback
schedule: end-of-current
title: Pointing hand actually shows over links in the running app, plus images and plain-click targets
---
## Tasks
- [ ] Cmd-hover cursor in the running app (ED-12, bug): the `testED12_*` tests pass, but in the
      bundled app holding Cmd over a link leaves the I-beam. Find what resets it (likely
      `NSTextView`'s own cursor rects / `mouseMoved` / `cursorUpdate` handling running after
      ours) and fix it so the hand holds while the hover does. Tests:
      `testED12_handSurvivesTextViewCursorHandling` driving the whole AppKit path through
      `window.sendEvent` (mouse moved, cursor update, flags changed, a second move within the
      same link) and asserting `NSCursor.current` after each; the existing ED-12 tests kept.
      Add the manual check to `docs/ACCEPTANCE.md`'s ED-12 line and do it in
      `scripts/bundle.sh`'s app before committing; say so in the commit message.
- [ ] Images are links for Cmd (ED-12, K-3): `![alt](url)` joins `EditorController.link(containingCharacterAt:)`
      as a URL destination, so Cmd-hover shows the hand and underline over it and Cmd-click or
      Cmd-Enter opens its URL (a relative URL resolved against the note's folder). Tests: `testED12_imageLinkHover`, `testK3_cmdClickImageOpensURL`,
      `testK3_cmdEnterInImageOpensURL`; update the ED-12 test that asserts no hand over an image.
- [ ] Plain hover hand over click targets (ED-12, E-9, T-4, ED-6): with no modifier held, the
      pointer over an inline thumbnail, a tag or a task box is the pointing hand, and back to
      the I-beam off it; no underline. Tests: `testED12_plainHoverHandOverThumbnail`,
      `testED12_plainHoverHandOverTag`, `testED12_plainHoverHandOverTaskBox`,
      `testED12_plainHoverIBeamOverProseAndLinks` (links still need Cmd).
## Spec amendments
replace ED-12 with:
- **ED-12** While Cmd is held and the pointer is over any link (wikilink, embed, standard link,
  image `![alt](url)`, autolink, bare URL), the cursor is the pointing hand and the link shows
  a solid underline. Released Cmd restores the I-beam. *(ADR-0021)* With no modifier held, the
  pointer over an inline thumbnail (E-9), a tag (T-4) or a task box (ED-6) is the pointing
  hand, since a plain click acts on them; no underline is shown. This is the cursor the user
  sees in the running app: the text view's own cursor handling must not restore the I-beam
  while either holds.
replace K-3 with:
- **K-3** *(v3)* Cmd-click, or Cmd-Enter with the caret inside a link, opens the target. For a
  wikilink with no resolving note, one is created at the root with that title (C-2 rules) and
  opened. For a standard link, image `![alt](url)` *(ADR-0021)*, autolink or bare URL (ED-1)
  the URL opens with the default application; a relative image URL resolves against the
  note's folder.
## ADR
docs/adr/0021-editor-and-list-niggles.md
