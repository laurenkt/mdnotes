---
kind: feedback
schedule: end-of-current
title: Quote and Code Block toggles in the editor's context menu for a selection
---
## Tasks
- [ ] Selection transforms (ED-16): with a non-empty selection, the editor's context menu gets
      Quote and Code Block, then a separator, above the standard `NSTextView` items; with no
      selection they are absent. Both act on every line the selection touches. Quote prefixes
      each line with `> `, or removes one leading `> ` from each when every touched non-blank
      line already has it. Code Block inserts a ```` ``` ```` line before the first touched
      line and after the last, or, when the touched lines are a fenced block (fences
      included) or lie inside one, removes that block's two fence lines. One undoable edit
      each, autosaved (E-4), restyled paragraph-scoped (E-3); the selection afterwards covers
      the transformed lines. Tests: `testED16_menuItemsOnlyWithSelection`,
      `testED16_quotePrefixesEachLine`, `testED16_quoteTogglesOff`,
      `testED16_quotePartialLineSelectionWholeLines`, `testED16_codeBlockWrapsLines`,
      `testED16_codeBlockTogglesOffFromInside`, `testED16_singleUndoStep`,
      `testED16_fileUpdated`.
## Spec amendments
add after ED-15:
- **ED-16** *(ADR-0021)* With a non-empty selection, the editor's context menu offers Quote and
  Code Block above the standard items. Both act on whole lines: every line the selection
  touches. Quote prefixes each with `> `; if every touched non-blank line already starts with
  `> `, it removes that prefix instead. Code Block puts a ```` ``` ```` fence line before the
  first touched line and after the last; if the touched lines are a fenced block or lie inside
  one, it removes that block's fences instead. Each is one undoable edit, autosaved (E-4).
  Other formatting transforms are out of scope.
## ADR
docs/adr/0021-editor-and-list-niggles.md
