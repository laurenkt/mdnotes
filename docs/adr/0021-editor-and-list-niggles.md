# ADR-0021: Editor and list niggles after v0.3.0

Status: accepted, 2026-09-22 (feedback)

## Decision
A batch of small changes after using v0.3.0:

- List markers and a rule's typed characters move from tertiary to secondary label colour
  (ED-2). A rule's drawn extension moves to quaternary label colour and runs across the whole
  editor view, left margin included, not only from the typed end to the container edge (ED-8).
  Section bands meet at the vertical centre of each rule's hyphens instead of the top of its
  line (ED-10).
- The pointing hand shows over `![alt](url)` images with Cmd held as well (ED-12, K-3), and
  over thumbnails, tags and task boxes with no modifier. It must show in the running app, not
  only in headless tests.
- Inline thumbnails lose the fixed 240 × 160 pt cap: they are aspect-locked and fit the
  smallest of the image's point size, the text width and the editor's visible height (E-9).
- A list row gets a context menu: Rename, Show in Finder, Copy Link, Move to Trash (R-4).
- Tab and Shift-Tab walk search field, list and editor; Ctrl-Tab leaves the editor (S-12).
- The editor's context menu gets Quote and Code Block toggles for a selection (ED-16).
- Enter carries the current line's leading whitespace to the new line (ED-17).

## Why
Tertiary markers made bullets and numbers hard to see; the rule read as one flat grey line
with no way to tell the typed, editable part from the drawing, and stopped short of the
margins that the bands already fill. Bands starting at the top of a rule's line looked
misaligned against hyphens drawn at mid-height. The Cmd-hover cursor, specified by ED-12 and
green in tests, does not change in the real app. The 240 × 160 cap made screenshots
unreadable. Rename, delete and reveal had only keyboard routes; Tab did not reach the list
from the search field; wrapping lines in quotes or fences and typing indented code were
manual.

## Consequences
ED-2's marker colour is no longer uniform: list markers and rules are secondary, the rest
tertiary. The rule extension is drawn from the text view's own pass, as the bands are, since
the layout manager's glyph pass is clipped to the container. Larger thumbnails cost more of
the PF-8 cache; the budget is unchanged and the cache still downsamples to the drawn size.
Shift-Tab in the editor is taken for focus, so a future list outdent needs another key.
List-marker continuation on Enter and further formatting transforms (bold, lists, links)
remain out of scope.
