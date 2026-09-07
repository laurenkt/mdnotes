import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the `[[` completion popover (K-4). Every character and every key is
/// a real `NSEvent` sent through the window, so it takes the path a user's keystroke does:
/// `EditorTextView.keyDown`, `interpretKeyEvents`, `insertText` or the command selector the
/// key maps to, and the text view delegate that hands the popover its keys.
@MainActor
final class LinkCompletionSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    private static let alphaBody = "alpha body\n"
    /// Written oldest first, so the empty query lists them newest first (S-3): zeta (daily),
    /// Zeta (archive), Gamma, Beta, Alpha.
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", alphaBody),
        ("daily/Beta.md", "beta body"),
        ("Gamma.md", "gamma body"),
        ("archive/Zeta.md", "older zeta"),
        ("daily/zeta.md", "newer zeta"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let gamma = NoteID(relativePath: "Gamma.md")
    /// The titles the popover lists for an empty filter: the two Zetas make one row, in the
    /// spelling of the newer.
    private let allTitles = ["zeta", "Gamma", "Beta", "Alpha"]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-completion-\(UUID().uuidString)", isDirectory: true)
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
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// A laid-out window with a ready library attached, Alpha shown in the editor and the
    /// editor focused, its caret at the start of the text.
    private func makeControllerShowingAlpha() async throws -> (MainWindowController, NSWindow) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.count, 5)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.listController.select(alpha))
        await waitForEditor(controller, toShow: alpha)
        XCTAssertEqual(controller.mainView.textView.string, Self.alphaBody)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        controller.mainView.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(controller.editorController.linkCompletion.isActive)
        return (controller, window)
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

    /// Waits for the editor's read of `id` to land, the async tail of S-8.
    private func waitForEditor(_ controller: MainWindowController, toShow id: NoteID) async {
        await waitUntil("editor shows \(id.relativePath)") {
            controller.editorController.noteID == id && controller.editorController.body != nil
        }
    }

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    // MARK: - Keys

    private enum Key {
        case down, up, escape, `return`, keypadEnter, delete, commandL

        var characters: String {
            switch self {
            case .down: "\u{F701}"  // NSDownArrowFunctionKey
            case .up: "\u{F700}"  // NSUpArrowFunctionKey
            case .escape: "\u{1B}"
            case .return: "\r"
            case .keypadEnter: "\u{03}"
            case .delete: "\u{7F}"
            case .commandL: "l"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .down: 125
            case .up: 126
            case .escape: 53
            case .return: 36
            case .keypadEnter: 76
            case .delete: 51
            case .commandL: 37
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .down, .up: .function
            case .keypadEnter: .numericPad
            case .commandL: .command
            case .escape, .return, .delete: []
            }
        }
    }

    /// Sends one key as a user's press: a `keyDown` then a `keyUp`, each offered to the window's
    /// key equivalents first, as the running app's event loop does, then dispatched by the
    /// window to its first responder.
    private func send(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws
    {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                    keyCode: keyCode))
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
    }

    private func press(_ key: Key, in window: NSWindow) throws {
        try send(characters: key.characters, keyCode: key.keyCode, modifiers: key.modifiers, in: window)
    }

    /// Types `text` one character at a time, each as a key press.
    private func type(_ text: String, in window: NSWindow) throws {
        for character in text {
            try send(characters: String(character), keyCode: 0, modifiers: [], in: window)
        }
    }

    // MARK: K-4 typing `[[` opens the popover

    func testK4_typingTwoBracketsOpensThePopoverListingEveryTitle() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        let textView = controller.mainView.textView

        try type("[", in: window)
        XCTAssertFalse(completion.isActive, "one bracket is not the trigger")
        XCTAssertEqual(textView.string, "[" + Self.alphaBody)

        try type("[", in: window)
        XCTAssertTrue(completion.isActive)
        XCTAssertTrue(completion.isShowing)
        XCTAssertEqual(completion.anchor, 2)
        XCTAssertEqual(completion.titles, allTitles, "every title once, most recently modified first (S-3)")
        XCTAssertEqual(completion.selectedTitle, "zeta", "the first row starts selected")
        XCTAssertEqual(completion.tableView.numberOfRows, 4)
        XCTAssertEqual(textView.string, "[[" + Self.alphaBody, "the brackets are typed as usual")
        XCTAssertIdentical(window.firstResponder, textView, "the editor keeps focus")

        // The panel's window follows the list a turn of the run loop behind (PF-3), as a child
        // of the editor's window.
        XCTAssertFalse(completion.isPanelAttached, "not inside the keystroke")
        await waitUntil("panel attached") { completion.isPanelAttached }
        XCTAssertTrue(window.childWindows?.contains { $0 is NSPanel } ?? false)
        XCTAssertIdentical(window.firstResponder, textView, "the panel did not take focus")
    }

    func testK4_theTextTypedSinceTheBracketsFiltersTitlesWithTheS2Rules() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion

        try type("[[ET", in: window)
        XCTAssertEqual(completion.titles, ["zeta", "Beta"], "a case-insensitive substring of the title")
        try type(" a", in: window)
        XCTAssertEqual(completion.titles, ["zeta", "Beta"], "every word, in any order")
        try type("l", in: window)
        XCTAssertEqual(completion.titles, [], "no title holds al and et")
        XCTAssertFalse(completion.isShowing, "nothing to list, so nothing is shown")
        XCTAssertTrue(completion.isActive, "but the session is still open")

        try press(.delete, in: window)
        try press(.delete, in: window)
        try press(.delete, in: window)
        XCTAssertEqual(controller.mainView.textView.string, "[[ET" + Self.alphaBody)
        XCTAssertEqual(completion.titles, ["zeta", "Beta"], "deleting back to a match shows the list again")
        XCTAssertTrue(completion.isShowing)

        try press(.delete, in: window)
        try press(.delete, in: window)
        XCTAssertEqual(completion.titles, allTitles, "an empty filter lists everything")
        XCTAssertEqual(
            LinkCompletion.titles(matching: "body", in: try XCTUnwrap(controller.library).snapshot), [],
            "a word found only in bodies matches no title")
    }

    // MARK: K-4 Enter inserts the title and the closing brackets

    func testK4_enterInsertsTheSelectedTitleAndTheClosingBrackets() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        let textView = controller.mainView.textView
        var inserted: (String, NSRange)?
        completion.onInsert = { inserted = ($0, $1) }

        try type("[[be", in: window)
        XCTAssertEqual(completion.titles, ["Beta"])
        try press(.return, in: window)

        XCTAssertEqual(textView.string, "[[Beta]]" + Self.alphaBody, "the typed text became the title, closed")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 8, length: 0), "the caret is after the ]]")
        XCTAssertEqual(inserted?.0, "Beta")
        XCTAssertEqual(inserted?.1, NSRange(location: 0, length: 8))
        XCTAssertFalse(completion.isActive)
        XCTAssertFalse(completion.isShowing)
        XCTAssertIdentical(window.firstResponder, textView)
        XCTAssertEqual(
            controller.editorController.linkTarget(at: 4), LinkTarget(text: "Beta"), "the result is a link (K-1)")
        let style = textView.textStorage?.attribute(EditorStyler.tokenAttribute, at: 3, effectiveRange: nil) as? String
        XCTAssertEqual(style, EditorStyler.TokenStyle.wikilink.rawValue, "and styled as one (E-2)")

        // The insertion is an edit like any other: it is autosaved (E-4).
        XCTAssertTrue(controller.editorController.hasUnsavedEdits)
        await waitUntil("Alpha written") { (try? self.fileText(self.alpha)) == "[[Beta]]" + Self.alphaBody }
        XCTAssertEqual(try fileText(alpha), "[[Beta]]" + Self.alphaBody)

        // Typing on does not reopen the popover for the link just made.
        try type(" x", in: window)
        XCTAssertFalse(completion.isActive)
        XCTAssertEqual(textView.string, "[[Beta]] x" + Self.alphaBody)
    }

    func testK4_theKeypadEnterInsertsToo() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        try type("[[gam", in: window)
        try press(.keypadEnter, in: window)
        XCTAssertEqual(controller.mainView.textView.string, "[[Gamma]]" + Self.alphaBody)
        XCTAssertFalse(controller.editorController.linkCompletion.isActive)
    }

    func testK4_downAndUpMoveTheSelectionAndEnterInsertsTheSelectedTitle() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        let textView = controller.mainView.textView

        try type("[[", in: window)
        XCTAssertEqual(completion.selectedTitle, "zeta")
        try press(.down, in: window)
        XCTAssertEqual(completion.selectedTitle, "Gamma")
        try press(.down, in: window)
        XCTAssertEqual(completion.selectedTitle, "Beta")
        try press(.up, in: window)
        XCTAssertEqual(completion.selectedTitle, "Gamma")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0), "the caret did not move")
        XCTAssertEqual(textView.string, "[[" + Self.alphaBody)

        for _ in 0..<5 { try press(.down, in: window) }
        XCTAssertEqual(completion.selectedTitle, "Alpha", "the selection stops at the last row")
        for _ in 0..<5 { try press(.up, in: window) }
        XCTAssertEqual(completion.selectedTitle, "zeta", "and at the first")
        try press(.down, in: window)

        try press(.return, in: window)
        XCTAssertEqual(textView.string, "[[Gamma]]" + Self.alphaBody)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 9, length: 0))
    }

    func testK4_typingIntoTheMiddleOfTheTextCompletesThere() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let textView = controller.mainView.textView
        textView.setSelectedRange(NSRange(location: 5, length: 0))  // after "alpha"

        try type(" see [[ze", in: window)
        XCTAssertEqual(controller.editorController.linkCompletion.titles, ["zeta"])
        try press(.return, in: window)
        XCTAssertEqual(textView.string, "alpha see [[zeta]] body\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 18, length: 0))
    }

    // MARK: K-4 Escape dismisses

    func testK4_escapeDismissesThePopoverAndLeavesTheTextAsTyped() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        let textView = controller.mainView.textView
        controller.mainView.searchField.stringValue = "alpha"
        controller.searchQueryDidChange()

        try type("[[be", in: window)
        XCTAssertTrue(completion.isShowing)
        await waitUntil("panel attached") { completion.isPanelAttached }
        try press(.escape, in: window)
        XCTAssertFalse(completion.isShowing)
        XCTAssertFalse(completion.isActive)
        await waitUntil("panel detached") { !completion.isPanelAttached }
        XCTAssertEqual(window.childWindows?.count ?? 0, 0, "the panel left the window")
        XCTAssertEqual(textView.string, "[[be" + Self.alphaBody, "nothing was inserted or removed")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertIdentical(window.firstResponder, textView, "Escape went to the popover, not to S-7")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "alpha")
        XCTAssertEqual(controller.query, "alpha")

        try type("t", in: window)
        XCTAssertFalse(completion.isActive, "typing on does not reopen the dismissed session")
        XCTAssertEqual(textView.string, "[[bet" + Self.alphaBody)

        // A second Escape, with no popover up, is S-7's.
        try press(.escape, in: window)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "")
        XCTAssertNotIdentical(window.firstResponder, textView, "focus went to the search field")
    }

    func testK4_escapeWithNoMatchShowingEndsTheSessionAndIsStillS7() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        controller.mainView.searchField.stringValue = "alpha"
        controller.searchQueryDidChange()

        try type("[[qqq", in: window)
        XCTAssertTrue(completion.isActive)
        XCTAssertFalse(completion.isShowing)
        try press(.escape, in: window)
        XCTAssertFalse(completion.isActive)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "", "S-7: the query is cleared")
        XCTAssertNotIdentical(window.firstResponder, controller.mainView.textView, "and the field focused")
    }

    // MARK: K-4 what else ends a session

    func testK4_aClosingBracketOrALineBreakEndsTheSession() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        let textView = controller.mainView.textView

        try type("[[be]", in: window)
        XCTAssertFalse(completion.isActive, "the user is closing the link by hand")
        try type("]", in: window)
        XCTAssertEqual(textView.string, "[[be]]" + Self.alphaBody)
        XCTAssertFalse(completion.isActive)

        try type(" [[qqq", in: window)
        XCTAssertTrue(completion.isActive)
        XCTAssertFalse(completion.isShowing)
        try press(.return, in: window)
        XCTAssertEqual(textView.string, "[[be]] [[qqq\n" + Self.alphaBody, "with nothing showing, Return is a newline")
        XCTAssertFalse(completion.isActive, "and the line break ends the session")
    }

    func testK4_deletingTheBracketsOrMovingTheCaretOutEndsTheSession() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        let textView = controller.mainView.textView

        try type("[[", in: window)
        XCTAssertTrue(completion.isShowing)
        try press(.delete, in: window)
        XCTAssertFalse(completion.isActive, "one bracket left")
        XCTAssertEqual(textView.string, "[" + Self.alphaBody)

        try type("[be", in: window)
        XCTAssertTrue(completion.isShowing)
        XCTAssertEqual(completion.anchor, 2)
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertFalse(completion.isActive, "the caret left the brackets")

        // Putting the caret back after an existing [[ does not open a session: typing does.
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(completion.isActive)
        try type("t", in: window)
        XCTAssertFalse(completion.isActive, "typing after the brackets without typing them is not the trigger")
        XCTAssertEqual(textView.string, "[[tbe" + Self.alphaBody)
    }

    func testK4_aSelectionInsteadOfACaretEndsTheSession() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        try type("[[be", in: window)
        XCTAssertTrue(completion.isShowing)
        controller.mainView.textView.setSelectedRange(NSRange(location: 2, length: 2))
        XCTAssertFalse(completion.isActive)
    }

    func testK4_losingFocusOrSwitchingNoteDismissesThePopover() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        let textView = controller.mainView.textView

        try type("[[", in: window)
        XCTAssertTrue(completion.isShowing)
        try press(.commandL, in: window)
        XCTAssertNotIdentical(window.firstResponder, textView)
        XCTAssertFalse(completion.isActive, "focus left the editor")

        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        try type("[[", in: window)
        XCTAssertTrue(completion.isShowing)
        XCTAssertTrue(controller.listController.select(gamma))
        await waitForEditor(controller, toShow: gamma)
        XCTAssertFalse(completion.isActive, "the text was replaced by another note")
        XCTAssertEqual(textView.string, "gamma body")
        await waitUntil("Alpha written") { (try? self.fileText(self.alpha)) == "[[" + Self.alphaBody + "[[" }
    }

    func testK4_theListFollowsTheSnapshotWhileItIsShowing() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.linkCompletion
        let library = try XCTUnwrap(controller.library)

        try type("[[del", in: window)
        XCTAssertEqual(completion.titles, [])
        XCTAssertFalse(completion.isShowing)
        let created = NoteID(relativePath: "Delta.md")
        let settled = expectation(description: "Delta created")
        library.create(created) { _ in settled.fulfill() }
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertNotNil(library.snapshot.entry(for: created))
        XCTAssertEqual(completion.titles, ["Delta"], "the new note is listed without another keystroke")
        XCTAssertTrue(completion.isShowing)

        try press(.return, in: window)
        XCTAssertEqual(controller.mainView.textView.string, "[[Delta]]" + Self.alphaBody)
    }
}
