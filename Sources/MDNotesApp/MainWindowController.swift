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
    /// selected note is read from its store. Replaces any library attached before.
    public func attach(_ library: LibraryController) {
        self.library?.onSnapshotChange = nil
        self.library = library
        library.onSnapshotChange = { [weak self] snapshot in self?.libraryDidPublish(snapshot) }
        libraryDidPublish(library.snapshot)
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
            window?.makeFirstResponder(mainView.textView)
        }
    }

    // MARK: - Autosave on focus loss (E-4)

    /// The window stopped being key: another window or app took over. Unsaved edits are
    /// written now rather than 300 ms from the last keystroke.
    @objc private func windowDidResignKey(_ notification: Notification) {
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
        // A fresh snapshot is shown through the query the user has typed; it is never reset.
        reloadList()
    }

    /// Queries the current snapshot with `query` and hands the results to the list. The
    /// snapshot is immutable and already on the main thread, so this is the whole PF-2 path.
    private func reloadList() {
        let snapshot = library?.snapshot ?? .empty
        listController.show(snapshot.query(query))
    }

    /// S-8: the selected row's note goes into the editor. Focus is left where it is.
    private func showInEditor(_ entry: SearchIndex.Entry?) {
        guard let entry, let library else {
            editorController.clear()
            return
        }
        editorController.load(entry.id, from: library)
    }
}
