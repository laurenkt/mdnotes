---
kind: feedback
schedule: end-of-current
title: Context menu on note rows: Rename, Show in Finder, Copy Link, Move to Trash
---
## Tasks
- [ ] Row context menu (R-4): right-click (or Ctrl-click) on a note row opens a menu acting on
      the clicked row, not the selection, with AppKit's clicked-row outline and the selection
      unchanged: Rename (inline edit on that row, R-1 to R-3), Show in Finder
      (`NSWorkspace.activateFileViewerSelecting`), Copy Link (`[[Title]]`, or
      `[[relative/path]]` without `.md` when the title is ambiguous per K-2, as plain text on
      the general pasteboard), separator, Move to Trash (D-1; the selection moves on only if
      the trashed row was the selected one). No menu on template rows (TP-5) or empty space.
      Tests: `testR4_menuItemsInOrder`, `testR4_actsOnClickedRowNotSelection`,
      `testR4_renameEditsClickedRow`, `testR4_showInFinderRevealsFile` (workspace stubbed),
      `testR4_copyLinkTitle`, `testR4_copyLinkAmbiguousUsesPath`,
      `testR4_moveToTrashUnselectedKeepsSelection`, `testR4_noMenuOnTemplateRows`.
## Spec amendments
add after R-3:
- **R-4** *(ADR-0021)* Right-clicking a note row opens a context menu that acts on the clicked
  row without changing the selection: Rename (inline edit of that row, R-1 to R-3), Show in
  Finder (reveals the file, selected, in Finder), Copy Link (puts `[[Title]]` on the
  pasteboard as plain text, or `[[relative/path]]` without `.md` when the title is ambiguous,
  K-2), a separator, and Move to Trash (D-1; the selection moves to the next row only if the
  trashed row was selected). Template rows (TP-5) have no menu.
## ADR
docs/adr/0021-editor-and-list-niggles.md
