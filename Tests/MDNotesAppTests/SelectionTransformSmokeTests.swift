import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the editor's selection transforms (ED-16): the context menu's
/// Quote and Code Block items, present only with a selection, and what each does to the lines
/// the selection touches, as one undoable, restyled (E-3), autosaved (E-4) edit.
@MainActor
final class SelectionTransformSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    private static let alphaBody = "Intro line\nfirst line\nsecond line\nthird line\nOutro\n"
    private let alpha = NoteID(relativePath: "Alpha.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-transform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.alphaBody.utf8).write(to: root.appendingPathComponent("Alpha.md"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let library: LibraryController
        let clock: ManualAutosaveClock
        let window: NSWindow
        var editor: EditorController { controller.editorController }
        var textView: EditorTextView { controller.mainView.textView }

        /// Replaces the shown text as typing would, then clears the undo stack, so a test
        /// starts from its own body.
        func show(_ text: String) {
            textView.selectAll(nil)
            textView.insertText(text, replacementRange: textView.selectedRange())
            textView.undoManager?.removeAllActions()
        }

        /// Selects the storage range from the first occurrence of `from` to the end of the
        /// first occurrence of `to` after it.
        func select(from: String, to: String) {
            let string = textView.string as NSString
            let start = string.range(of: from)
            let end = string.range(
                of: to, range: NSRange(location: start.location, length: string.length - start.location))
            textView.setSelectedRange(NSRange(location: start.location, length: NSMaxRange(end) - start.location))
        }

        /// The selected text.
        var selection: String { (textView.string as NSString).substring(with: textView.selectedRange()) }
    }

    /// A laid-out window with a ready library attached, Alpha shown and the editor focused.
    private func makeFixture() async throws -> Fixture {
        let clock = ManualAutosaveClock()
        let controller = makeMainWindowController(autosaveClock: clock)
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.listController.select(alpha))
        await waitUntil("editor shows Alpha") {
            controller.editorController.noteID == self.alpha && controller.editorController.body != nil
        }
        XCTAssertEqual(controller.editorController.text, Self.alphaBody)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        return Fixture(controller: controller, library: library, clock: clock, window: window)
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

    /// Lets the run loop turn, which closes the undo group as the end of a key or menu event
    /// would.
    private func endOfEvent() async {
        try? await Task.sleep(for: .milliseconds(1))
    }

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    /// A right-click on the character at storage index `index`, as AppKit hands it to
    /// `menu(for:)`.
    private func rightClick(onCharacterAt index: Int, in fixture: Fixture) throws -> NSEvent {
        let textView = fixture.textView
        let onScreen = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        let inWindow = fixture.window.convertFromScreen(onScreen)
        return try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: inWindow.midX, y: inWindow.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    // MARK: ED-16 the menu items

    func testED16_menuItemsOnlyWithSelection() async throws {
        let fixture = try await makeFixture()
        let textView = fixture.textView
        fixture.select(from: "first", to: "second")
        let selected = textView.selectedRange()
        let menu = try XCTUnwrap(textView.menu(for: try rightClick(onCharacterAt: selected.location + 2, in: fixture)))
        XCTAssertEqual(textView.selectedRange(), selected, "the right-click keeps the selection")
        XCTAssertGreaterThan(menu.items.count, 3)
        XCTAssertEqual(menu.items[0].title, EditorTextView.quoteItemTitle)
        XCTAssertEqual(menu.items[1].title, EditorTextView.codeBlockItemTitle)
        XCTAssertTrue(menu.items[2].isSeparatorItem, "a separator between them and the standard items")
        XCTAssertTrue(
            menu.items.dropFirst(3).contains { $0.action == #selector(NSText.copy(_:)) },
            "the standard items follow")
        for item in menu.items.prefix(2) {
            XCTAssertIdentical(item.target as? EditorTextView, textView)
            XCTAssertTrue(textView.validateUserInterfaceItem(item), "\(item.title) enabled")
        }
        XCTAssertFalse(
            NSTextView.defaultMenu?.items.contains { $0.title == EditorTextView.quoteItemTitle } ?? false,
            "the shared standard menu is left alone")

        // With no selection neither item is there, even when the right-click selects the word
        // under the pointer, as `NSTextView` does.
        textView.setSelectedRange(NSRange(location: selected.location + 2, length: 0))
        let plain = textView.menu(for: try rightClick(onCharacterAt: textView.string.utf16.count - 2, in: fixture))
        let titles = plain?.items.map(\.title) ?? []
        XCTAssertFalse(titles.contains(EditorTextView.quoteItemTitle), "\(titles)")
        XCTAssertFalse(titles.contains(EditorTextView.codeBlockItemTitle), "\(titles)")
        fixture.select(from: "third", to: "third")
        let again = try rightClick(onCharacterAt: textView.selectedRange().location, in: fixture)
        let menuAgain = try XCTUnwrap(textView.menu(for: again))
        XCTAssertEqual(
            menuAgain.items.filter { $0.title == EditorTextView.quoteItemTitle }.count, 1,
            "one Quote item however often the menu is asked for")
    }

    // MARK: ED-16 Quote

    func testED16_quotePrefixesEachLine() async throws {
        let fixture = try await makeFixture()
        fixture.select(from: "first line", to: "third line")
        fixture.textView.quoteLines(nil)
        XCTAssertEqual(fixture.editor.text, "Intro line\n> first line\n> second line\n> third line\nOutro\n")
        XCTAssertEqual(fixture.selection, "> first line\n> second line\n> third line", "covers the lines")
        XCTAssertIdentical(fixture.window.firstResponder, fixture.textView)

        // A blank line among them is prefixed too.
        fixture.show("a\n\nb\n")
        fixture.textView.selectAll(nil)
        fixture.textView.quoteLines(nil)
        XCTAssertEqual(fixture.editor.text, "> a\n> \n> b\n")
    }

    func testED16_quoteTogglesOff() async throws {
        let fixture = try await makeFixture()
        fixture.select(from: "first line", to: "third line")
        fixture.textView.quoteLines(nil)
        fixture.textView.quoteLines(nil)
        XCTAssertEqual(fixture.editor.text, Self.alphaBody, "a second Quote takes the prefixes off")
        XCTAssertEqual(fixture.selection, "first line\nsecond line\nthird line")

        // Blank lines do not count against every line having it, and are left alone.
        fixture.show("> a\n\n> > b\nc\n")
        fixture.select(from: "> a", to: "> > b")
        fixture.textView.quoteLines(nil)
        XCTAssertEqual(fixture.editor.text, "a\n\n> b\nc\n", "one prefix off each line that has it")

        // A touched line without it: every line gets one more.
        fixture.show("> a\nb\n")
        fixture.textView.selectAll(nil)
        fixture.textView.quoteLines(nil)
        XCTAssertEqual(fixture.editor.text, "> > a\n> b\n")
    }

    func testED16_quotePartialLineSelectionWholeLines() async throws {
        let fixture = try await makeFixture()
        fixture.select(from: "st line", to: "sec")
        fixture.textView.quoteLines(nil)
        XCTAssertEqual(
            fixture.editor.text, "Intro line\n> first line\n> second line\nthird line\nOutro\n",
            "every line the selection touches, whole")
        XCTAssertEqual(fixture.selection, "> first line\n> second line")

        // A selection that ends just after a line break does not touch the line after it.
        fixture.show(Self.alphaBody)
        fixture.select(from: "Intro", to: "line\n")
        fixture.textView.quoteLines(nil)
        XCTAssertEqual(fixture.editor.text, "> Intro line\nfirst line\nsecond line\nthird line\nOutro\n")
    }

    // MARK: ED-16 Code Block

    func testED16_codeBlockWrapsLines() async throws {
        let fixture = try await makeFixture()
        fixture.select(from: "rst", to: "second")
        fixture.textView.codeBlockLines(nil)
        XCTAssertEqual(fixture.editor.text, "Intro line\n```\nfirst line\nsecond line\n```\nthird line\nOutro\n")
        XCTAssertEqual(fixture.selection, "```\nfirst line\nsecond line\n```", "covers the new block")

        // Restyled: the lines are code now, in the mono font (E-2, E-3, E-8).
        let storage = try XCTUnwrap(fixture.textView.textStorage)
        let inside = (fixture.textView.string as NSString).range(of: "second line")
        let font = try XCTUnwrap(storage.attribute(.font, at: inside.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.isFixedPitch, "\(font)")
        let outside = (fixture.textView.string as NSString).range(of: "third line")
        let prose = try XCTUnwrap(storage.attribute(.font, at: outside.location, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(prose.isFixedPitch, "\(prose)")

        // The last line of a text with no final line break.
        fixture.show("a\nb")
        fixture.select(from: "b", to: "b")
        fixture.textView.codeBlockLines(nil)
        XCTAssertEqual(fixture.editor.text, "a\n```\nb\n```")
        XCTAssertEqual(fixture.selection, "```\nb\n```")
    }

    func testED16_codeBlockTogglesOffFromInside() async throws {
        let fixture = try await makeFixture()
        fixture.show("Intro\n```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```\nOutro\n")
        fixture.select(from: "a = 1", to: "b =")
        fixture.textView.codeBlockLines(nil)
        XCTAssertEqual(
            fixture.editor.text, "Intro\nlet a = 1\nlet b = 2\nlet c = 3\nOutro\n",
            "lines inside a block: its two fence lines go")
        XCTAssertEqual(fixture.selection, "let a = 1\nlet b = 2\nlet c = 3", "covers the block's lines")

        // The block itself, fences included, toggles off too, and a round trip is exact.
        fixture.textView.codeBlockLines(nil)
        XCTAssertEqual(fixture.editor.text, "Intro\n```\nlet a = 1\nlet b = 2\nlet c = 3\n```\nOutro\n")
        fixture.textView.codeBlockLines(nil)
        XCTAssertEqual(fixture.editor.text, "Intro\nlet a = 1\nlet b = 2\nlet c = 3\nOutro\n")

        // A closing fence that ends the text goes with the line break before it.
        fixture.show("```\ncode\n```")
        fixture.select(from: "code", to: "code")
        fixture.textView.codeBlockLines(nil)
        XCTAssertEqual(fixture.editor.text, "code")

        // Lines reaching outside a block are wrapped, not unwrapped.
        fixture.show("before\n```\ncode\n```\n")
        fixture.select(from: "before", to: "code")
        fixture.textView.codeBlockLines(nil)
        XCTAssertEqual(fixture.editor.text, "```\nbefore\n```\ncode\n```\n```\n")
    }

    // MARK: ED-16 one undoable, autosaved edit

    func testED16_singleUndoStep() async throws {
        let fixture = try await makeFixture()
        let manager = try XCTUnwrap(fixture.textView.undoManager)
        fixture.textView.undoManager?.removeAllActions()
        // Typing just before is its own step.
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 0))
        fixture.textView.insertText("x", replacementRange: fixture.textView.selectedRange())
        await endOfEvent()
        let typed = "x" + Self.alphaBody

        fixture.select(from: "first line", to: "third line")
        fixture.textView.quoteLines(nil)
        await endOfEvent()
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        XCTAssertEqual(fixture.editor.text, typed, "one undo takes every prefix off, and only them")
        manager.redo()
        XCTAssertEqual(fixture.editor.text, "xIntro line\n> first line\n> second line\n> third line\nOutro\n")
        manager.undo()

        fixture.select(from: "first line", to: "second line")
        fixture.textView.codeBlockLines(nil)
        await endOfEvent()
        XCTAssertEqual(fixture.editor.text, "xIntro line\n```\nfirst line\nsecond line\n```\nthird line\nOutro\n")
        manager.undo()
        XCTAssertEqual(fixture.editor.text, typed, "one undo takes both fences out")
        manager.undo()
        XCTAssertEqual(fixture.editor.text, Self.alphaBody, "the typing before is a step of its own")
    }

    func testED16_fileUpdated() async throws {
        let fixture = try await makeFixture()
        fixture.select(from: "first line", to: "second line")
        fixture.textView.codeBlockLines(nil)
        fixture.select(from: "third line", to: "Outro")
        fixture.textView.quoteLines(nil)
        let expected = "Intro line\n```\nfirst line\nsecond line\n```\n> third line\n> Outro\n"
        XCTAssertEqual(fixture.editor.text, expected)
        XCTAssertTrue(fixture.editor.hasUnsavedEdits, "an edit like any other (E-4)")
        XCTAssertEqual(try fileText(alpha), Self.alphaBody, "not before the autosave delay")
        fixture.clock.advance(by: EditorController.autosaveDelay)
        await waitUntil("Alpha written") { (try? self.fileText(self.alpha)) == expected }
    }
}
