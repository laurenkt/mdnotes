import AppKit
import MDNotesCore

/// The single main window (W-1). Its content is a `MainView` laid out per W-2; the list and
/// editor controllers drive its table and text view, fed by the library attached to it.
@MainActor
public final class MainWindowController: NSWindowController {
    /// Autosave name under which `NSWindow` persists the frame.
    nonisolated public static let frameAutosaveName = "MainWindow"

    public let mainView: MainView
    public let listController: NoteListController
    public let editorController: EditorController

    /// The library whose snapshots the list shows, once one is attached.
    public private(set) var library: LibraryController?

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

    private func libraryDidPublish(_ snapshot: SearchIndex) {
        // The current query is kept across a reload; M2.4 wires the field itself.
        listController.show(snapshot.query(mainView.searchField.stringValue))
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
