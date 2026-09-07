import AppKit
import MDNotesCore

/// The single main window (W-1). Its content is a `MainView` laid out per W-2; the list and
/// editor controllers drive its table and text view, fed by the library attached to it.
///
/// The search field (S-1) is wired here: every change to its text re-queries the current
/// snapshot on the main thread and reloads the list (S-5). Both routes a change can take, the
/// field editor's text-change notification for keystrokes and the field's action for the
/// cancel button, land in `searchQueryDidChange()`, which reloads once per distinct query.
///
/// The keyboard flow between the field, the list and the editor (S-7, S-8) is wired here too:
/// the field's command selectors arrive through the delegate, the list's through
/// `NoteTableView`'s closures, the editor's through `EditorController`, and Cmd-L is a key
/// equivalent of `MainView`.
///
/// Autosave (E-4) lives in `EditorController`; this controller adds the window-level trigger,
/// writing unsaved edits when the window stops being key.
///
/// External changes to the open note (X-2 to X-4) are wired here too. A snapshot that no
/// longer lists the editor's note means its file is gone: the editor is told (X-4), and the
/// list selection moves to the row that took the deleted one's place, unless the editor is
/// holding unsaved edits, in which case the list is left with no selection so the held text
/// is not replaced by another note (S-8 loads a selected row into the editor). External
/// modifications reported by the library reread the note when the editor is clean (X-2) and
/// are left to the next autosave to overwrite when it is not (X-3).
///
/// Deletion (D-1) is Cmd-Delete, a key equivalent of `MainView`, and later the menu item: the
/// selected note goes to the Trash through the library with no confirmation. The snapshot the
/// library publishes when the move has landed no longer lists the note (D-2), so the same path
/// as an external deletion (X-4) clears the editor and moves the selection to the next row.
///
/// Rename (R-1, R-2) is Cmd-R, a key equivalent of `MainView`, or a double-click on a title:
/// the list edits the title in place and hands the committed text to `commitTitle(of:to:)`,
/// which rejects an unusable title inline, under the search field like C-3, or renames the
/// file through the library. The rename is remembered in `pendingRenames` until the snapshot
/// listing the note under its new id arrives (D-2), so that publish is recognised as the note
/// moving rather than vanishing: the editor and the list selection follow it to the new id and
/// nothing is reloaded. A renamed title the current query no longer matches leaves the list, as
/// it would if the query had been typed after the rename. The library rewrites the links to
/// the note in other notes as part of the rename (R-3); those notes arrive in the same
/// snapshot, already indexed under their new bodies.
///
/// Link opening (K-3) is a Cmd-click in the editor or Cmd-Enter with the caret in a link, both
/// intercepted by `EditorTextView` and handed here: the editor names the link's target, the
/// snapshot's link index resolves it (K-2), and the note is opened as Enter in the search
/// field opens one, or created first as Enter creates one (C-2, C-3) when nothing resolves.
///
/// The `[[` and `#` completion popovers (K-4, T-3) live in the editor controller; this
/// controller dismisses them when the window stops being key and refreshes their lists when a
/// snapshot arrives.
///
/// A plain click on a tag in the editor (T-4) is intercepted by `EditorTextView` and handed
/// here: the search field is set to the tag, `#` included, and the list reloads for it as it
/// would for typing (S-4, S-5). The click is consumed, so the caret stays where it was and
/// focus stays in the editor; the note shown stays selected if the new query lists it.
///
/// The backlinks strip (K-6) is fed from here: whenever the editor's note changes or a snapshot
/// arrives, the snapshot's link index names the notes linking to the open note and the strip
/// shows their titles, or hides itself when there are none. A click on a title opens that note
/// as a link does (K-3). The strip keeps its own collapse state.
@MainActor
public final class MainWindowController: NSWindowController, NSSearchFieldDelegate {
    /// Autosave name under which `NSWindow` persists the frame.
    nonisolated public static let frameAutosaveName = "MainWindow"

    public let mainView: MainView
    public let listController: NoteListController
    public let editorController: EditorController

    /// The library whose snapshots the list shows, once one is attached.
    public private(set) var library: LibraryController?

    /// The query the list currently shows: the search field's text as of the last reload.
    public private(set) var query = ""

    /// The message shown under the search field (C-3), or nil while none is shown. Cleared
    /// by the next change to the query.
    public private(set) var inlineMessage: String?

    /// Called on the main thread once Enter's create-or-open has settled: with the note that
    /// was opened or created, or nil when the query was rejected or the write failed.
    public var onCommitQuery: (@MainActor (NoteID?) -> Void)?

    /// Called on the main thread once opening a link (K-3) has settled: with the link's target
    /// and the note that was opened or created for it, or nil when the target could not name a
    /// note or the write failed. Not called for an embed, which is not a note (K-1).
    public var onOpenLink: (@MainActor (LinkTarget, NoteID?) -> Void)?

    /// Called on the main thread once a deletion begun by `deleteSelectedNote()` has settled:
    /// with the note and where it went in the Trash, or the error that kept it in place.
    public var onDeleteNote: (@MainActor (NoteID, Result<URL, any Error>) -> Void)?

    /// Called on the main thread once a rename accepted by `commitTitle(of:to:)` has settled:
    /// with the old and new ids and the file's modification date, or the error that kept the
    /// old name. Not called for a title rejected inline.
    public var onRenameNote: (@MainActor (NoteID, NoteID, Result<Date, any Error>) -> Void)?

    /// Renames begun and not yet seen in a snapshot, old id to new (R-2, D-2).
    private var pendingRenames: [NoteID: NoteID] = [:]

    /// `autosaveClock` times the editor's autosave delay (E-4); tests pass one they advance
    /// by hand.
    public init(autosaveClock: any AutosaveClock = SystemAutosaveClock()) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MDNotes"
        window.minSize = NSSize(width: 400, height: 300)
        // W-4: closing quits, so nothing ever needs the window released on close.
        window.isReleasedWhenClosed = false
        window.center()
        let view = MainView(frame: window.contentLayoutRect)
        window.contentView = view
        window.initialFirstResponder = view.searchField
        mainView = view
        listController = NoteListController(tableView: view.tableView)
        editorController = EditorController(textView: view.textView, clock: autosaveClock)
        super.init(window: window)
        // E-4: unsaved edits are written the moment the window stops being key.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification,
            object: window)
        listController.onSelectionChange = { [weak self] entry in self?.showInEditor(entry) }
        view.searchField.delegate = self
        view.searchField.target = self
        view.searchField.action = #selector(searchFieldDidSendAction(_:))
        // S-7 and S-8 keyboard flow between the field, the list and the editor.
        view.tableView.onMoveUpFromFirstRow = { [weak self] in self?.focusSearchField(nil) }
        view.tableView.onActivateSelectedRow = { [weak self] in self?.focusEditor() }
        view.tableView.onCancel = { [weak self] in self?.clearQueryAndFocusSearchField() }
        editorController.onCancel = { [weak self] in self?.clearQueryAndFocusSearchField() }
        // E-8 into E-2: a new editor font is the styling's new base.
        view.onEditorFontChange = { [weak self] font in self?.editorController.styler.baseFont = font }
        // D-1: Cmd-Delete from anywhere in the window.
        view.onDeleteNote = { [weak self] in self?.deleteSelectedNote() ?? false }
        // R-1, R-2: Cmd-R from anywhere in the window; the list's edited title comes back here.
        view.onRenameNote = { [weak self] in self?.renameSelectedNote() ?? false }
        listController.onCommitTitle = { [weak self] id, text in self?.commitTitle(of: id, to: text) ?? false }
        // K-3: Cmd-click on a link in the editor, or Cmd-Enter with the caret in one.
        view.textView.onCommandClick = { [weak self] index in self?.openLink(at: index) ?? false }
        view.textView.onCommandReturn = { [weak self] in self?.openLinkAtCaret() ?? false }
        // T-4: a plain click on a tag in the editor searches for it.
        view.textView.onClick = { [weak self] index in self?.searchTag(at: index) ?? false }
        // K-6: a click on a title in the backlinks strip opens that note.
        view.backlinksStrip.onOpen = { [weak self] id in self?.openBacklink(id) }
        // W-1: one window, one persisted frame. Cascading would discard the autosave name, and
        // the name must be set after the content view exists so a restored frame lays it out.
        shouldCascadeWindows = false
        windowFrameAutosaveName = Self.frameAutosaveName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `library` in the window: every snapshot it publishes reloads the list, and the
    /// selected note is read from its store. A library attached before is let go of first, as
    /// `detachLibrary()` does.
    public func attach(_ library: LibraryController) {
        if self.library != nil { detachLibrary() }
        self.library = library
        library.onSnapshotChange = { [weak self] snapshot in self?.libraryDidPublish(snapshot) }
        library.onExternalChanges = { [weak self] changes in self?.libraryDidChangeExternally(changes) }
        libraryDidPublish(library.snapshot)
    }

    /// Lets go of the attached library (L-1: the library folder is changing). Unsaved edits to
    /// the note shown are written to it first (E-4 treats leaving a note as a save), then the
    /// editor is emptied, an inline rename in progress is dropped, and the list is emptied,
    /// so no row of the old library can be selected into the editor. The query in the search
    /// field is kept; the next library is shown through it. Does nothing when no library is
    /// attached.
    public func detachLibrary() {
        guard let library else { return }
        library.onSnapshotChange = nil
        library.onExternalChanges = nil
        self.library = nil
        pendingRenames = [:]
        hideInlineMessage()
        listController.cancelEditingTitle()
        editorController.clear()
        listController.show(SearchIndex.empty.query(query))
        refreshBacklinks()
    }

    // MARK: - Search (S-1, S-5)

    /// Reloads the list from the search field's current text if it differs from `query`.
    /// Called for every keystroke in the field and for its cancel button; safe to call after
    /// setting `stringValue` in code.
    public func searchQueryDidChange() {
        let text = mainView.searchField.stringValue
        guard text != query else { return }
        query = text
        hideInlineMessage()
        reloadList()
    }

    /// Keystrokes: the field editor changed the text (PF-2 starts here).
    public func controlTextDidChange(_ notification: Notification) {
        searchQueryDidChange()
    }

    /// The cancel button, and `sendsSearchStringImmediately` for good measure.
    @objc private func searchFieldDidSendAction(_ sender: Any?) {
        searchQueryDidChange()
    }

    // MARK: - Keyboard flow (S-7, S-8)

    /// Command selectors the search field's editor receives. Down arrow selects the first row
    /// and moves focus to the list; Escape clears the query and leaves focus in the field
    /// (S-7); Enter opens or creates the note the query names (C-1). Anything else keeps the
    /// field's own behaviour.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === mainView.searchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            selectFirstRowAndFocusList()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            clearQueryAndFocusSearchField()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            return commitQuery()
        default:
            return false
        }
    }

    // MARK: - Create on Enter (C-1 to C-4)

    /// Enter in the search field (C-1). With a blank query nothing happens and false is
    /// returned. Otherwise the query, trimmed (C-2), is compared case-insensitively with every
    /// listed note's title; a match is opened and the editor focused. With no match the note
    /// is created (C-2) unless the query cannot name a file, in which case the reason is shown
    /// under the field and nothing is written (C-3). Creation is asynchronous: the file is
    /// written off the main thread, and once the snapshot lists the note it is selected and
    /// the empty editor focused, with the query left in the field (C-4). `onCommitQuery`
    /// reports the outcome.
    @discardableResult
    public func commitQuery() -> Bool {
        let text = mainView.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let library else { return false }
        hideInlineMessage()
        if let existing = existingNote(matching: text, in: library.snapshot) {
            open(existing)
            onCommitQuery?(existing)
            return true
        }
        let id: NoteID
        do {
            id = try NoteCreation.noteID(forQuery: text)
        } catch {
            showInlineMessage(error.message)
            onCommitQuery?(nil)
            return true
        }
        library.create(id) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                open(id)
                onCommitQuery?(id)
            case .failure(let error):
                showInlineMessage(error.localizedDescription)
                onCommitQuery?(nil)
            }
        }
        return true
    }

    /// The note Enter opens instead of creating (C-1): the note at exactly the path the query
    /// would create, if there is one, so an existing file is never written over; otherwise
    /// the most recently modified note whose title equals the query. Both comparisons ignore
    /// case, like the file system does.
    private func existingNote(matching text: String, in snapshot: SearchIndex) -> NoteID? {
        var titleMatch: NoteID?
        // Entries are in list order, so the first title match is the most recently modified.
        for entry in snapshot.entries {
            if CaseFolding.areEqual(NoteCreation.queryForm(of: entry.id), text) { return entry.id }
            if titleMatch == nil, CaseFolding.areEqual(entry.id.title, text) { titleMatch = entry.id }
        }
        return titleMatch
    }

    /// Selects `id` in the list, which loads it into the editor (S-8), and focuses the editor.
    /// A note the current query does not list is loaded into the editor directly, with the
    /// list's selection cleared so the two never disagree.
    private func open(_ id: NoteID) {
        if listController.select(id) {
            focusEditor()
        } else if let library {
            mainView.tableView.deselectAll(nil)
            editorController.load(id, from: library)
            refreshBacklinks()
            window?.makeFirstResponder(mainView.textView)
        }
    }

    // MARK: - Backlinks (K-6)

    /// A click on a title in the backlinks strip (K-6). Opens `id` as a link to it would (K-3):
    /// selected in the list if the query lists it, loaded into the editor directly if not, with
    /// the editor focused and unsaved edits to the note being left written first (E-4).
    /// Returns false, doing nothing, when the snapshot no longer lists the note.
    @discardableResult
    public func openBacklink(_ id: NoteID) -> Bool {
        guard let library, library.snapshot.entry(for: id) != nil else { return false }
        hideInlineMessage()
        open(id)
        return true
    }

    /// Hands the strip the notes linking to the editor's note under the current snapshot (K-5,
    /// K-6), or nothing when no note is shown, so it hides. Called whenever either changes.
    private func refreshBacklinks() {
        guard let id = editorController.noteID, let library else {
            mainView.backlinksStrip.show([])
            return
        }
        mainView.backlinksStrip.show(library.snapshot.links.backlinks(to: id))
    }

    // MARK: - Link opening (K-3)

    /// Cmd-Enter in the editor (K-3). Opens the link the caret is in; returns false, doing
    /// nothing, when the caret is not in one.
    @discardableResult
    public func openLinkAtCaret() -> Bool {
        guard let target = editorController.linkTargetAtCaret() else { return false }
        return openLink(target)
    }

    /// Cmd-click in the editor (K-3), with the insertion index the click landed on. Opens the
    /// link there; returns false, doing nothing, when there is none.
    @discardableResult
    public func openLink(at index: Int) -> Bool {
        guard let target = editorController.linkTarget(at: index) else { return false }
        return openLink(target)
    }

    /// Opens the note `target` names (K-3): the note it resolves to (K-2), or, when none does,
    /// a note created for it as Enter in the search field would create one for the target's
    /// text (C-2), so a `/` in the target makes folders. A target that cannot name a file (C-3)
    /// shows the reason under the search field and creates nothing. Opening selects the note in
    /// the list if the query lists it, or loads it into the editor directly if not, and focuses
    /// the editor; unsaved edits to the note being left are written first (E-4). Creation is
    /// asynchronous and the note is opened once the snapshot lists it. Returns false, doing
    /// nothing, for an embed, which links to a file that is not a note (K-1, I-2), or when no
    /// library is attached; `onOpenLink` reports the outcome otherwise.
    @discardableResult
    public func openLink(_ target: LinkTarget) -> Bool {
        guard !target.isEmbed, let library else { return false }
        hideInlineMessage()
        if let existing = library.snapshot.links.resolve(target).target {
            open(existing)
            onOpenLink?(target, existing)
            return true
        }
        let id: NoteID
        do {
            id = try NoteCreation.noteID(forQuery: target.text)
        } catch {
            showInlineMessage(error.message)
            onOpenLink?(target, nil)
            return true
        }
        library.create(id) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                open(id)
                onOpenLink?(target, id)
            case .failure(let error):
                FileHandle.standardError.write(
                    Data("MDNotes: could not create \(id) for [[\(target.text)]]: \(error)\n".utf8))
                showInlineMessage(error.localizedDescription)
                onOpenLink?(target, nil)
            }
        }
        return true
    }

    // MARK: - Tag search (T-4)

    /// A plain click in the editor on the character at `index` (T-4). If the character is part
    /// of a tag, the search field is set to that tag, `#` included, the list reloads for it
    /// (S-5) and true is returned; the caret and focus are left alone. Returns false, doing
    /// nothing, when the character is not in a tag, so the click places the caret as usual.
    @discardableResult
    public func searchTag(at index: Int) -> Bool {
        guard let tag = editorController.tag(at: index) else { return false }
        search(for: tag)
        return true
    }

    /// Puts `text` in the search field and reloads the list for it, as typing it would (S-5).
    /// Focus is left where it is.
    public func search(for text: String) {
        mainView.searchField.stringValue = text
        searchQueryDidChange()
    }

    // MARK: - Delete (D-1, D-2)

    /// Cmd-Delete, and the menu item. Moves the selected row's note to the Trash with no
    /// confirmation (D-1). Returns false, doing nothing, when no row is selected. Unsaved
    /// edits to the note are written first (E-4 treats leaving a note as a save), so the file
    /// in the Trash holds what the editor showed. The move is asynchronous; once it lands the
    /// library's snapshot drops the note (D-2), which clears the editor and moves the selection
    /// to the next row through the X-4 path. A failure leaves the note listed and shows the
    /// reason under the search field. `onDeleteNote` reports the outcome.
    @discardableResult
    public func deleteSelectedNote() -> Bool {
        guard let entry = listController.selectedEntry, let library else { return false }
        let id = entry.id
        hideInlineMessage()
        let recycle: @MainActor () -> Void = { [weak self] in
            library.delete(id) { [weak self] outcome in
                guard let self else { return }
                if case .failure(let error) = outcome {
                    FileHandle.standardError.write(Data("MDNotes: could not delete \(id): \(error)\n".utf8))
                    showInlineMessage(error.localizedDescription)
                }
                onDeleteNote?(id, outcome)
            }
        }
        if editorController.noteID == id {
            editorController.flush(completion: recycle)
        } else {
            recycle()
        }
        return true
    }

    // MARK: - Rename (R-1, R-2)

    /// Cmd-R, and the menu item. Edits the selected row's title inline in the list (R-1).
    /// Returns false, doing nothing, when no row is selected.
    @discardableResult
    public func renameSelectedNote() -> Bool {
        guard listController.selectedEntry != nil else { return false }
        return listController.beginEditingTitle(ofRow: mainView.tableView.selectedRow)
    }

    /// The list committed `text` as the new title of `id` (R-2). A title that cannot be a file
    /// name, or that another note in the folder already has ignoring case, is rejected: the
    /// reason is shown under the search field and false is returned, so the list keeps the
    /// text up to be fixed. Otherwise true is returned and the rename begins: unsaved edits to
    /// the note are written first under its old name (E-4 treats leaving a note as a save), then
    /// the file is renamed within its folder off the main thread. The snapshot the library
    /// publishes when it lands lists the note under its new id (D-2), and `libraryDidPublish`
    /// moves the editor and the selection with it. A failure on disk leaves the note as it was
    /// and shows the reason. `onRenameNote` reports the outcome. A title that trims to the
    /// current one is accepted and renames nothing.
    public func commitTitle(of id: NoteID, to text: String) -> Bool {
        guard let library else { return false }
        hideInlineMessage()
        let newID: NoteID
        do {
            newID = try NoteRename.noteID(renaming: id, toTitle: text)
        } catch {
            showInlineMessage(error.message)
            return false
        }
        if newID == id { return true }
        if let other = NoteRename.collision(renaming: id, to: newID, in: library.snapshot) {
            showInlineMessage(NoteRename.Rejection.collision(other).message)
            return false
        }
        pendingRenames[id] = newID
        let rename: @MainActor () -> Void = { [weak self] in
            library.rename(id, to: newID) { [weak self] outcome in
                guard let self else { return }
                pendingRenames[id] = nil
                if case .failure(let error) = outcome {
                    FileHandle.standardError.write(Data("MDNotes: could not rename \(id) to \(newID): \(error)\n".utf8))
                    showInlineMessage(error.localizedDescription)
                }
                onRenameNote?(id, newID, outcome)
            }
        }
        if editorController.noteID == id {
            editorController.flush(completion: rename)
        } else {
            rename()
        }
        return true
    }

    // MARK: - Autosave on focus loss (E-4)

    /// The window stopped being key: another window or app took over. Unsaved edits are
    /// written now rather than 300 ms from the last keystroke, and a completion popover (K-4,
    /// T-3) left up in the editor is dismissed.
    @objc private func windowDidResignKey(_ notification: Notification) {
        editorController.dismissCompletions()
        editorController.flush()
    }

    private func showInlineMessage(_ text: String) {
        inlineMessage = text
        mainView.showMessage(text)
    }

    private func hideInlineMessage() {
        guard inlineMessage != nil else { return }
        inlineMessage = nil
        mainView.hideMessage()
    }

    /// S-7: Cmd-L, the menu item and the hotkey. Focuses the search field, selecting its text.
    @objc public func focusSearchField(_ sender: Any?) {
        mainView.focusSearchField()
    }

    /// S-7: Down from the search field. Selects the first row, which loads it into the editor
    /// (S-8), and moves focus to the list. With nothing listed the key is consumed and nothing
    /// changes.
    public func selectFirstRowAndFocusList() {
        let table = mainView.tableView
        guard table.numberOfRows > 0 else { return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        window?.makeFirstResponder(table)
    }

    /// S-7: Escape from anywhere. Empties the query, so the list shows every note again, and
    /// returns focus to the search field. The selected note, if still listed, stays selected.
    public func clearQueryAndFocusSearchField() {
        mainView.searchField.stringValue = ""
        searchQueryDidChange()
        mainView.focusSearchField()
    }

    /// S-8: Tab or Enter on a selected row. Focus moves to the editor; the note it shows, or is
    /// about to show, is the selected one.
    public func focusEditor() {
        guard listController.selectedEntry != nil else { return }
        window?.makeFirstResponder(mainView.textView)
    }

    private func libraryDidPublish(_ snapshot: SearchIndex) {
        // R-2, D-2: a rename of ours has landed. The note is the same; only its id changed.
        for (oldID, newID) in pendingRenames
        where snapshot.entry(for: oldID) == nil && snapshot.entry(for: newID) != nil {
            pendingRenames[oldID] = nil
            if editorController.noteID == oldID { editorController.noteWasRenamed(to: newID) }
            listController.noteWasRenamed(from: oldID, to: newID)
        }
        if let id = editorController.noteID, snapshot.entry(for: id) == nil {
            openNoteWasDeleted(id, snapshot: snapshot)
            return
        }
        // A fresh snapshot is shown through the query the user has typed; it is never reset.
        reloadList()
        // K-4, T-3: a completion list left showing lists the titles or tags the new snapshot has.
        editorController.refreshCompletions()
        // K-6: the new snapshot may link to the open note differently.
        refreshBacklinks()
    }

    /// Queries the current snapshot with `query` and hands the results to the list. The
    /// snapshot is immutable and already on the main thread, so this is the whole PF-2 path.
    private func reloadList() {
        let snapshot = library?.snapshot ?? .empty
        listController.show(snapshot.query(query))
        // The editor shows a note that is listed but not selected: it was opened while the
        // query did not list it, or X-4 held its edits until typing recreated the file. The
        // list catches up so the two agree (S-8); the editor is not reloaded for it.
        if listController.selectedID == nil, let id = editorController.noteID, !editorController.holdsEditsOfDeletedNote
        {
            listController.select(id)
        }
    }

    // MARK: - External changes to the open note (X-2, X-3, X-4)

    /// The snapshot has stopped listing the editor's note: its file was deleted (X-4). The
    /// editor is told first, so that the list's selection change cannot load another note
    /// over unsaved edits. With none, the selection moves to the row that now sits where the
    /// deleted note's row was (or the last row), which loads that note; a deleted note that was
    /// open without being listed leaves nothing selected. With unsaved edits the list is left
    /// with no selection and the editor keeps the text until the user types again.
    private func openNoteWasDeleted(_ id: NoteID, snapshot: SearchIndex) {
        let row = listController.selectedID == id ? mainView.tableView.selectedRow : -1
        editorController.noteWasDeleted()
        let fallbackRow = row >= 0 && !editorController.holdsEditsOfDeletedNote ? row : nil
        listController.show(snapshot.query(query), fallbackRow: fallbackRow)
        refreshBacklinks()
    }

    /// The library reports changes that were not ours (E-6). If the editor's note is among the
    /// files changed on disk it is reread when there are no unsaved edits (X-2); with unsaved
    /// edits the editor's text stands and the pending autosave writes it over the disk version
    /// (X-3), so nothing is done here. Deletions are handled from the snapshot instead.
    private func libraryDidChangeExternally(_ changes: LibraryChanges) {
        guard let id = editorController.noteID, changes.modified.contains(id) || changes.added.contains(id) else {
            return
        }
        editorController.reloadFromDisk()
    }

    /// S-8: the selected row's note goes into the editor. Focus is left where it is.
    private func showInEditor(_ entry: SearchIndex.Entry?) {
        guard let entry, let library else {
            // X-4: the deleted note's row is gone, but its unsaved edits stay in the view.
            if !editorController.holdsEditsOfDeletedNote { editorController.clear() }
            refreshBacklinks()
            return
        }
        // The note is already in the editor (see `reloadList`); reloading would move the caret.
        if entry.id == editorController.noteID { return }
        editorController.load(entry.id, from: library)
        refreshBacklinks()
    }
}
