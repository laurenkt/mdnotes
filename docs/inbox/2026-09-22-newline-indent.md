---
kind: feedback
schedule: end-of-current
title: Enter keeps the current line's leading indentation
---
## Tasks
- [ ] Newline keeps indentation (ED-17): Return in the editor inserts a line break followed by
      the current line's leading spaces and tabs (only those before the caret, when the caret
      is inside them), as one undoable edit; list markers, `>` prefixes and task boxes are not
      carried. An open completion popover (K-4, T-3) still takes Return first; Cmd-Return
      still opens links (K-3). Tests: `testED17_returnCopiesSpaces`,
      `testED17_returnCopiesTabs`, `testED17_returnInFencedCodeKeepsIndent`,
      `testED17_noIndentNoInsertion`, `testED17_caretInsideIndentCopiesUpToCaret`,
      `testED17_listMarkerNotContinued`, `testED17_singleUndoStep`,
      `testED17_completionPopoverTakesReturn`.
## Spec amendments
add after ED-16:
- **ED-17** *(ADR-0021)* Return in the editor inserts a line break followed by the leading
  spaces and tabs of the line the caret is on (those before the caret, if it is within them),
  as one undoable edit. List markers, blockquote prefixes and task boxes are not continued.
## ADR
docs/adr/0021-editor-and-list-niggles.md
