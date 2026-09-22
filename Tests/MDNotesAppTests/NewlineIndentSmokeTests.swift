import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for Return in the editor (ED-17): the line break carries the current
/// line's leading spaces and tabs (those before the caret, when it is within them) as one
/// undoable edit, and nothing else of the line; an open completion popover (K-4) still takes
/// the key first. Return is sent as a real key press through the window.
@MainActor
final class NewlineIndentSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    private static let alphaBody = "alpha body\n"
    private let alpha = NoteID(relativePath: "Alpha.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-indent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.alphaBody.utf8).write(to: root.appendingPathComponent("Alpha.md"))
        try Data("beta body\n".utf8).write(to: root.appendingPathComponent("Beta.md"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let window: NSWindow
        var editor: EditorController { controller.editorController }
        var textView: EditorTextView { controller.mainView.textView }

        /// Replaces the shown text as typing would, clears the undo stack, and puts the caret
        /// at storage index `caret` (the end when nil).
        func show(_ text: String, caret: Int? = nil) {
            textView.selectAll(nil)
            textView.insertText(text, replacementRange: textView.selectedRange())
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        }

        /// The caret's storage index.
        var caret: Int { textView.selectedRange().location }
    }

    /// A laid-out window with a ready library attached, Alpha shown and the editor focused.
    private func makeFixture() async throws -> Fixture {
        let controller = makeMainWindowController()
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
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        return Fixture(controller: controller, window: window)
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

    /// Lets the run loop turn, which closes the undo group as the end of a key event would.
    private func endOfEvent() async {
        try? await Task.sleep(for: .milliseconds(1))
    }

    /// Sends one key as a user's press: a `keyDown` then a `keyUp`, each offered to the window's
    /// key equivalents first, as the running app's event loop does, then dispatched by the
    /// window to its first responder.
    private func send(_ characters: String, keyCode: UInt16, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                    keyCode: keyCode))
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
    }

    private func pressReturn(in window: NSWindow) throws {
        try send("\r", keyCode: 36, in: window)
    }

    /// Types `text` one character at a time, each as a key press.
    private func type(_ text: String, in window: NSWindow) throws {
        for character in text { try send(String(character), keyCode: 0, in: window) }
    }

    // MARK: ED-17 the indent is carried

    func testED17_returnCopiesSpaces() async throws {
        let fixture = try await makeFixture()
        fixture.show("    indented line")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "    indented line\n    ")
        XCTAssertEqual(fixture.caret, 22, "the caret is after the carried indent")

        // The caret mid-line: the break splits the line and the indent starts the rest.
        fixture.show("  one two", caret: 5)
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "  one\n   two")
        XCTAssertEqual(fixture.caret, 8)

        // Typing on stays at the carried depth, and the next Return carries it again.
        fixture.show("first\n  second")
        try pressReturn(in: fixture.window)
        try type("third", in: fixture.window)
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "first\n  second\n  third\n  ")
    }

    func testED17_returnCopiesTabs() async throws {
        let fixture = try await makeFixture()
        fixture.show("\t\tdeep")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "\t\tdeep\n\t\t")

        fixture.show("\t  \tmixed")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "\t  \tmixed\n\t  \t", "spaces and tabs as they are, in order")
    }

    func testED17_returnInFencedCodeKeepsIndent() async throws {
        let fixture = try await makeFixture()
        let code = "```swift\nfunc f() {\n    let x = 1\n"
        fixture.show(code + "}\n```\n", caret: (code as NSString).length - 1)
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "```swift\nfunc f() {\n    let x = 1\n    \n}\n```\n")
        try type("return x", in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "```swift\nfunc f() {\n    let x = 1\n    return x\n}\n```\n")
    }

    func testED17_noIndentNoInsertion() async throws {
        let fixture = try await makeFixture()
        fixture.show("plain line")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "plain line\n")
        XCTAssertEqual(fixture.caret, 11)

        // Whitespace later in the line is not indentation.
        fixture.show("a  b\tc  ")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "a  b\tc  \n")

        // Only the caret's own line counts: the one above is indented, this one is not.
        fixture.show("    above\nhere")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "    above\nhere\n")
    }

    func testED17_caretInsideIndentCopiesUpToCaret() async throws {
        let fixture = try await makeFixture()
        // The tab before the caret is carried; the two spaces after it stay where they were,
        // after the carried tab on the new line.
        fixture.show("\t  text", caret: 1)
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "\t\n\t  text", "the tab before the caret, not the spaces after it")
        XCTAssertEqual(fixture.caret, 3, "the caret is after the carried tab")

        // At the very start of an indented line there is nothing before the caret to carry.
        fixture.show("x\n    text", caret: 2)
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "x\n\n    text")

        // With a selection, the line its start is on decides and the selection is replaced.
        fixture.show("  keep drop this")
        fixture.textView.setSelectedRange(NSRange(location: 6, length: 10))
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "  keep\n  ")
    }

    func testED17_listMarkerNotContinued() async throws {
        let fixture = try await makeFixture()
        fixture.show("- item")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "- item\n", "the bullet is not continued")

        fixture.show("  - nested")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "  - nested\n  ", "the indent, not the marker")

        fixture.show("1. first")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "1. first\n")

        fixture.show("> quoted")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "> quoted\n", "the blockquote prefix is not continued")

        fixture.show("  - [ ] task")
        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "  - [ ] task\n  ", "nor the task box")
    }

    // MARK: ED-17 one undoable, autosaved edit

    func testED17_singleUndoStep() async throws {
        let fixture = try await makeFixture()
        let manager = try XCTUnwrap(fixture.textView.undoManager)
        fixture.show("    line")
        try pressReturn(in: fixture.window)
        await endOfEvent()
        XCTAssertEqual(fixture.editor.text, "    line\n    ")
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        XCTAssertEqual(fixture.editor.text, "    line", "one undo takes the break and the indent together")
        XCTAssertFalse(manager.canUndo, "and there was nothing else to undo")
        manager.redo()
        XCTAssertEqual(fixture.editor.text, "    line\n    ")

        // Like any typed edit, it is autosaved (E-4).
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        await waitUntil("Alpha written") {
            (try? String(contentsOf: self.root.appendingPathComponent("Alpha.md"), encoding: .utf8))
                == "    line\n    "
        }
    }

    // MARK: ED-17 the completion popover takes Return first (K-4)

    func testED17_completionPopoverTakesReturn() async throws {
        let fixture = try await makeFixture()
        let completion = fixture.editor.linkCompletion
        fixture.show("  see ")
        try type("[[be", in: fixture.window)
        XCTAssertTrue(completion.isShowing)
        XCTAssertEqual(completion.items, ["Beta"])

        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "  see [[Beta]]", "Return inserted the title, not a line break")
        XCTAssertFalse(completion.isActive)

        try pressReturn(in: fixture.window)
        XCTAssertEqual(fixture.editor.text, "  see [[Beta]]\n  ", "with the popover gone Return carries the indent")
    }
}
