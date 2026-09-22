---
kind: feedback
schedule: end-of-current
title: Tab and Shift-Tab walk search field, list and editor; Ctrl-Tab leaves the editor
---
## Tasks
- [ ] Keyboard focus order (S-12, S-8): Tab in the search field focuses the list, selecting the
      first row when none is selected (as Down does, S-7), and stays put when the list is
      empty; Tab in the list still moves to the editor (S-8); Tab in the editor still inserts a
      tab. Shift-Tab: editor to list, list to search field (query kept), nothing in the search field. Ctrl-Tab in the editor focuses the search field.
      Tests: `testS12_tabFromSearchFocusesListSelectsFirst`,
      `testS12_tabFromSearchKeepsExistingSelection`, `testS12_tabFromSearchEmptyListStays`,
      `testS12_tabInEditorInsertsTab`, `testS12_shiftTabEditorToList`,
      `testS12_shiftTabListToSearch`, `testS12_controlTabEditorToSearch`; S-7 and S-8 tests
      kept green.
## Spec amendments
add after S-8:
- **S-12** *(ADR-0021)* Keyboard focus order: Tab in the search field moves focus to the list,
  selecting the first row if none is selected (S-7), and does nothing when the list is empty.
  Tab in the list moves to the editor (S-8). In the editor Tab inserts a tab. Shift-Tab moves
  back: editor to list, list to search field; in the search field it does nothing. Ctrl-Tab in
  the editor moves focus to the search field.
## ADR
docs/adr/0021-editor-and-list-niggles.md
