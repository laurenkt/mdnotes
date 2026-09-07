import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public private(set) var mainWindowController: MainWindowController?
    public private(set) var libraryController: LibraryController?
    /// The Preferences window (PR-1), built the first time `showPreferences(_:)` is called.
    public private(set) var preferencesWindowController: PreferencesWindowController?
    /// The global hotkey's registration (W-3), made at launch.
    public private(set) var globalHotKey: GlobalHotKey?
    /// The menu bar (`MainMenu`), built and installed at launch.
    public private(set) var mainMenu: NSMenu?

    /// How `applicationShouldTerminate` tells AppKit the last write has landed. Tests, which
    /// must not actually terminate, replace it to observe the reply.
    public var replyToTerminate: @MainActor (NSApplication, Bool) -> Void = {
        $0.reply(toApplicationShouldTerminate: $1)
    }

    /// How closing the window quits the app (W-4). `NSApplication.terminate`, which asks
    /// `applicationShouldTerminate` and so writes unsaved edits first (E-4); tests replace it
    /// to observe the call.
    public var terminate: @MainActor (NSApplication) -> Void = { $0.terminate(nil) }

    /// How the hotkey makes this the active application (W-3). Tests, whose process is never
    /// the active application, replace it to observe the call.
    public var activateApp: @MainActor () -> Void = { NSApplication.shared.activate() }

    /// Where one-line reports go, such as a hotkey Carbon declined. Defaults to stderr.
    public var log: @Sendable (String) -> Void = LibraryController.standardErrorLog

    /// The folder `applicationDidFinishLaunching` opens as the library (L-1), and the one the
    /// library controller is on afterwards: `openLibrary(at:)` moves it.
    public private(set) var libraryRoot: URL

    /// The combination `applicationDidFinishLaunching` registers as the global hotkey (W-3),
    /// and the one in use afterwards: `setHotKey(_:)` moves it.
    public private(set) var hotKey: HotKey

    /// Opens the folder remembered in `UserDefaults`, or the default library (L-1), and
    /// registers the hotkey remembered there, or Ctrl-Cmd-N (W-3).
    public override init() {
        libraryRoot = LibraryRootPreference.root(from: .standard)
        hotKey = HotKeyPreference.hotKey(from: .standard)
        super.init()
    }

    /// Uses `mainWindowController` instead of building one at launch, and opens `libraryRoot`
    /// instead of the default library. The hotkey is read from `UserDefaults` as at launch.
    /// For tests.
    public init(mainWindowController: MainWindowController, libraryRoot: URL = LibraryController.defaultRoot) {
        self.mainWindowController = mainWindowController
        self.libraryRoot = LibraryRootPreference.standardized(libraryRoot)
        hotKey = HotKeyPreference.hotKey(from: .standard)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu bar is up before the window is, so its key equivalents are live with it.
        let menus = MainMenu.make()
        NSApp.mainMenu = menus.mainMenu
        NSApp.windowsMenu = menus.windowMenu
        mainMenu = menus.mainMenu

        // The window comes first and the index fills in behind it (PF-1, PF-7).
        let controller = mainWindowController ?? MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        // PR-1: Cmd-, and the menu item.
        controller.mainView.onShowPreferences = { [weak self] in self?.showPreferences(nil) }
        // W-4: closing the window quits.
        if let window = controller.window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(mainWindowWillClose(_:)), name: NSWindow.willCloseNotification,
                object: window)
        }

        let library = LibraryController(root: libraryRoot)
        controller.attach(library)
        library.start()
        libraryController = library

        // W-3: the hotkey is live from the first moment the window is.
        let hotKey = GlobalHotKey()
        hotKey.onPress = { [weak self] in self?.activateFromHotKey() }
        globalHotKey = hotKey
        register(self.hotKey)
    }

    // MARK: - Global hotkey (W-3)

    /// What the global hotkey does: makes this the active application, brings the window
    /// forward, and focuses the search field with its contents selected, so typing replaces
    /// the query (S-7 does the last part for Cmd-L).
    public func activateFromHotKey() {
        activateApp()
        guard let controller = mainWindowController else { return }
        controller.showWindow(nil)
        if let window = controller.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        controller.focusSearchField(nil)
    }

    /// Moves the global hotkey to `hotKey` (W-3, PR-1): the old combination is released and
    /// the new one registered. Should Carbon decline, the old one stays registered and a line
    /// says so. Before launch only `hotKey` moves, and launch registers it.
    public func setHotKey(_ hotKey: HotKey) {
        guard hotKey != self.hotKey else { return }
        self.hotKey = hotKey
        register(hotKey)
    }

    private func register(_ hotKey: HotKey) {
        guard let globalHotKey else { return }
        do {
            try globalHotKey.register(hotKey)
        } catch {
            log("could not register the global hotkey \(hotKey.displayString): \(error)")
        }
    }

    // MARK: - Preferences (PR-1)

    /// Cmd-, and the menu item. Shows the Preferences window, building it on first use, with
    /// the library folder, the editor font and the hotkey in use. A folder chosen there goes
    /// through `openLibrary(at:)`, a hotkey recorded there through `setHotKey(_:)`; a font
    /// chosen there is written to the defaults, which the main view follows (E-8).
    @objc public func showPreferences(_ sender: Any?) {
        let preferences = preferencesWindowController ?? makePreferencesWindowController()
        preferencesWindowController = preferences
        preferences.showLibraryRoot(libraryRoot)
        preferences.showEditorFont()
        preferences.showHotKey(hotKey)
        preferences.showWindow(sender)
        preferences.window?.makeKeyAndOrderFront(sender)
    }

    private func makePreferencesWindowController() -> PreferencesWindowController {
        let preferences = PreferencesWindowController(libraryRoot: libraryRoot, hotKey: hotKey)
        preferences.onLibraryRootChange = { [weak self] root in self?.openLibrary(at: root) }
        preferences.onHotKeyChange = { [weak self] hotKey in self?.setHotKey(hotKey) }
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

    // MARK: - Quit (W-4, E-4)

    /// W-4: the main window is closing, by its close button or Cmd-W, so the app quits. The
    /// call is made before the window has gone, and `terminate` does not return until the app
    /// has quit or a deferred quit has been answered (E-4), so AppKit's own last-window check
    /// cannot ask a second time while a write is still in flight. Only the application's own
    /// delegate quits it: a delegate built by a test is nobody's, and its window closes without
    /// consequence.
    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard let delegate = NSApp.delegate, delegate === self else { return }
        terminate(NSApp)
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

    /// W-4 as AppKit asks it: with the one window gone there is nothing to keep running for.
    /// `mainWindowWillClose` has normally quit before this is asked.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
