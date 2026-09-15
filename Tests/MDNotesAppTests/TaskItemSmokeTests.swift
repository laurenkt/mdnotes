import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for task items (ED-6): the box in the monospaced font so `[ ]` and
/// `[x]` take the same width, a done item's content in secondary label colour, and a plain
/// click on the box toggling it as one undoable edit that autosaves. Styling goes through the
/// real text view's storage as a load does; the click is a real `NSEvent` delivered to the
/// editor as the window would deliver it; undo is the `undo:` action sent up the responder
/// chain, as Cmd-Z is; the autosave runs on a manual clock over a real library on disk.
@MainActor
final class TaskItemSmokeTests: XCTestCase {
    private let keys = [EditorFontPreference.sizeDefaultsKey, MainView.listHeightDefaultsKey]
    private var root: URL = FileManager.default.temporaryDirectory

    private static let tasksBody = "- [ ] Buy milk\n- [x] Post the letter\n1. [ ] Ordered task\nplain [x] not a box\n"
    private static let notes: [(path: String, body: String)] = [
        ("Other.md", "other body"),
        ("Tasks.md", tasksBody),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let tasks = NoteID(relativePath: "Tasks.md")
    private let other = NoteID(relativePath: "Other.md")

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-tasks-\(UUID().uuidString)", isDirectory: true)
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
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try await super.tearDown()
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let clock: ManualAutosaveClock
        var window: NSWindow? { controller.window }
        var editor: EditorController { controller.editorController }
        var textView: NSTextView { controller.mainView.textView }
        var storage: NSTextStorage { textView.textStorage ?? NSTextStorage() }
        var styler: EditorStyler { editor.styler }
        var table: NSTableView { controller.mainView.tableView }

        /// Puts `text` in the editor as a load does, and makes it editable so typing works.
        func show(_ text: String) {
            textView.string = text
            textView.isEditable = true
        }

        func attributes(at location: Int) -> [NSAttributedString.Key: Any] {
            storage.attributes(at: location, effectiveRange: nil)
        }

        func style(at location: Int) -> EditorStyler.TokenStyle? {
            (attributes(at: location)[EditorStyler.tokenAttribute] as? String).flatMap(EditorStyler.TokenStyle.init)
        }

        func color(at location: Int) -> NSColor? { attributes(at: location)[.foregroundColor] as? NSColor }
        func font(at location: Int) -> NSFont? { attributes(at: location)[.font] as? NSFont }

        func colors(in range: NSRange) -> [NSColor?] {
            (range.location..<(range.location + range.length)).map { color(at: $0) }
        }

        func fonts(in range: NSRange) -> [NSFont?] {
            (range.location..<(range.location + range.length)).map { font(at: $0) }
        }

        func styles(in range: NSRange) -> [EditorStyler.TokenStyle?] {
            (range.location..<(range.location + range.length)).map { style(at: $0) }
        }
    }

    /// A laid-out window on a manual clock, with no library: enough for styling.
    private func makeFixture() -> Fixture {
        let clock = ManualAutosaveClock()
        let controller = makeMainWindowController(autosaveClock: clock)
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        return Fixture(controller: controller, clock: clock)
    }

    /// The fixture with the library on disk attached and ready, `Tasks.md` shown and the
    /// editor focused with the caret at the end of the text.
    private func makeFixtureShowingTasks() async throws -> Fixture {
        let fixture = makeFixture()
        let library = LibraryController(root: root)
        fixture.controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(fixture.controller.listController.results.map(\.id), [tasks, other])
        let row = try XCTUnwrap(fixture.controller.listController.results.firstIndex { $0.id == tasks })
        fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntil("editor shows Tasks.md") { fixture.editor.noteID == tasks && fixture.editor.body != nil }
        XCTAssertEqual(fixture.textView.string, Self.tasksBody)
        let window = try XCTUnwrap(fixture.window)
        XCTAssertTrue(window.makeFirstResponder(fixture.textView))
        fixture.textView.setSelectedRange(NSRange(location: (Self.tasksBody as NSString).length, length: 0))
        return fixture
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

    private func range(of needle: String, in text: String, occurrence: Int = 0) -> NSRange {
        var search = NSRange(location: 0, length: (text as NSString).length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = (text as NSString).range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let next = found.location + found.length
            search = NSRange(location: next, length: (text as NSString).length - next)
        }
        XCTAssertNotEqual(found.location, NSNotFound, "\(needle) is in the text")
        return found
    }

    private func width(of text: String, in font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    /// The x position, in the text container, of the glyph for the character at `location`.
    private func glyphX(at location: Int, in layoutManager: NSLayoutManager) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return fragment.minX + layoutManager.location(forGlyphAt: glyph).x
    }

    /// The advance the three characters of the box starting at `location` take on their line.
    private func boxAdvance(at location: Int, in layoutManager: NSLayoutManager) -> CGFloat {
        glyphX(at: location + 3, in: layoutManager) - glyphX(at: location, in: layoutManager)
    }

    /// The point, in the window's coordinates, at the centre of the character at `index`.
    private func centre(ofCharacterAt index: Int, in fixture: Fixture) throws -> NSPoint {
        let window = try XCTUnwrap(fixture.window)
        // The editor's layout manager lays out lazily (ED-8): the character's rect is an
        // estimate until its line has been laid out.
        if let layoutManager = fixture.textView.layoutManager, let container = fixture.textView.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        let screenRect = fixture.textView.firstRect(
            forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, "the character has been laid out")
        let windowRect = window.convertFromScreen(screenRect)
        return NSPoint(x: windowRect.midX, y: windowRect.midY)
    }

    /// Sends a plain click on the character at `index` of the editor's text: a mouse-down then
    /// a mouse-up at the character's centre, delivered to the editor as `NSWindow.sendEvent`
    /// would deliver them; a window that has never been on screen does not dispatch mouse
    /// events itself.
    private func click(onCharacterAt index: Int, in fixture: Fixture) throws {
        let window = try XCTUnwrap(fixture.window)
        let textView = fixture.textView
        let point = try centre(ofCharacterAt: index, in: fixture)
        XCTAssertIdentical(window.contentView?.hitTest(point), textView, "the point is over the editor")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { textView.mouseDown(with: event) } else { textView.mouseUp(with: event) }
        }
    }

    /// Lets the run loop turn once, which closes the undo group open for the current event.
    private func turn() async {
        try? await Task.sleep(for: .milliseconds(1))
    }

    /// Cmd-Z: the Undo menu item's action, sent up the responder chain from the text view.
    private func undo(_ fixture: Fixture) {
        XCTAssertTrue(fixture.textView.tryToPerform(Selector(("undo:")), with: nil), "nothing handled undo:")
    }

    /// Cmd-Shift-Z.
    private func redo(_ fixture: Fixture) {
        XCTAssertTrue(fixture.textView.tryToPerform(Selector(("redo:")), with: nil), "nothing handled redo:")
    }

    /// Runs `trigger` and waits for the editor's next `onSave`.
    private func saveAfter(_ fixture: Fixture, _ trigger: () throws -> Void) async throws {
        let saved = expectation(description: "note saved")
        fixture.editor.onSave = { _, _ in saved.fulfill() }
        try trigger()
        await fulfillment(of: [saved], timeout: 10)
        fixture.editor.onSave = nil
    }

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    /// The prose font: the system font at 13 pt (E-8).
    private var base: NSFont { NSFont.systemFont(ofSize: 13) }
    /// The monospaced font at the same size, which a task box is set in (ED-6, E-8).
    private var mono: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
    private var tertiary: NSColor { EditorStyler.markerColor }
    private var secondary: NSColor { EditorStyler.doneItemColor }

    // MARK: - ED-6 the box is monospaced at body size, so both boxes are the same width

    func testED6_boxesAreSetInTheMonospacedFontAtBodySizeAndTakeTheSameWidth() throws {
        let fixture = makeFixture()
        let text = Self.tasksBody
        fixture.show(text)
        let styler = fixture.styler
        XCTAssertEqual(secondary, .secondaryLabelColor)

        // The property the font is chosen for: a space and an x advance the same in it, and
        // not in the prose font.
        XCTAssertEqual(width(of: "[ ]", in: mono), width(of: "[x]", in: mono), accuracy: 0.001)
        XCTAssertNotEqual(width(of: "[ ]", in: base), width(of: "[x]", in: base), accuracy: 0.001)
        XCTAssertEqual(styler.codeFont, mono)

        let open = range(of: "[ ]", in: text)
        let done = range(of: "[x]", in: text)
        let ordered = range(of: "[ ]", in: text, occurrence: 1)
        for (name, box) in [("open", open), ("done", done), ("ordered", ordered)] {
            XCTAssertEqual(fixture.fonts(in: box), Array(repeating: mono, count: 3), "\(name): the box is monospaced")
            XCTAssertEqual(fixture.styles(in: box), Array(repeating: .taskBox, count: 3), name)
            XCTAssertEqual(
                fixture.colors(in: box), Array(repeating: styler.baseColor, count: 3),
                "\(name): the box keeps the text colour, its brackets undimmed")
            XCTAssertEqual(fixture.font(at: box.location - 1), base, "\(name): the space before it is prose")
            XCTAssertEqual(fixture.font(at: box.location + 3), base, "\(name): the space after it is prose")
            XCTAssertEqual(fixture.color(at: box.location - 2), tertiary, "\(name): the list marker is dimmed (ED-2)")
        }

        // Laid out, the two boxes advance the same and the item text after each starts at the
        // same x.
        let layoutManager = try XCTUnwrap(fixture.textView.layoutManager)
        let container = try XCTUnwrap(fixture.textView.textContainer)
        layoutManager.ensureLayout(for: container)
        XCTAssertEqual(
            boxAdvance(at: open.location, in: layoutManager), boxAdvance(at: done.location, in: layoutManager),
            accuracy: 0.01, "[ ] and [x] take the same advance")
        XCTAssertEqual(
            glyphX(at: range(of: "Buy", in: text).location, in: layoutManager),
            glyphX(at: range(of: "Post", in: text).location, in: layoutManager), accuracy: 0.01,
            "so the item text after either starts at the same place")

        // Only a box after a list marker is one (ED-1).
        let plain = range(of: "[x] not", in: text)
        XCTAssertEqual(fixture.fonts(in: plain), Array(repeating: base, count: plain.length))
        XCTAssertEqual(fixture.styles(in: plain), Array(repeating: nil, count: plain.length))
        XCTAssertEqual(fixture.textView.string, text, "the text is exactly what went in (E-1)")
    }

    func testED6_boxesFollowCmdPlusAndCmdMinus() throws {
        let fixture = makeFixture()
        let text = Self.tasksBody
        fixture.show(text)
        let box = range(of: "[x]", in: text)

        fixture.controller.makeTextBigger(nil)
        let bigger = EditorFontPreference.size()
        XCTAssertGreaterThan(bigger, 13)
        XCTAssertEqual(
            fixture.fonts(in: box),
            Array(repeating: NSFont.monospacedSystemFont(ofSize: bigger, weight: .regular), count: 3),
            "the box follows the body size")
        XCTAssertEqual(fixture.font(at: box.location + 4), NSFont.systemFont(ofSize: bigger))

        fixture.controller.makeTextActualSize(nil)
        XCTAssertEqual(fixture.fonts(in: box), Array(repeating: mono, count: 3))
    }

    // MARK: - ED-6 a done item's content is secondary

    func testED6_doneItemContentIsSecondaryAndAnOpenItemsIsNot() throws {
        let fixture = makeFixture()
        let text = Self.tasksBody
        fixture.show(text)
        let styler = fixture.styler

        let doneContent = range(of: "Post the letter", in: text)
        XCTAssertEqual(fixture.colors(in: doneContent), Array(repeating: secondary, count: doneContent.length))
        XCTAssertEqual(fixture.styles(in: doneContent), Array(repeating: .doneItem, count: doneContent.length))
        XCTAssertEqual(fixture.fonts(in: doneContent), Array(repeating: base, count: doneContent.length))
        XCTAssertEqual(
            fixture.color(at: doneContent.location - 1), styler.baseColor, "the space between box and content is not")

        let openContent = range(of: "Buy milk", in: text)
        XCTAssertEqual(fixture.colors(in: openContent), Array(repeating: styler.baseColor, count: openContent.length))
        XCTAssertEqual(fixture.styles(in: openContent), Array(repeating: .listItem, count: openContent.length))
        let orderedContent = range(of: "Ordered task", in: text)
        XCTAssertEqual(
            fixture.colors(in: orderedContent), Array(repeating: styler.baseColor, count: orderedContent.length))
    }

    func testED6_inlineTokensInADoneItemKeepTheirOwnStyling() throws {
        let fixture = makeFixture()
        let text = "- [X] done **bold** and [[Link]] and #tag and `code`\n"
        fixture.show(text)

        let box = range(of: "[X]", in: text)
        XCTAssertEqual(fixture.fonts(in: box), Array(repeating: mono, count: 3), "an upper-case X is ticked too")
        XCTAssertEqual(fixture.color(at: range(of: "done", in: text).location), secondary)
        let bold = range(of: "bold", in: text)
        XCTAssertEqual(fixture.colors(in: bold), Array(repeating: secondary, count: 4), "emphasis keeps the colour")
        XCTAssertTrue(fixture.font(at: bold.location)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertEqual(fixture.color(at: bold.location - 1), tertiary, "its markers are dimmed (ED-2)")
        XCTAssertEqual(fixture.color(at: range(of: "Link", in: text).location), NSColor.linkColor)
        XCTAssertEqual(fixture.color(at: range(of: "#tag", in: text).location + 1), NSColor.systemPurple)
        XCTAssertEqual(fixture.font(at: range(of: "code", in: text).location), mono)
        XCTAssertEqual(fixture.color(at: range(of: " and", in: text).location + 1), secondary)
    }

    func testED6_typingIntoTheBoxRestylesTheItem() {
        let fixture = makeFixture()
        let text = Self.tasksBody
        fixture.show(text)
        let open = range(of: "[ ]", in: text)
        let content = range(of: "Buy milk", in: text)

        fixture.textView.insertText("x", replacementRange: NSRange(location: open.location + 1, length: 1))
        XCTAssertEqual(fixture.textView.string, Self.tasksBody.replacingOccurrences(of: "[ ] Buy", with: "[x] Buy"))
        XCTAssertEqual(fixture.fonts(in: open), Array(repeating: mono, count: 3))
        XCTAssertEqual(fixture.colors(in: content), Array(repeating: secondary, count: content.length))

        fixture.textView.insertText(" ", replacementRange: NSRange(location: open.location + 1, length: 1))
        XCTAssertEqual(fixture.textView.string, Self.tasksBody)
        XCTAssertEqual(fixture.colors(in: content), Array(repeating: fixture.styler.baseColor, count: content.length))

        // A box that stops being one (no space after it) loses the font with the item.
        fixture.textView.insertText("", replacementRange: NSRange(location: open.location + 3, length: 1))
        XCTAssertEqual(fixture.fonts(in: open), Array(repeating: base, count: 3))
        XCTAssertNil(fixture.editor.taskBox(at: open.location))
    }

    // MARK: - ED-6 a plain click on the box toggles it

    func testED6_aClickOnTheBoxTogglesItLeavingTheCaretAlone() async throws {
        let fixture = try await makeFixtureShowingTasks()
        let text = Self.tasksBody
        let end = NSRange(location: (text as NSString).length, length: 0)
        let open = range(of: "[ ]", in: text)
        let done = range(of: "[x]", in: text)
        let ordered = range(of: "[ ]", in: text, occurrence: 1)
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)

        // Each of the three characters is the box.
        XCTAssertEqual(fixture.editor.taskBox(at: open.location)?.range, open)
        XCTAssertEqual(fixture.editor.taskBox(at: open.location + 1)?.range, open)
        XCTAssertEqual(fixture.editor.taskBox(at: open.location + 2)?.range, open)
        XCTAssertEqual(fixture.editor.taskBox(at: open.location)?.isDone, false)
        XCTAssertEqual(fixture.editor.taskBox(at: done.location + 1)?.isDone, true)
        XCTAssertNil(fixture.editor.taskBox(at: open.location - 1), "the space before it is not")
        XCTAssertNil(fixture.editor.taskBox(at: open.location + 3), "nor the one after")
        XCTAssertNil(fixture.editor.taskBox(at: range(of: "[x] not", in: text).location + 1), "not after a marker")
        XCTAssertNil(fixture.editor.taskBox(at: -1))
        XCTAssertNil(fixture.editor.taskBox(at: end.location))

        try click(onCharacterAt: open.location + 1, in: fixture)
        XCTAssertEqual(
            fixture.textView.string, text.replacingOccurrences(of: "[ ] Buy", with: "[x] Buy"),
            "a click on the space ticks it")
        XCTAssertEqual(fixture.textView.selectedRange(), end, "the caret did not move")
        XCTAssertIdentical(fixture.window?.firstResponder, fixture.textView, "focus stays in the editor")
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.colors(in: range(of: "Buy milk", in: text)), Array(repeating: secondary, count: 8))
        XCTAssertEqual(fixture.fonts(in: open), Array(repeating: mono, count: 3))

        try click(onCharacterAt: open.location, in: fixture)
        XCTAssertEqual(fixture.textView.string, text, "a click on the opening bracket unticks it")
        XCTAssertEqual(
            fixture.colors(in: range(of: "Buy milk", in: text)), Array(repeating: fixture.styler.baseColor, count: 8))

        try click(onCharacterAt: done.location + 2, in: fixture)
        XCTAssertEqual(
            fixture.textView.string, text.replacingOccurrences(of: "[x] Post", with: "[ ] Post"),
            "a click on the closing bracket unticks a done item")
        try click(onCharacterAt: done.location + 1, in: fixture)
        XCTAssertEqual(fixture.textView.string, text)

        try click(onCharacterAt: ordered.location + 1, in: fixture)
        XCTAssertEqual(
            fixture.textView.string, text.replacingOccurrences(of: "[ ] Ordered", with: "[x] Ordered"),
            "a box after an ordered marker toggles too")
        XCTAssertEqual(fixture.textView.selectedRange(), end)

        // A click anywhere else is the text view's, which places the caret: the handler
        // declines it and changes nothing. (The text view's own mouse-down tracks the mouse
        // until it is released, so the decline is checked at the handler, not by an event.)
        let milk = range(of: "milk", in: text)
        XCTAssertFalse(fixture.controller.toggleTaskBox(at: milk.location))
        XCTAssertFalse(fixture.controller.clickInEditor(at: milk.location))
        let notABox = range(of: "[x] not", in: text)
        XCTAssertFalse(
            fixture.controller.clickInEditor(at: notABox.location + 1),
            "brackets that are not after a list marker are not a box")
        XCTAssertFalse(fixture.controller.clickInEditor(at: open.location - 1), "the space before a box")
        XCTAssertFalse(fixture.controller.clickInEditor(at: open.location + 3), "and the one after")
        XCTAssertEqual(
            fixture.textView.string, text.replacingOccurrences(of: "[ ] Ordered", with: "[x] Ordered"),
            "and nothing changed")
        XCTAssertEqual(fixture.textView.selectedRange(), end)
    }

    func testED6_aToggleIsOneUndoableEdit() async throws {
        let fixture = try await makeFixtureShowingTasks()
        let text = Self.tasksBody
        let open = range(of: "[ ]", in: text)
        let manager = try XCTUnwrap(fixture.textView.undoManager)
        XCTAssertFalse(manager.canUndo, "loading registers nothing")

        try click(onCharacterAt: open.location + 1, in: fixture)
        let ticked = text.replacingOccurrences(of: "[ ] Buy", with: "[x] Buy")
        XCTAssertEqual(fixture.textView.string, ticked)
        XCTAssertTrue(manager.canUndo)

        undo(fixture)
        XCTAssertEqual(fixture.textView.string, text, "one undo restores the box")
        XCTAssertFalse(manager.canUndo, "and there was only the one edit to undo")
        XCTAssertEqual(fixture.fonts(in: open), Array(repeating: mono, count: 3), "styled as it was")
        XCTAssertEqual(
            fixture.colors(in: range(of: "Buy milk", in: text)), Array(repeating: fixture.styler.baseColor, count: 8))
        XCTAssertTrue(manager.canRedo)
        redo(fixture)
        XCTAssertEqual(fixture.textView.string, ticked)
        XCTAssertEqual(fixture.colors(in: range(of: "Buy milk", in: text)), Array(repeating: secondary, count: 8))
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, text)

        // Apart from typing on either side of it: two toggles are two steps, and typing
        // before one is its own. The undo manager closes a group at the end of each event, so
        // the run loop turns between these as it would between a key press and two clicks.
        fixture.textView.insertText("!", replacementRange: NSRange(location: (text as NSString).length, length: 0))
        await turn()
        try click(onCharacterAt: open.location + 1, in: fixture)
        await turn()
        try click(onCharacterAt: open.location + 1, in: fixture)
        await turn()
        XCTAssertEqual(fixture.textView.string, text + "!")
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, ticked + "!", "the second toggle is undone")
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, text + "!", "then the first")
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, text, "then the typing")
    }

    func testED6_aToggleAutosavesTheFile() async throws {
        let fixture = try await makeFixtureShowingTasks()
        let text = Self.tasksBody
        let open = range(of: "[ ]", in: text)
        XCTAssertEqual(try fileText(tasks), text)

        try click(onCharacterAt: open.location + 1, in: fixture)
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.clock.pendingCount, 1, "the autosave delay is running (E-4)")
        XCTAssertEqual(try fileText(tasks), text, "nothing is written before the delay")
        try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        XCTAssertEqual(
            try fileText(tasks), text.replacingOccurrences(of: "[ ] Buy", with: "[x] Buy"),
            "the file is exactly the text in the view (E-1)")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)

        try click(onCharacterAt: open.location + 1, in: fixture)
        try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        XCTAssertEqual(try fileText(tasks), text, "and back")
    }

    // MARK: - V-1

    func testV1_editorSnapshotShowsTaskItems() throws {
        let fixture = makeFixture()
        fixture.show(
            """
            # Tasks

            - [ ] Buy milk
            - [x] Post the letter
            - [ ] A task item that is long enough to wrap onto a second line, so the hanging indent can be seen under the item text past the box
            - [x] A done task that is also long enough to wrap onto a second line, its content in the secondary colour throughout
              - [ ] Nested open task with **bold** and a [[Link]]
              - [x] Nested done task with **bold**, a [[Link]] and a #tag
            1. [ ] An ordered open task
            2. [x] An ordered done task

            A plain paragraph with [x] in it, which is not a box.

            """)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        let text = fixture.textView.string
        XCTAssertEqual(fixture.font(at: range(of: "[x]", in: text).location), mono)
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-tasks")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }
}
