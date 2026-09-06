import AppKit
import MDNotesCore

/// The single main window (W-1). Its content is a `MainView` laid out per W-2; the list and
/// editor controllers drive its table and text view, fed by the library attached to it.
///
/// The search field (S-1) is wired here: every change to its text re-queries the current
/// snapshot on the main thread and reloads the list (S-5). Both routes a change can take, the
/// field editor's text-change notification for keystrokes and the field's action for the
/// cancel button, land in `searchQueryDidChange()`, which reloads once per distinct query.
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

    public init() {
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
        editorController = EditorController(textView: view.textView)
        super.init(window: window)
        listController.onSelectionChange = { [weak self] entry in self?.showInEditor(entry) }
        view.searchField.delegate = self
        view.searchField.target = self
        view.searchField.action = #selector(searchFieldDidSendAction(_:))
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
        editorController.load(entry.id, from: library.store)
    }
}
