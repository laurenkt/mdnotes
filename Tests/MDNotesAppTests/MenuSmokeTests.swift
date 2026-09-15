import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the menu bar (`MainMenu`) and hide-on-close (W-4). The menu is
/// installed by the real launch path; its items are found by action and sent down the
/// responder chain from the window's first responder, which is what the menu does for the key
/// window (a headless test process has none). Closing is driven through `performClose`, with
/// the delegate standing in as the application's for the duration, and reopening through the
/// delegate's `applicationShouldHandleReopen`, as a Dock click does. `File > New from
/// Template` (TP-6) is opened as AppKit opens it, through its delegate's `menuNeedsUpdate`,
/// over a library with real template files; choosing a row goes down the responder chain.
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

    /// The templates a TP-6 test writes under `templates/` before launching, listed in
    /// case-insensitive order (TP-1): one whose path needs a title, one whose path does not,
    /// and one without a header (TP-2).
    private static let templates: [(name: String, text: String)] = [
        ("meeting", "---\npath: meetings/{{date:yyyy-MM-dd}}/{{title}}\n---\n# {{title}}\n\n{{cursor}}\n"),
        ("daily", "---\npath: daily/{{date:yyyy-MM-dd}}\n---\n# {{date:EEEE}}\n"),
        ("headless", "no header here\n"),
    ]
    private static let templateNames = ["daily", "headless", "meeting"]

    /// Wednesday 9 September 2026, 23:30:00 UTC, which `environment()` pins in UTC.
    private static let instant = Date(timeIntervalSince1970: 1_788_996_600)

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

    // MARK: - Templates (TP-6)

    private func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    private func writeTemplate(_ name: String, _ text: String) throws {
        let url = url("\(TemplateStore.folderName)/\(name).md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func environment() throws -> TemplateParser.Environment {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return TemplateParser.Environment(
            date: Self.instant, timeZone: zone, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Writes the fixture templates and launches over them, the date pinned and the library's
    /// template list up.
    private func launchWithTemplates() async throws -> AppDelegate {
        for template in Self.templates { try writeTemplate(template.name, template.text) }
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let environment = try environment()
        controller.templateEnvironment = { environment }
        let library = try XCTUnwrap(delegate.libraryController)
        await waitUntil("templates listed") { library.templateNames == Self.templateNames }
        return delegate
    }

    private func templatesMenu(of delegate: AppDelegate) throws -> NSMenu {
        let file = try submenu(titled: MainMenu.fileMenuTitle, of: delegate.mainMenu)
        return try submenu(titled: MainMenu.newFromTemplateItemTitle, of: file)
    }

    /// Opens the `New from Template` submenu as AppKit does, by telling its delegate it is
    /// about to be shown, and returns its rows.
    private func openTemplatesMenu(of delegate: AppDelegate) throws -> [NSMenuItem] {
        let menu = try templatesMenu(of: delegate)
        let menuDelegate = try XCTUnwrap(menu.delegate, "the submenu has a delegate to fill it")
        menuDelegate.menuNeedsUpdate?(menu)
        return menu.items
    }

    /// The submenu's row for the template called `name`, the submenu opened first.
    private func templateItem(_ name: String, in delegate: AppDelegate) throws -> NSMenuItem {
        try XCTUnwrap(try openTemplatesMenu(of: delegate).first { $0.title == name }, "a row for \(name)")
    }

    /// Chooses `item` as the menu would and waits for the instantiation it starts, or the
    /// refusal, to be reported.
    private func chooseAndSettle(_ item: NSMenuItem, in delegate: AppDelegate) async throws -> NoteID? {
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        let settled = expectation(description: "instantiation settled")
        var reported: NoteID?
        controller.onInstantiateTemplate = { id in
            reported = id
            settled.fulfill()
        }
        XCTAssertTrue(try perform(item, in: window), "the row's action found the window controller")
        await fulfillment(of: [settled], timeout: 10)
        controller.onInstantiateTemplate = nil
        return reported
    }

    /// A focused text field's first responder is its field editor, not the field itself.
    private func searchFieldEditor(_ controller: MainWindowController) throws -> NSTextView {
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView, "focus is in a text view")
        XCTAssertTrue(editor.isFieldEditor && editor.delegate === controller.mainView.searchField, "the search field's")
        return editor
    }

    /// Every file under the root, as relative paths, sorted.
    private func filesOnDisk() throws -> [String] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []))
        var paths: [String] = []
        for case let url as URL in enumerator
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            paths.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
        }
        return paths.sorted()
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

    // MARK: - The menu bar: app, File, Edit, Note, View and Window menus, built in code (P-2)

    /// One row of the menu audit: an item's title and the shortcut it shows, or nil for a
    /// separator.
    private typealias Row = (title: String, key: String, modifiers: NSEvent.ModifierFlags)?

    /// The whole menu bar as the audit expects it, menu by menu, in order. The Window menu's
    /// own items only; AppKit appends the open windows below them.
    private static let expectedMenus: [(title: String, rows: [Row])] = [
        (
            MainMenu.appMenuTitle,
            [
                ("About MDNotes", "", .command), nil, ("Settings\u{2026}", ",", .command), nil,
                ("Hide MDNotes", "h", .command), ("Hide Others", "h", [.command, .option]),
                ("Show All", "", .command), nil, ("Quit MDNotes", "q", .command),
            ]
        ),
        (
            MainMenu.fileMenuTitle,
            [(MainMenu.newFromTemplateItemTitle, "", .command), nil, (MainMenu.closeItemTitle, "w", .command)]
        ),
        (
            MainMenu.editMenuTitle,
            [
                ("Undo", "z", .command), ("Redo", "z", [.command, .shift]), nil, ("Cut", "x", .command),
                ("Copy", "c", .command), ("Paste", "v", .command),
                (MainMenu.pasteAndMatchStyleItemTitle, "v", [.command, .shift]), ("Select All", "a", .command),
            ]
        ),
        (
            MainMenu.noteMenuTitle,
            [
                (MainMenu.searchItemTitle, "l", .command), nil, (MainMenu.renameItemTitle, "r", .command),
                (MainMenu.deleteItemTitle, MainMenu.deleteKeyEquivalent, .command),
            ]
        ),
        (
            MainMenu.viewMenuTitle,
            [
                (MainMenu.biggerItemTitle, "+", .command), (MainMenu.smallerItemTitle, "-", .command),
                (MainMenu.actualSizeItemTitle, "0", .command), nil,
                (MainMenu.hideBacklinksItemTitle, "b", [.command, .shift]),
            ]
        ),
        (
            MainMenu.windowMenuTitle,
            [("Minimize", "m", .command), ("Zoom", "", .command), nil, ("Bring All to Front", "", .command)]
        ),
    ]

    func testP2_launchInstallsTheMenuBarWithTheStandardMenusAndNoSaveItem() async throws {
        let delegate = try await launch()
        let menu = try XCTUnwrap(delegate.mainMenu)
        XCTAssertTrue(NSApp.mainMenu === menu, "installed as the application's menu bar")
        XCTAssertEqual(menu.items.map(\.title), Self.expectedMenus.map(\.title))
        XCTAssertTrue(
            NSApp.windowsMenu === (try submenu(titled: MainMenu.windowMenuTitle, of: menu)),
            "the Window menu is the application's windows menu")

        // Every title and key equivalent, menu by menu (the audit M7.5 asks for). AppKit
        // appends a separator and the open windows to the windows menu; those are its.
        for expected in Self.expectedMenus {
            var actual = Array(
                try submenu(titled: expected.title, of: menu).items.prefix {
                    $0.action != #selector(NSWindow.makeKeyAndOrderFront(_:))
                })
            while actual.last?.isSeparatorItem == true { actual.removeLast() }
            XCTAssertEqual(actual.count, expected.rows.count, "\(expected.title) menu has \(expected.rows.count) rows")
            for (item, row) in zip(actual, expected.rows) {
                guard let row else {
                    XCTAssertTrue(item.isSeparatorItem, "a separator in \(expected.title) before \(item.title)")
                    continue
                }
                XCTAssertFalse(item.isSeparatorItem, "\(row.title) in \(expected.title)")
                XCTAssertEqual(item.title, row.title, "\(expected.title) menu")
                assertShortcut(item, row.key, row.modifiers)
            }
        }

        // AppKit appends the open windows to the windows menu, each targeted at its window;
        // every item the app builds sends its action down the responder chain instead. The
        // one exception is the template placeholder, which has no action so it stays disabled.
        let built = items(in: menu).filter {
            $0.submenu == nil && !$0.isSeparatorItem && $0.action != #selector(NSWindow.makeKeyAndOrderFront(_:))
        }
        XCTAssertEqual(built.filter { $0.target != nil }.map(\.title), [])
        XCTAssertEqual(built.filter { $0.action == nil }.map(\.title), [MainMenu.noTemplatesItemTitle])
        XCTAssertEqual(built.count, 25)

        // S-1 creates notes and E-4 saves them: no New item, no Save item.
        XCTAssertEqual(
            items(in: menu).filter {
                let title = $0.title.lowercased()
                return title.hasPrefix("save") || title == "new" || title.hasPrefix("new note")
            }.map(\.title), [])
    }

    // MARK: - TP-6: File > New from Template lists the library's templates by name

    func testTP6_fileMenuHoldsNewFromTemplateWithADisabledPlaceholderWhenThereAreNoneAndClose() async throws {
        let delegate = try await launch()
        let file = try submenu(titled: MainMenu.fileMenuTitle, of: delegate.mainMenu)
        XCTAssertEqual(
            file.items.filter { !$0.isSeparatorItem }.map(\.title),
            [MainMenu.newFromTemplateItemTitle, MainMenu.closeItemTitle])
        XCTAssertEqual(MainMenu.newFromTemplateItemTitle, "New from Template", "as TP-6 names it")

        let newFromTemplate = try XCTUnwrap(file.items.first { $0.title == MainMenu.newFromTemplateItemTitle })
        assertShortcut(newFromTemplate, "")
        XCTAssertTrue(newFromTemplate.hasSubmenu, "the item only opens its submenu")
        let templates = try XCTUnwrap(newFromTemplate.submenu, "New from Template is a submenu")
        XCTAssertEqual(templates.title, MainMenu.newFromTemplateItemTitle)
        XCTAssertEqual(templates.items.map(\.title), [MainMenu.noTemplatesItemTitle], "one placeholder row at launch")
        XCTAssertEqual(delegate.libraryController?.templateNames, [], "this library has no templates/")
        XCTAssertEqual(
            try openTemplatesMenu(of: delegate).map(\.title), [MainMenu.noTemplatesItemTitle],
            "and the placeholder is what opening it shows")
        let placeholder = try XCTUnwrap(templates.items.first)
        XCTAssertNil(placeholder.action)
        XCTAssertNil(placeholder.target)
        assertShortcut(placeholder, "")
        XCTAssertTrue(templates.autoenablesItems)
        templates.update()
        XCTAssertFalse(placeholder.isEnabled, "no action, so the menu leaves it disabled")

        // Close moved here from the Window menu with the File menu's arrival; still Cmd-W.
        let close = try item(#selector(NSWindow.performClose(_:)), in: delegate.mainMenu)
        XCTAssertTrue(file.items.contains(close), "Close is in the File menu")
        assertShortcut(close, "w")
        XCTAssertEqual(
            items(in: delegate.mainMenu).filter { $0.action == #selector(NSWindow.performClose(_:)) }.count, 1,
            "and nowhere else")
    }

    func testTP6_openingTheSubmenuListsTheLibrarysTemplatesByNameAndFollowsTheWatcher() async throws {
        let delegate = try await launchWithTemplates()
        let controller = try controller(of: delegate)
        let library = try XCTUnwrap(delegate.libraryController)
        let menu = try templatesMenu(of: delegate)
        XCTAssertEqual(menu.items.map(\.title), [MainMenu.noTemplatesItemTitle], "nothing is built until it opens")

        let rows = try openTemplatesMenu(of: delegate)
        XCTAssertEqual(rows.map(\.title), Self.templateNames, "every template, by name, in the library's order")
        XCTAssertEqual(rows.map { $0.representedObject as? String }, Self.templateNames, "each row names its template")
        for row in rows {
            XCTAssertEqual(row.action, #selector(MainWindowController.newFromTemplate(_:)), row.title)
            XCTAssertNil(row.target, "\(row.title) goes down the responder chain")
            XCTAssertFalse(row.hasSubmenu)
            assertShortcut(row, "")
            XCTAssertTrue(controller.validateMenuItem(row), "\(row.title) is available with a library open")
        }
        let first = try XCTUnwrap(rows.first)
        XCTAssertFalse(
            makeMainWindowController(autosaveClock: ManualAutosaveClock()).validateMenuItem(first),
            "and not without one")
        XCTAssertEqual(
            try openTemplatesMenu(of: delegate).map(\.title), Self.templateNames, "opening again rebuilds the same rows"
        )

        // TP-7: a template that arrives on disk is listed next time the submenu opens, and one
        // that goes is not, through the real watcher.
        try writeTemplate("weekly", "---\npath: weekly/{{date:yyyy}}-W{{date:ww}}\n---\n")
        await waitUntil("weekly listed") { library.templateNames.contains("weekly") }
        XCTAssertEqual(try openTemplatesMenu(of: delegate).map(\.title), ["daily", "headless", "meeting", "weekly"])
        try FileManager.default.removeItem(at: url("\(TemplateStore.folderName)/headless.md"))
        await waitUntil("headless gone") { !library.templateNames.contains("headless") }
        XCTAssertEqual(try openTemplatesMenu(of: delegate).map(\.title), ["daily", "meeting", "weekly"])
    }

    func testTP6_choosingATemplateWhosePathNeedsNoTitleCreatesAndOpensTheNote() async throws {
        let delegate = try await launchWithTemplates()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        controller.search(for: "gam")
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma])
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView), "focus anywhere: the menu is global")
        let before = try filesOnDisk()

        let created = NoteID(relativePath: "daily/2026-09-09.md")
        let reported = try await chooseAndSettle(try templateItem("daily", in: delegate), in: delegate)
        XCTAssertEqual(reported, created, "TP-5 with no title: the path needs none, so the note is made")
        XCTAssertEqual(try String(contentsOf: url(created.relativePath), encoding: .utf8), "# Wednesday\n")
        XCTAssertEqual(try filesOnDisk(), (before + [created.relativePath]).sorted(), "and nothing else")
        XCTAssertNil(controller.inlineMessage)
        await waitUntil("editor shows the new note") {
            controller.editorController.noteID == created && controller.editorController.body != nil
        }
        XCTAssertEqual(controller.mainView.textView.string, "# Wednesday\n")
        XCTAssertTrue(window.firstResponder === controller.mainView.textView, "the editor is focused (TP-4)")
        XCTAssertEqual(controller.query, "gam", "the query is left as it was")
        XCTAssertFalse(controller.listController.isShowingTemplates)

        // Choosing it again opens the same note and writes nothing (TP-4).
        let again = try await chooseAndSettle(try templateItem("daily", in: delegate), in: delegate)
        XCTAssertEqual(again, created)
        XCTAssertEqual(try filesOnDisk(), (before + [created.relativePath]).sorted())
    }

    func testTP6_choosingATemplateWhosePathNeedsATitlePromptsInTheSearchFieldAndEnterThenCreatesIt() async throws {
        let delegate = try await launchWithTemplates()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        try await select(alpha, in: delegate)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        let before = try filesOnDisk()

        let reported = try await chooseAndSettle(try templateItem("meeting", in: delegate), in: delegate)
        XCTAssertNil(reported, "nothing is created without a title")
        XCTAssertEqual(try filesOnDisk(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("meetings").path), "no folder was made either")

        // The prompt: template mode on that template, focus in the field after the name,
        // ready for the title, and the ask under the field.
        XCTAssertEqual(controller.mainView.searchField.stringValue, "@meeting ")
        XCTAssertEqual(controller.query, "@meeting ")
        XCTAssertTrue(controller.isInTemplateMode)
        XCTAssertTrue(controller.listController.isShowingTemplates)
        XCTAssertEqual(controller.listController.templateRows?.map(\.name), ["meeting"])
        XCTAssertEqual(controller.listController.selectedTemplate?.name, "meeting", "selected, so Enter acts on it")
        XCTAssertNil(controller.listController.selectedEntry, "no note is selected in template mode")
        let editor = try searchFieldEditor(controller)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 9, length: 0), "the caret is after the space")
        let message = try XCTUnwrap(controller.inlineMessage)
        XCTAssertTrue(message.contains("needs a title"), message)
        XCTAssertTrue(message.contains("meeting"), message)
        XCTAssertFalse(controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(controller.mainView.messageLabel.stringValue, message)

        // Typing the title clears the ask; Enter creates the note as TP-5 does.
        for character in "Standup" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
        XCTAssertEqual(controller.query, "@meeting Standup")
        XCTAssertNil(controller.inlineMessage)
        XCTAssertTrue(controller.mainView.messageLabel.isHidden)
        let settled = expectation(description: "instantiation settled")
        var created: NoteID?
        controller.onInstantiateTemplate = { id in
            created = id
            settled.fulfill()
        }
        window.sendEvent(try keyDown("\r", modifiers: [], keyCode: 36, in: window))
        await fulfillment(of: [settled], timeout: 10)
        controller.onInstantiateTemplate = nil
        let note = NoteID(relativePath: "meetings/2026-09-09/Standup.md")
        XCTAssertEqual(created, note)
        XCTAssertEqual(try String(contentsOf: url(note.relativePath), encoding: .utf8), "# Standup\n\n\n")
        await waitUntil("editor shows the new note") {
            controller.editorController.noteID == note && controller.editorController.body != nil
        }
    }

    func testTP2_choosingATemplateThatDoesNotParseIsRefusedInlineAndCreatesNothing() async throws {
        let delegate = try await launchWithTemplates()
        let controller = try controller(of: delegate)
        controller.search(for: "gam")
        let before = try filesOnDisk()

        let reported = try await chooseAndSettle(try templateItem("headless", in: delegate), in: delegate)
        XCTAssertNil(reported)
        XCTAssertEqual(controller.inlineMessage, TemplateParser.Rejection.missingHeader.message)
        XCTAssertFalse(controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(try filesOnDisk(), before, "nothing was created")
        XCTAssertEqual(controller.query, "gam", "the query is left as it was: there is no title to ask for")
        XCTAssertFalse(controller.listController.isShowingTemplates)
        XCTAssertNil(controller.editorController.noteID)
    }

    // MARK: - E-7: the Edit menu carries undo and redo, and the clipboard

    func testE7_editMenuUndoAndRedoReachTheEditorThroughTheResponderChain() async throws {
        let delegate = try await launch()
        let edit = try submenu(titled: MainMenu.editMenuTitle, of: delegate.mainMenu)
        XCTAssertEqual(
            edit.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Undo", "Redo", "Cut", "Copy", "Paste", MainMenu.pasteAndMatchStyleItemTitle, "Select All"])
        let undo = try item(Selector(("undo:")), in: edit)
        let redo = try item(Selector(("redo:")), in: edit)
        assertShortcut(undo, "z")
        assertShortcut(redo, "z", [.command, .shift])
        assertShortcut(try item(#selector(NSText.cut(_:)), in: edit), "x")
        assertShortcut(try item(#selector(NSText.copy(_:)), in: edit), "c")
        assertShortcut(try item(#selector(NSText.paste(_:)), in: edit), "v")
        // ED-14: Paste and Match Style is Cmd-Shift-V and reaches the editor's pasteAsPlainText.
        assertShortcut(try item(#selector(NSTextView.pasteAsPlainText(_:)), in: edit), "v", [.command, .shift])
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
        XCTAssertEqual(
            view.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                MainMenu.biggerItemTitle, MainMenu.smallerItemTitle, MainMenu.actualSizeItemTitle,
                MainMenu.hideBacklinksItemTitle,
            ])
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
        XCTAssertEqual(
            view.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                MainMenu.biggerItemTitle, MainMenu.smallerItemTitle, MainMenu.actualSizeItemTitle,
                MainMenu.hideBacklinksItemTitle,
            ], "only ours")
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

    // MARK: - W-4: closing the window hides it; the app keeps running

    func testW4_closingTheWindowHidesItAndDoesNotQuit() async throws {
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        let close = try item(#selector(NSWindow.performClose(_:)), in: delegate.mainMenu)
        let quit = try item(#selector(NSApplication.terminate(_:)), in: delegate.mainMenu)
        assertShortcut(close, "w")
        assertShortcut(quit, "q")
        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp),
            "the one window going away does not quit the app")

        // Some state to survive the hide: a query, a selection, the note in the editor.
        controller.search(for: "alpha")
        try await select(alpha, in: delegate)
        XCTAssertEqual(controller.mainView.textView.string, "alpha body")

        await asApplicationDelegate(delegate) {
            XCTAssertTrue(window.isVisible)
            window.performClose(nil)
        }
        XCTAssertFalse(window.isVisible, "closed: hidden")
        XCTAssertFalse(delegate.isMainWindowVisible)
        XCTAssertNotNil(delegate.mainWindowController?.window, "the window is kept, not released")
        XCTAssertTrue(delegate.libraryController?.phase == .ready, "the library is still open")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "alpha", "nothing in it is disturbed")
        XCTAssertEqual(controller.listController.selectedID, alpha)
        XCTAssertEqual(controller.editorController.noteID, alpha)

        // The close button does the same as Cmd-W: both go through `performClose`.
        delegate.showMainWindow()
        XCTAssertTrue(window.isVisible)
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        await asApplicationDelegate(delegate) { button.performClick(nil) }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(controller.editorController.noteID, alpha)
    }

    func testW4_aDockClickShowsTheHiddenWindowAgain() async throws {
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        try await select(alpha, in: delegate)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        await asApplicationDelegate(delegate) { window.performClose(nil) }
        XCTAssertFalse(window.isVisible)

        // A click on the Dock icon reaches the delegate as a reopen, which it handles itself.
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(window.isVisible, "shown again")
        XCTAssertEqual(controller.editorController.noteID, alpha, "on the note it was showing")

        // With the window already up a reopen leaves it as it is.
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertTrue(window.isVisible)
    }

    func testW4_theHotKeyShowsTheClosedWindowAgain() async throws {
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        delegate.activateApp = {}
        delegate.isAppActive = { true }
        controller.search(for: "alpha")
        await asApplicationDelegate(delegate) { window.performClose(nil) }
        XCTAssertFalse(window.isVisible)

        try XCTUnwrap(delegate.globalHotKey).fire()
        XCTAssertTrue(window.isVisible, "shown again by the hotkey (W-3)")
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor())
        XCTAssertIdentical(window.firstResponder, editor, "with the search field focused")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 5))
    }

    func testW4_closingKeepsUnsavedEditsForTheAutosaveAndQuitWritesThemFirst() async throws {
        let delegate = try await launch()
        let controller = try controller(of: delegate)
        let window = try window(of: delegate)
        try await select(alpha, in: delegate)
        let textView = controller.mainView.textView
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.insertText(
            " edited", replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
        XCTAssertTrue(controller.editorController.hasUnsavedEdits)

        // Closing hides; the edit is still pending, as it would be with the window up (E-4).
        await asApplicationDelegate(delegate) { window.performClose(nil) }
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(controller.editorController.hasUnsavedEdits, "nothing is written by the hide alone")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(alpha.relativePath), encoding: .utf8), "alpha body")

        // Cmd-Q asks the delegate, which writes the edit before the app goes (E-4).
        var replies: [Bool] = []
        let replied = expectation(description: "termination resumed")
        delegate.replyToTerminate = { _, shouldTerminate in
            replies.append(shouldTerminate)
            replied.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater, "the quit waits for the write")
        await fulfillment(of: [replied], timeout: 10)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(alpha.relativePath), encoding: .utf8),
            "alpha body edited")
    }

    func testW4_closingTheWindowWhilePreferencesIsOpenHidesOnlyTheMainWindow() async throws {
        let delegate = try await launch()
        let window = try window(of: delegate)
        delegate.showPreferences(nil)
        let preferences = try XCTUnwrap(delegate.preferencesWindowController?.window)
        XCTAssertTrue(preferences.isVisible)

        await asApplicationDelegate(delegate) { window.performClose(nil) }
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(preferences.isVisible, "Settings stays up")
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}
