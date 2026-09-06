import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public private(set) var mainWindowController: MainWindowController?
    public private(set) var libraryController: LibraryController?
    /// The Preferences window (PR-1), built the first time `showPreferences(_:)` is called.
    public private(set) var preferencesWindowController: PreferencesWindowController?

    /// How `applicationShouldTerminate` tells AppKit the last write has landed. Tests, which
    /// must not actually terminate, replace it to observe the reply.
    public var replyToTerminate: @MainActor (NSApplication, Bool) -> Void = {
        $0.reply(toApplicationShouldTerminate: $1)
    }

    /// The folder `applicationDidFinishLaunching` opens as the library (L-1), and the one the
    /// library controller is on afterwards: `openLibrary(at:)` moves it.
    public private(set) var libraryRoot: URL

    /// Opens the folder remembered in `UserDefaults`, or the default library (L-1).
    public override init() {
        libraryRoot = LibraryRootPreference.root(from: .standard)
        super.init()
    }

    /// Uses `mainWindowController` instead of building one at launch, and opens `libraryRoot`
    /// instead of the default library. For tests.
    public init(mainWindowController: MainWindowController, libraryRoot: URL = LibraryController.defaultRoot) {
        self.mainWindowController = mainWindowController
        self.libraryRoot = LibraryRootPreference.standardized(libraryRoot)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The window comes first and the index fills in behind it (PF-1, PF-7).
        let controller = mainWindowController ?? MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        // PR-1: Cmd-, and later the menu item.
        controller.mainView.onShowPreferences = { [weak self] in self?.showPreferences(nil) }

        let library = LibraryController(root: libraryRoot)
        controller.attach(library)
        library.start()
        libraryController = library
    }

    // MARK: - Preferences (PR-1)

    /// Cmd-, and the menu item. Shows the Preferences window, building it on first use, with
    /// the library folder in use. A folder chosen there goes through `openLibrary(at:)`.
    @objc public func showPreferences(_ sender: Any?) {
        let preferences = preferencesWindowController ?? makePreferencesWindowController()
        preferencesWindowController = preferences
        preferences.showLibraryRoot(libraryRoot)
        preferences.showWindow(sender)
        preferences.window?.makeKeyAndOrderFront(sender)
    }

    private func makePreferencesWindowController() -> PreferencesWindowController {
        let preferences = PreferencesWindowController(libraryRoot: libraryRoot)
        preferences.onLibraryRootChange = { [weak self] root in self?.openLibrary(at: root) }
        return preferences
    }

    /// Moves the app to the library at `root` (L-1, PR-1): the library controller on the old
    /// root is torn down and a new one built on the new root. The window lets go of the old
    /// library first, which writes any unsaved edits to the note it showed (E-4 treats leaving
    /// a note as a save) and empties the editor and the list; the old controller is then
    /// stopped, so nothing it still had in flight reaches the window, and the new one is
    /// attached and started, populating the list progressively as at launch (PF-7). The query
    /// in the search field is kept. A `root` that is the current one, however spelled, changes
    /// nothing. Before launch only `libraryRoot` moves, and launch opens it.
    public func openLibrary(at root: URL) {
        let root = LibraryRootPreference.standardized(root)
        guard root != libraryRoot || libraryController == nil else { return }
        libraryRoot = root
        guard let controller = mainWindowController, let old = libraryController else { return }
        controller.detachLibrary()
        old.stop()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        libraryController = library
    }

    /// E-4: unsaved edits are written before the app quits. The write runs off the main thread
    /// (PF-6), so termination is deferred until it lands, then resumed through
    /// `replyToTerminate`. With nothing to write the app quits at once.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor = mainWindowController?.editorController, editor.hasUnsavedEdits else {
            return .terminateNow
        }
        let reply = replyToTerminate
        editor.flush { reply(sender, true) }
        return .terminateLater
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
