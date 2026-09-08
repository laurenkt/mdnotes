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

    /// How the hotkey makes this the active application (W-3). Tests, whose process is never
    /// the active application, replace it to observe the call.
    public var activateApp: @MainActor () -> Void = { NSApplication.shared.activate() }

    /// Whether this is the active application, which decides what the hotkey does (W-3).
    /// Tests, whose process is never the active application, replace it to say so.
    public var isAppActive: @MainActor () -> Bool = { NSApplication.shared.isActive }

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
        // E-8, ADR-0010: v1's font family preference is gone for good.
        EditorFontPreference.deleteStaleFamily(in: .standard)

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
        // W-4: closing the window (Cmd-W, the close button) only hides it. The window is not
        // released when closed (`MainWindowController`), so it is ordered out and stays whole,
        // ready for the hotkey or a Dock click to bring it back.

        let library = LibraryController(root: libraryRoot)
        controller.attach(library)
        library.start()
        libraryController = library

        // W-3: the hotkey is live from the first moment the window is.
        let hotKey = GlobalHotKey()
        hotKey.onPress = { [weak self] in self?.toggleFromHotKey() }
        globalHotKey = hotKey
        register(self.hotKey)
    }

    // MARK: - Global hotkey (W-3)

    /// What the global hotkey does (W-3): with the window visible and this the active
    /// application, hides the window (ordered out, the app keeps running); otherwise makes this
    /// the active application, brings the window forward, and focuses the search field with
    /// its contents selected, so typing replaces the query (S-7 does the last part for Cmd-L).
    public func toggleFromHotKey() {
        if isMainWindowVisible && isAppActive() {
            hideMainWindow()
            return
        }
        activateApp()
        showMainWindow()
        mainWindowController?.focusSearchField(nil)
    }

    /// Whether the main window is on screen: ordered in and not miniaturized.
    public var isMainWindowVisible: Bool {
        mainWindowController?.window?.isVisible ?? false
    }

    /// Brings the main window forward on the current Space (W-5 has it follow the active
    /// Space), deminiaturizing it if need be, and makes it key. Focus inside it is untouched.
    public func showMainWindow() {
        guard let controller = mainWindowController else { return }
        controller.showWindow(nil)
        guard let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Orders the main window out without closing it (W-3, W-4): the note in the editor, the
    /// query and the selection are all kept for the next show.
    public func hideMainWindow() {
        mainWindowController?.window?.orderOut(nil)
    }

    /// W-4: a click on the Dock icon with the window hidden shows it again. AppKit's own
    /// reopen handling is declined, since a hidden window is ordered out, not closed, and
    /// would otherwise be left as it is.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return false
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
    /// the library folder and the hotkey in use. A folder chosen there goes through
    /// `openLibrary(at:)`, a hotkey recorded there through `setHotKey(_:)`.
    @objc public func showPreferences(_ sender: Any?) {
        let preferences = preferencesWindowController ?? makePreferencesWindowController()
        preferencesWindowController = preferences
        preferences.showLibraryRoot(libraryRoot)
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

    /// W-4 as AppKit asks it: closing the one window hides it, and the app stays running for
    /// the hotkey and the Dock icon to bring it back. Only Cmd-Q quits.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
