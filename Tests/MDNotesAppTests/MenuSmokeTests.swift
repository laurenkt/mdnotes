import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the menu bar (`MainMenu`) and quit-on-close (W-4). The menu is
/// installed by the real launch path; its items are found by action and sent down the
/// responder chain from the window's first responder, which is what the menu does for the key
/// window (a headless test process has none). Quitting is observed through the delegate's
/// `terminate` hook, with the delegate standing in as the application's for the duration.
@MainActor
final class MenuSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    /// Files this test put in the Trash, removed again at teardown.
    private var trashed: [URL] = []

    /// Written oldest first, so the empty query lists Gamma, Beta, Alpha (S-3). Beta links to
    /// Alpha, so Alpha has one backlink (K-6).
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "alpha body"),
        ("daily/Beta.md", "beta links [[Alpha]]"),
        ("Gamma.md", "gamma body"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")

    private let keys = [MainView.listHeightDefaultsKey, BacklinksStrip.collapsedDefaultsKey]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-menu-\(UUID().uuidString)", isDirectory: true)
        for (i, note) in Self.notes.enumerated() {
            let url = root.appendingPathComponent(note.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try note.body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.base.addingTimeInterval(Double(i) * 60)], ofItemAtPath: url.path)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        for url in trashed { try? FileManager.default.removeItem(at: url) }
        trashed = []
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// Main-actor box so a delegate can ride inside a `@Sendable` teardown block.
    @MainActor
    private final class DelegateBox {
        let delegate: AppDelegate
        init(_ delegate: AppDelegate) { self.delegate = delegate }
    }

    /// A delegate launched against `root` through the real launch path, with the library
    /// ready and the list showing its notes. Its hotkey is released at teardown, so the next
    /// test can register it again, and its windows are closed.
    private func launch() async throws -> AppDelegate {
        let controller = makeMainWindowController(autosaveClock: ManualAutosaveClock())
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let delegate = AppDelegate(mainWindowController: controller, libraryRoot: root)
        let box = DelegateBox(delegate)
        addTeardownBlock {
            await MainActor.run {
                box.delegate.globalHotKey?.unregister()
                box.delegate.libraryController?.stop()
                box.delegate.preferencesWindowController?.close()
                box.delegate.mainWindowController?.close()
            }
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let library = try XCTUnwrap(delegate.libraryController)
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma, beta, alpha])
        return delegate
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func controller(of delegate: AppDelegate) throws -> MainWindowController {
        try XCTUnwrap(delegate.mainWindowController)
    }

    private func window(of delegate: AppDelegate) throws -> NSWindow {
        try XCTUnwrap(delegate.mainWindowController?.window)
    }

    /// Selects `id` in the list (S-8) and waits for the editor to show its body.
    private func select(_ id: NoteID, in delegate: AppDelegate) async throws {
        let controller = try controller(of: delegate)
        XCTAssertTrue(controller.listController.select(id), "\(id) is listed")
        await waitUntil("editor shows \(id.relativePath)") {
            controller.editorController.noteID == id && controller.editorController.body != nil
        }
    }

    /// Runs `body` with `delegate` as the application's delegate, as it is in the running app,
    /// and puts back whatever was there.
    private func asApplicationDelegate(_ delegate: AppDelegate, _ body: () async throws -> Void) async rethrows {
        let previous = NSApp.delegate
        NSApp.delegate = delegate
        defer { NSApp.delegate = previous }
        try await body()
    }

    // MARK: - Menu helpers

    /// Every item of `menu` and its submenus, in menu order.
    private func items(in menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { [$0] + items(in: $0.submenu) }
    }

    private func item(_ action: Selector, in menu: NSMenu?) throws -> NSMenuItem {
        try XCTUnwrap(items(in: menu).first { $0.action == action }, "an item with action \(action)")
    }

    private func submenu(titled title: String, of menu: NSMenu?) throws -> NSMenu {
        try XCTUnwrap(menu?.items.first { $0.title == title }?.submenu, "a \(title) menu")
    }

    /// Asserts `item` carries the shortcut `key` with `modifiers`, the way the menu shows it.
    private func assertShortcut(
        _ item: NSMenuItem, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(item.keyEquivalent, key, "key of \(item.title)", file: file, line: line)
        XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, "modifiers of \(item.title)", file: file, line: line)
    }

    /// Sends `item`'s action down the responder chain from the window's first responder, as
    /// the menu does for the key window. Returns whether a responder took it.
    @discardableResult
    private func perform(_ item: NSMenuItem, in window: NSWindow) throws -> Bool {
        let action = try XCTUnwrap(item.action)
        return (window.firstResponder ?? window).tryToPerform(action, with: item)
    }

    /// A `keyDown` for `characters` with `modifiers`, addressed to `window`.
    private func keyDown(
        _ characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16, in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    // MARK: - The menu bar: app, Edit, Note, View and Window menus, built in code (P-2)

    func testP2_launchInstallsTheMenuBarWithTheStandardMenusAndNoFileOrSaveItem() async throws {
        let delegate = try await launch()
        let menu = try XCTUnwrap(delegate.mainMenu)
        XCTAssertTrue(NSApp.mainMenu === menu, "installed as the application's menu bar")
        XCTAssertEqual(
            menu.items.map(\.title),
            [
                MainMenu.appMenuTitle, MainMenu.editMenuTitle, MainMenu.noteMenuTitle, MainMenu.viewMenuTitle,
                MainMenu.windowMenuTitle,
            ])
        XCTAssertTrue(
            NSApp.windowsMenu === (try submenu(titled: MainMenu.windowMenuTitle, of: menu)),
            "the Window menu is the application's windows menu")
        // AppKit appends the open windows to the windows menu, each targeted at its window;
        // every item the app builds sends its action down the responder chain instead.
        let built = items(in: menu).filter {
            $0.submenu == nil && !$0.isSeparatorItem && $0.action != #selector(NSWindow.makeKeyAndOrderFront(_:))
        }
        XCTAssertEqual(built.filter { $0.target != nil || $0.action == nil }.map(\.title), [])
        XCTAssertEqual(built.count, 19)

        let app = try submenu(titled: MainMenu.appMenuTitle, of: menu)
        XCTAssertEqual(
            app.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["About MDNotes", "Preferences\u{2026}", "Hide MDNotes", "Hide Others", "Show All", "Quit MDNotes"])
        XCTAssertEqual(
            try item(#selector(NSApplication.orderFrontStandardAboutPanel(_:)), in: app).title, "About MDNotes")
        assertShortcut(try item(#selector(NSApplication.hide(_:)), in: app), "h")
        assertShortcut(try item(#selector(NSApplication.hideOtherApplications(_:)), in: app), "h", [.command, .option])
        assertShortcut(try item(#selector(NSApplication.unhideAllApplications(_:)), in: app), "")
        assertShortcut(try item(#selector(NSApplication.terminate(_:)), in: app), "q")

        let window = try submenu(titled: MainMenu.windowMenuTitle, of: menu)
        XCTAssertEqual(
            window.items.filter { !$0.isSeparatorItem && $0.action != #selector(NSWindow.makeKeyAndOrderFront(_:)) }
                .map(\.title), ["Minimize", "Zoom", "Close"])
        assertShortcut(try item(#selector(NSWindow.performMiniaturize(_:)), in: window), "m")
        assertShortcut(try item(#selector(NSWindow.performZoom(_:)), in: window), "")
        assertShortcut(try item(#selector(NSWindow.performClose(_:)), in: window), "w")

        // S-1 creates notes and E-4 saves them: no File menu, no Save item.
        XCTAssertNil(menu.items.first { $0.title == "File" })
        XCTAssertEqual(items(in: menu).filter { $0.title.lowercased().hasPrefix("save") }.map(\.title), [])
    }

    // MARK: - E-7: the Edit menu carries undo and redo, and the clipboard

    func testE7_editMenuUndoAndRedoReachTheEditorThroughTheResponderChain() async throws {
        let delegate = try await launch()
        let edit = try submenu(titled: MainMenu.editMenuTitle, of: delegate.mainMenu)
        XCTAssertEqual(
            edit.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"])
        let undo = try item(Selector(("undo:")), in: edit)
        let redo = try item(Selector(("redo:")), in: edit)
        assertShortcut(undo, "z")
        assertShortcut(redo, "z", [.command, .shift])
        assertShortcut(try item(#selector(NSText.cut(_:)), in: edit), "x")
        assertShortcut(try item(#selector(NSText.copy(_:)), in: edit), "c")
        assertShortcut(try item(#selector(NSText.paste(_:)), in: edit), "v")
        let selectAll = try item(#selector(NSText.selectAll(_:)), in: edit)
        assertShortcut(selectAll, "a")

        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        let textView = controller.mainView.textView
        try await select(alpha, in: delegate)
        XCTAssertTrue(window.makeFirstResponder(textView))
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        textView.insertText(" edited", replacementRange: end)
        XCTAssertEqual(textView.string, "alpha body edited")

        XCTAssertTrue(try perform(undo, in: window), "Undo found a responder from the editor")
        XCTAssertEqual(textView.string, "alpha body", "the edit is undone (E-7)")
        XCTAssertTrue(try perform(redo, in: window))
        XCTAssertEqual(textView.string, "alpha body edited", "and redone")
        XCTAssertTrue(try perform(selectAll, in: window))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: (textView.string as NSString).length))
    }

    // MARK: - S-7: Search, Cmd-L

    func testS7_searchItemFocusesTheSearchFieldWithCommandL() async throws {
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        let note = try submenu(titled: MainMenu.noteMenuTitle, of: delegate.mainMenu)
        XCTAssertEqual(
            note.items.filter { !$0.isSeparatorItem }.map(\.title),
            [MainMenu.searchItemTitle, MainMenu.renameItemTitle, MainMenu.deleteItemTitle])
        let search = try item(#selector(MainWindowController.focusSearchField(_:)), in: note)
        assertShortcut(search, "l")
        XCTAssertTrue(controller.validateMenuItem(search), "always available")

        controller.search(for: "alpha")
        try await select(alpha, in: delegate)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))

        XCTAssertTrue(try perform(search, in: window), "Search found the window controller from the editor")
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor(), "the field is being edited")
        XCTAssertTrue(window.firstResponder === editor, "focus is in the search field")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 5), "with the query selected")
    }

    // MARK: - R-1: Rename Note, Cmd-R

    func testR1_renameItemEditsTheSelectedTitleWithCommandRAndNeedsARow() async throws {
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        let rename = try item(#selector(MainWindowController.renameNote(_:)), in: delegate.mainMenu)
        assertShortcut(rename, "r")

        XCTAssertNil(controller.listController.selectedEntry)
        XCTAssertFalse(controller.validateMenuItem(rename), "disabled with no row selected")
        XCTAssertTrue(try perform(rename, in: window), "the action is answered")
        XCTAssertNil(controller.listController.editingTitleOfID, "but edits nothing")

        try await select(alpha, in: delegate)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        XCTAssertTrue(controller.validateMenuItem(rename), "enabled with a row selected")
        XCTAssertTrue(try perform(rename, in: window))
        XCTAssertEqual(controller.listController.editingTitleOfID, alpha, "the selected title is being edited")
        controller.listController.cancelEditingTitle()
        XCTAssertNil(controller.listController.editingTitleOfID)
    }

    // MARK: - D-1: Delete Note, Cmd-Delete

    func testD1_deleteItemMovesTheSelectedNoteToTheTrashWithCommandDeleteAndNeedsARow() async throws {
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        let delete = try item(#selector(MainWindowController.deleteNote(_:)), in: delegate.mainMenu)
        assertShortcut(delete, MainMenu.deleteKeyEquivalent)
        XCTAssertEqual(MainMenu.deleteKeyEquivalent, "\u{8}", "NSBackspaceCharacter, shown as ⌫")

        var reported: [NoteID] = []
        controller.onDeleteNote = { [weak self] id, result in
            reported.append(id)
            if case .success(let url) = result { self?.trashed.append(url) }
        }
        XCTAssertFalse(controller.validateMenuItem(delete), "disabled with no row selected")
        XCTAssertTrue(try perform(delete, in: window))
        XCTAssertEqual(reported, [], "nothing is deleted without a selection")

        try await select(beta, in: delegate)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        XCTAssertTrue(controller.validateMenuItem(delete), "enabled with a row selected")
        XCTAssertTrue(try perform(delete, in: window))
        await waitUntil("deletion reported") { !reported.isEmpty }
        XCTAssertEqual(reported, [beta])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(beta.relativePath).path))
        await waitUntil("list drops Beta") { controller.listController.results.map(\.id) == [gamma, alpha] }
        XCTAssertEqual(controller.listController.selectedID, alpha, "the selection moved to the next row")
        XCTAssertEqual(trashed.count, 1)
    }

    // MARK: - K-6: Show/Hide Backlinks, Cmd-Shift-B

    func testK6_backlinksItemCollapsesAndExpandsTheStripWithCommandShiftB() async throws {
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        let strip = controller.mainView.backlinksStrip
        let view = try submenu(titled: MainMenu.viewMenuTitle, of: delegate.mainMenu)
        XCTAssertEqual(view.items.map(\.title), [MainMenu.hideBacklinksItemTitle])
        let toggle = try item(#selector(MainWindowController.toggleBacklinks(_:)), in: view)
        assertShortcut(toggle, "b", [.command, .shift])

        try await select(alpha, in: delegate)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        XCTAssertEqual(strip.backlinks, [beta], "Beta links to Alpha")
        XCTAssertFalse(strip.isHidden)
        XCTAssertFalse(strip.isCollapsed)

        XCTAssertTrue(controller.validateMenuItem(toggle))
        XCTAssertEqual(toggle.title, MainMenu.hideBacklinksItemTitle, "expanded: the item offers to hide")
        XCTAssertTrue(try perform(toggle, in: window))
        XCTAssertTrue(strip.isCollapsed)
        XCTAssertTrue(strip.titlesStack.isHidden)
        XCTAssertEqual(strip.summaryLabel.stringValue, "1 backlink")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: BacklinksStrip.collapsedDefaultsKey), "remembered")
        XCTAssertTrue(controller.validateMenuItem(toggle))
        XCTAssertEqual(toggle.title, MainMenu.showBacklinksItemTitle, "collapsed: the item offers to show")
        XCTAssertTrue(try perform(toggle, in: window))
        XCTAssertFalse(strip.isCollapsed)
        XCTAssertFalse(strip.titlesStack.isHidden)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: BacklinksStrip.collapsedDefaultsKey))

        // The window takes Cmd-Shift-B itself, before the menu is asked, wherever focus is.
        let press = try keyDown("B", modifiers: [.command, .shift], keyCode: 11, in: window)
        XCTAssertTrue(window.performKeyEquivalent(with: press), "taken by the window from the editor")
        XCTAssertTrue(strip.isCollapsed)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        XCTAssertTrue(window.performKeyEquivalent(with: press), "and from the search field")
        XCTAssertFalse(strip.isCollapsed)
        let plainB = try keyDown("b", modifiers: [.command], keyCode: 11, in: window)
        XCTAssertFalse(window.performKeyEquivalent(with: plainB), "Cmd-B alone is not the shortcut")
        XCTAssertFalse(strip.isCollapsed)

        // With no backlinks the strip is hidden, and the item still works on the remembered state.
        try await select(gamma, in: delegate)
        XCTAssertTrue(strip.isHidden)
        XCTAssertTrue(controller.validateMenuItem(toggle))
        XCTAssertTrue(try perform(toggle, in: window))
        XCTAssertTrue(strip.isCollapsed)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: BacklinksStrip.collapsedDefaultsKey))
        try await select(alpha, in: delegate)
        XCTAssertFalse(strip.isHidden)
        XCTAssertTrue(strip.isCollapsed, "shown collapsed, as left")
    }

    // MARK: - W-1: one window, so no window tabbing and no tab items in the View menu

    func testW1_viewMenuHoldsOnlyOurItemsBecauseTheWindowDisallowsTabbing() async throws {
        let delegate = try await launch()
        let window = try window(of: delegate)
        XCTAssertEqual(window.tabbingMode, .disallowed, "one window: nothing to tab (W-1)")
        XCTAssertNil(window.tabGroup, "the window is in no tab group")

        // AppKit adds Show Tab Bar and Show All Tabs to the menu titled View when it is about
        // to be shown, if any window allows tabbing; `update()` is what showing it does first.
        let view = try submenu(titled: MainMenu.viewMenuTitle, of: delegate.mainMenu)
        NSApp.mainMenu?.update()
        view.update()
        XCTAssertEqual(view.items.map(\.title), [MainMenu.hideBacklinksItemTitle], "only ours")
        let tabActions = [#selector(NSWindow.toggleTabBar(_:)), #selector(NSWindow.toggleTabOverview(_:))]
        XCTAssertEqual(
            items(in: delegate.mainMenu).filter { item in tabActions.contains { $0 == item.action } }.map(\.title),
            [], "no tab items anywhere in the menu bar")
    }

    // MARK: - PR-1: Preferences, Cmd-,

    func testPR1_preferencesItemShowsThePreferencesWindowWithCommandComma() async throws {
        let delegate = try await launch()
        let preferences = try item(
            #selector(AppDelegate.showPreferences(_:)), in: delegate.mainMenu)
        assertShortcut(preferences, ",")
        XCTAssertNil(delegate.preferencesWindowController, "not built until asked for")

        // The delegate is the end of the responder chain; the action reaches it from anywhere.
        let action = try XCTUnwrap(preferences.action)
        await asApplicationDelegate(delegate) {
            XCTAssertTrue(NSApp.sendAction(action, to: nil, from: preferences))
        }
        let shown = try XCTUnwrap(delegate.preferencesWindowController)
        XCTAssertEqual(shown.window?.isVisible, true)
        XCTAssertEqual(shown.libraryRoot, LibraryRootPreference.standardized(root))
    }

    // MARK: - W-4: closing the window quits the app

    func testW4_closingTheWindowQuitsTheApp() async throws {
        let delegate = try await launch()
        let window = try window(of: delegate)
        var terminated = 0
        delegate.terminate = { app in
            XCTAssertTrue(app === NSApp)
            terminated += 1
        }
        let close = try item(#selector(NSWindow.performClose(_:)), in: delegate.mainMenu)
        let quit = try item(#selector(NSApplication.terminate(_:)), in: delegate.mainMenu)
        assertShortcut(close, "w")
        assertShortcut(quit, "q")
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

        await asApplicationDelegate(delegate) {
            XCTAssertTrue(window.isVisible)
            window.performClose(nil)
        }
        XCTAssertEqual(terminated, 1, "closing the window asked the app to quit")
        XCTAssertFalse(window.isVisible)
    }

    func testW4_closingTheWindowQuitsEvenWhilePreferencesIsOpen() async throws {
        let delegate = try await launch()
        let window = try window(of: delegate)
        var terminated = 0
        delegate.terminate = { _ in terminated += 1 }
        delegate.showPreferences(nil)
        XCTAssertEqual(delegate.preferencesWindowController?.window?.isVisible, true)

        await asApplicationDelegate(delegate) { window.performClose(nil) }
        XCTAssertEqual(terminated, 1, "the Preferences window does not keep the app running")
    }

    func testW4_quittingOnCloseWritesUnsavedEditsFirst() async throws {
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        try await select(alpha, in: delegate)
        let textView = controller.mainView.textView
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.insertText(
            " edited", replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
        XCTAssertTrue(controller.editorController.hasUnsavedEdits)

        // The hook stands in for `NSApplication.terminate`, which asks the delegate as here.
        var replies: [Bool] = []
        let replied = expectation(description: "termination resumed")
        delegate.replyToTerminate = { _, shouldTerminate in
            replies.append(shouldTerminate)
            replied.fulfill()
        }
        var terminateReplies: [NSApplication.TerminateReply] = []
        delegate.terminate = { app in terminateReplies.append(delegate.applicationShouldTerminate(app)) }
        await asApplicationDelegate(delegate) { window.performClose(nil) }
        XCTAssertEqual(terminateReplies, [.terminateLater], "the quit waits for the write (E-4)")
        await fulfillment(of: [replied], timeout: 10)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(alpha.relativePath), encoding: .utf8),
            "alpha body edited")
    }

    func testW4_aDelegateThatIsNotTheApplicationsDoesNotQuitWhenItsWindowCloses() async throws {
        let delegate = try await launch()
        let window = try window(of: delegate)
        var terminated = 0
        delegate.terminate = { _ in terminated += 1 }
        XCTAssertFalse((NSApp.delegate as AnyObject?) === delegate)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(terminated, 0, "a test's delegate is nobody's: its window closes and nothing quits")
    }
}
