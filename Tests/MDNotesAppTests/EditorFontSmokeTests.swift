import AppKit
import MDNotesApp
import XCTest

/// Headless smoke tests for the editor font (E-8, ADR-0010): the system font at the size in
/// `UserDefaults` when the window is built, applied again when the defaults change; the View
/// menu's Bigger, Smaller and Actual Size moving the size within 9 to 36 pt and storing it;
/// and the v1 family preference deleted at launch.
@MainActor
final class EditorFontSmokeTests: XCTestCase {
    private let keys = [
        EditorFontPreference.staleFamilyDefaultsKey, EditorFontPreference.sizeDefaultsKey,
        MainView.listHeightDefaultsKey,
    ]
    private var root: URL = FileManager.default.temporaryDirectory

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-fonts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try await super.tearDown()
    }

    private func system(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size) }
    private func mono(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }

    private var storedSize: Double? {
        (UserDefaults.standard.object(forKey: EditorFontPreference.sizeDefaultsKey) as? NSNumber)?.doubleValue
    }

    // MARK: - Fixture

    /// Main-actor box so a delegate can ride inside a `@Sendable` teardown block.
    @MainActor
    private final class DelegateBox {
        let delegate: AppDelegate
        init(_ delegate: AppDelegate) { self.delegate = delegate }
    }

    /// A delegate launched against the empty `root` through the real launch path. Its hotkey
    /// is released at teardown, so the next test can register it again, and its windows are
    /// closed.
    private func launch() async throws -> AppDelegate {
        let controller = makeMainWindowController()
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
        let deadline = Date().addingTimeInterval(20)
        while library.phase != .ready {
            if Date() > deadline { throw XCTSkip("library did not become ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
        return delegate
    }

    /// Every item of `menu` and its submenus, in menu order.
    private func items(in menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { [$0] + items(in: $0.submenu) }
    }

    private func item(_ action: Selector, in menu: NSMenu?) throws -> NSMenuItem {
        try XCTUnwrap(items(in: menu).first { $0.action == action }, "an item with action \(action)")
    }

    /// Sends `item`'s action down the responder chain from the window's first responder, as
    /// the menu does for the key window. Returns whether a responder took it.
    @discardableResult
    private func perform(_ item: NSMenuItem, in window: NSWindow) throws -> Bool {
        let action = try XCTUnwrap(item.action)
        return (window.firstResponder ?? window).tryToPerform(action, with: item)
    }

    // MARK: - E-8: the system font at the stored size

    func testE8_defaultIsTheSystemFontAt13pt() {
        XCTAssertEqual(EditorFontPreference.defaultSize, 13)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), system(13))
        XCTAssertEqual(EditorFontPreference.codeFont(ofSize: 13), mono(13))
        XCTAssertNotEqual(system(13).familyName, mono(13).familyName, "prose and code are different faces")

        let controller = makeMainWindowController()
        let textView = controller.mainView.textView
        XCTAssertEqual(textView.font, system(13))
        XCTAssertEqual(textView.typingAttributes[.font] as? NSFont, system(13), "typed text gets it too")
        XCTAssertEqual(controller.editorController.styler.baseFont, system(13))
        XCTAssertEqual(controller.editorController.styler.codeFont, mono(13))
    }

    func testE8_sizeIsReadFromUserDefaultsAndHeldWithin9To36() throws {
        UserDefaults.standard.set(15, forKey: EditorFontPreference.sizeDefaultsKey)
        let controller = makeMainWindowController()
        XCTAssertEqual(controller.mainView.textView.font, system(15))
        XCTAssertEqual(controller.editorController.styler.codeFont, mono(15), "code follows the size")

        // v1's Settings field allowed 6 to 72; those are read as the nearest bound now.
        UserDefaults.standard.set(6, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.size(from: .standard), 9)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), system(9))
        UserDefaults.standard.set(72, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.size(from: .standard), 36)
        UserDefaults.standard.set(11.5, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.size(from: .standard), 11.5, "a fraction within the range is kept")

        // Numbers below the range, however far, are read as 9; anything that is not a finite
        // number falls back to 13.
        UserDefaults.standard.set(-3, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), system(9))
        UserDefaults.standard.set(0, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), system(9))
        UserDefaults.standard.set("large", forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), system(13))
        UserDefaults.standard.set(Double.nan, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), system(13))
        UserDefaults.standard.set(Double.infinity, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), system(13))

        // setSize clamps too, and drops what is not a finite number.
        EditorFontPreference.setSize(100, in: .standard)
        XCTAssertEqual(storedSize, 36)
        EditorFontPreference.setSize(2, in: .standard)
        XCTAssertEqual(storedSize, 9)
        EditorFontPreference.setSize(.nan, in: .standard)
        XCTAssertEqual(storedSize, 9, "not stored")
        EditorFontPreference.setSize(20, in: .standard)
        XCTAssertEqual(storedSize, 20)
    }

    func testE8_thereIsNoFamilyPreference() {
        // A stored family from v1 changes nothing: the font is the system font regardless.
        UserDefaults.standard.set("Menlo", forKey: EditorFontPreference.staleFamilyDefaultsKey)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), system(13))
        let controller = makeMainWindowController()
        XCTAssertEqual(controller.mainView.textView.font, system(13))
        XCTAssertEqual(try XCTUnwrap(controller.mainView.textView.font).familyName, system(13).familyName)
    }

    func testE8_changingTheSizeRestylesTheEditor() throws {
        let controller = makeMainWindowController()
        let textView = controller.mainView.textView
        XCTAssertEqual(textView.font, system(13))

        UserDefaults.standard.set(16, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(textView.font, system(16))
        XCTAssertEqual(textView.typingAttributes[.font] as? NSFont, system(16))
        XCTAssertEqual(controller.editorController.styler.baseFont, system(16))
        XCTAssertEqual(controller.editorController.styler.codeFont, mono(16))

        // Removing the preference goes back to the default.
        UserDefaults.standard.removeObject(forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(textView.font, system(13))
    }

    // MARK: - E-8: Bigger, Smaller and Actual Size in the View menu

    func testE8_viewMenuHasBiggerSmallerAndActualSizeWithCommandPlusMinusAndZero() throws {
        let menu = MainMenu.make().mainMenu
        let view = try XCTUnwrap(menu.items.first { $0.title == MainMenu.viewMenuTitle }?.submenu)
        XCTAssertEqual(
            view.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                MainMenu.biggerItemTitle, MainMenu.smallerItemTitle, MainMenu.actualSizeItemTitle,
                MainMenu.hideBacklinksItemTitle,
            ])
        XCTAssertEqual(MainMenu.biggerItemTitle, "Bigger")
        XCTAssertEqual(MainMenu.smallerItemTitle, "Smaller")
        XCTAssertEqual(MainMenu.actualSizeItemTitle, "Actual Size")
        let bigger = try item(#selector(MainWindowController.makeTextBigger(_:)), in: view)
        let smaller = try item(#selector(MainWindowController.makeTextSmaller(_:)), in: view)
        let actual = try item(#selector(MainWindowController.makeTextActualSize(_:)), in: view)
        for (item, key) in [(bigger, "+"), (smaller, "-"), (actual, "0")] {
            XCTAssertEqual(item.keyEquivalent, key, item.title)
            XCTAssertEqual(item.keyEquivalentModifierMask, .command, item.title)
            XCTAssertNil(item.target, "\(item.title) goes down the responder chain")
        }
    }

    func testE8_zoomActionsMoveTheSizeOnePointAtATimeClampAndPersist() async throws {
        let delegate = try await launch()
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let window = try XCTUnwrap(controller.window)
        let textView = controller.mainView.textView
        XCTAssertTrue(window.makeFirstResponder(textView))
        let bigger = try item(#selector(MainWindowController.makeTextBigger(_:)), in: delegate.mainMenu)
        let smaller = try item(#selector(MainWindowController.makeTextSmaller(_:)), in: delegate.mainMenu)
        let actual = try item(#selector(MainWindowController.makeTextActualSize(_:)), in: delegate.mainMenu)
        XCTAssertNil(storedSize)
        XCTAssertEqual(textView.font, system(13))

        XCTAssertTrue(try perform(bigger, in: window), "Bigger found the window controller from the editor")
        XCTAssertEqual(storedSize, 14, "persisted in EditorFontSize")
        XCTAssertEqual(textView.font, system(14), "the editor follows at once")
        XCTAssertEqual(controller.editorController.styler.codeFont, mono(14))
        XCTAssertTrue(try perform(bigger, in: window))
        XCTAssertEqual(storedSize, 15)

        XCTAssertTrue(try perform(smaller, in: window))
        XCTAssertEqual(storedSize, 14)
        XCTAssertEqual(textView.font, system(14))

        XCTAssertTrue(try perform(actual, in: window))
        XCTAssertEqual(storedSize, 13, "Actual Size stores the default rather than removing the key")
        XCTAssertEqual(textView.font, system(13))

        // Up to 36 and no further: Bigger stops there and the item is disabled.
        for _ in 0..<30 { try perform(bigger, in: window) }
        XCTAssertEqual(storedSize, 36)
        XCTAssertEqual(textView.font, system(36))
        XCTAssertFalse(controller.validateMenuItem(bigger), "at the top, Bigger is disabled")
        XCTAssertTrue(controller.validateMenuItem(smaller))
        XCTAssertTrue(controller.validateMenuItem(actual))
        XCTAssertTrue(try perform(bigger, in: window), "still answered")
        XCTAssertEqual(storedSize, 36, "but clamped")

        // Down to 9 and no further.
        for _ in 0..<30 { try perform(smaller, in: window) }
        XCTAssertEqual(storedSize, 9)
        XCTAssertEqual(textView.font, system(9))
        XCTAssertFalse(controller.validateMenuItem(smaller), "at the bottom, Smaller is disabled")
        XCTAssertTrue(controller.validateMenuItem(bigger))
        XCTAssertTrue(try perform(smaller, in: window))
        XCTAssertEqual(storedSize, 9)

        XCTAssertTrue(try perform(actual, in: window))
        XCTAssertEqual(storedSize, 13)
        XCTAssertFalse(controller.validateMenuItem(actual), "at 13, Actual Size is disabled")
        XCTAssertTrue(controller.validateMenuItem(bigger))
        XCTAssertTrue(controller.validateMenuItem(smaller))

        // From a v1 size outside the range, one step lands within it.
        UserDefaults.standard.set(72, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(textView.font, system(36))
        XCTAssertTrue(try perform(smaller, in: window))
        XCTAssertEqual(storedSize, 35)
        UserDefaults.standard.set(6, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertTrue(try perform(bigger, in: window))
        XCTAssertEqual(storedSize, 10)

        // The size survives a rebuild of the window, as it does a relaunch.
        let again = makeMainWindowController()
        XCTAssertEqual(again.mainView.textView.font, system(10))
        again.close()
    }

    func testE8_zoomActionsAreAnsweredFromTheSearchFieldAndTheList() async throws {
        let delegate = try await launch()
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let window = try XCTUnwrap(controller.window)
        let bigger = try item(#selector(MainWindowController.makeTextBigger(_:)), in: delegate.mainMenu)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        XCTAssertTrue(try perform(bigger, in: window), "from the search field's editor")
        XCTAssertEqual(storedSize, 14)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.tableView))
        XCTAssertTrue(try perform(bigger, in: window), "from the list")
        XCTAssertEqual(storedSize, 15)
    }

    // MARK: - E-8, ADR-0010: the v1 family preference is deleted at launch

    func testE8_staleFamilyKeyIsGoneAfterLaunch() async throws {
        UserDefaults.standard.set("Menlo", forKey: EditorFontPreference.staleFamilyDefaultsKey)
        UserDefaults.standard.set(15, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.staleFamilyDefaultsKey, "EditorFontFamily")

        let delegate = try await launch()

        XCTAssertNil(UserDefaults.standard.object(forKey: EditorFontPreference.staleFamilyDefaultsKey), "deleted")
        XCTAssertEqual(storedSize, 15, "the size preference is kept")
        XCTAssertEqual(delegate.mainWindowController?.mainView.textView.font, system(15))

        // Settings has no font controls any more (PR-1): the folder row and the hotkey row only.
        delegate.showPreferences(nil)
        let preferences = try XCTUnwrap(delegate.preferencesWindowController)
        let content = try XCTUnwrap(preferences.window?.contentView)
        XCTAssertTrue(preferences.chooseButton.isDescendant(of: content))
        XCTAssertTrue(preferences.hotKeyRecorder.isDescendant(of: content))
        XCTAssertEqual(controls(in: content).filter { $0 is NSPopUpButton || $0 is NSStepper }.count, 0)
        XCTAssertEqual(
            controls(in: content).compactMap { ($0 as? NSTextField)?.stringValue }.filter { $0.hasSuffix(":") },
            ["Notes folder:", "Global shortcut:"])
    }

    private func controls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { ($0 as? NSControl).map { [$0] } ?? [] } + view.subviews.flatMap { controls(in: $0) }
    }

    // MARK: - V-1: the editor rendered with prose and code

    func testV1_editorSnapshotShowsProseAndCodeInTheirFonts() throws {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        let textView = controller.mainView.textView
        textView.string = """
            # Meeting notes

            Prose is set in the system font, with a [[Wikilink]] and a #tag, and some `inline code`.

            ```swift
            let answer = 42  // fenced code is monospaced
            ```

            More prose after the block.

            """
        controller.mainView.layoutSubtreeIfNeeded()
        let storage = try XCTUnwrap(textView.textStorage)
        let text = textView.string as NSString
        let inline = text.range(of: "`inline code`")
        let fenced = text.range(of: "let answer")
        let prose = text.range(of: "Prose is")
        XCTAssertEqual(storage.attribute(.font, at: inline.location, effectiveRange: nil) as? NSFont, mono(13))
        XCTAssertEqual(storage.attribute(.font, at: fenced.location, effectiveRange: nil) as? NSFont, mono(13))
        XCTAssertEqual(storage.attribute(.font, at: prose.location, effectiveRange: nil) as? NSFont, system(13))
        let written = try writeWindowSnapshots(of: controller, named: "editor-fonts")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }
}
