import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the `#` completion popover (T-3) and click-to-search on a tag
/// (T-4). Every character and key is a real `NSEvent` sent through the window, so it takes the
/// path a user's keystroke does; a click is a real mouse event delivered to the editor as the
/// window would deliver it. The cases where the text view's own mouse handling would follow (a
/// click outside a tag) call the controller's entry points directly, because `NSTextView`'s
/// `mouseDown` runs a tracking loop that waits for a mouse-up the test process never delivers.
@MainActor
final class TagCompletionSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Alpha carries the tags the tests type against and click on. The `#hidden` is in a code
    /// span and so is not a tag (T-1); `C#` is glued to a word and so is not one either.
    private static let alphaBody = "alpha #swift and #AppKit here\ncode `#hidden` and C# tail\n"
    /// Written oldest first, so the empty query lists them newest first (S-3): Gamma, Beta,
    /// Alpha. Two notes spell the tag `swift`, one `Swift`, so the library's spelling is the
    /// lowercase one (T-2).
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", alphaBody),
        ("daily/Beta.md", "beta #swift #project/mdnotes"),
        ("Gamma.md", "gamma #Swift #golang"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")
    /// Every known tag in the library's spelling, sorted ignoring case (T-2).
    private let allTags = ["AppKit", "golang", "project/mdnotes", "swift"]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-tags-\(UUID().uuidString)", isDirectory: true)
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
    /// editor focused, its caret at the end of the text (the start of an empty last line).
    private func makeControllerShowingAlpha() async throws -> (MainWindowController, NSWindow) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma, beta, alpha])
        XCTAssertEqual(library.snapshot.tags.allTags, allTags)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.listController.select(alpha))
        await waitForEditor(controller, toShow: alpha)
        XCTAssertEqual(controller.mainView.textView.string, Self.alphaBody)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        controller.mainView.textView.setSelectedRange(NSRange(location: Self.end, length: 0))
        XCTAssertFalse(controller.editorController.tagCompletion.isActive)
        return (controller, window)
    }

    private static var end: Int { (alphaBody as NSString).length }

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

    /// The range of the first `needle` in Alpha's body, in UTF-16 units.
    private func range(of needle: String) -> NSRange {
        let found = (Self.alphaBody as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "\(needle) is in the fixture")
        return found
    }

    // MARK: - Keys

    private enum Key {
        case down, escape, `return`, delete, commandL

        var characters: String {
            switch self {
            case .down: "\u{F701}"  // NSDownArrowFunctionKey
            case .escape: "\u{1B}"
            case .return: "\r"
            case .delete: "\u{7F}"
            case .commandL: "l"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .down: 125
            case .escape: 53
            case .return: 36
            case .delete: 51
            case .commandL: 37
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .down: .function
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

    // MARK: - Clicks

    /// The point, in the window's coordinates, at the centre of the character at `index`.
    private func centre(ofCharacterAt index: Int, in controller: MainWindowController, window: NSWindow) -> NSPoint {
        let textView = controller.mainView.textView
        if let layoutManager = textView.textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, "the character has been laid out")
        let windowRect = window.convertFromScreen(screenRect)
        return NSPoint(x: windowRect.midX, y: windowRect.midY)
    }

    /// Sends a plain click on the character at `index` of the editor's text: a mouse-down then
    /// a mouse-up at the character's centre, delivered to the editor as `NSWindow.sendEvent`
    /// would deliver them; a window that has never been on screen does not dispatch mouse
    /// events itself.
    private func click(onCharacterAt index: Int, in controller: MainWindowController, window: NSWindow) throws {
        let textView = controller.mainView.textView
        let point = centre(ofCharacterAt: index, in: controller, window: window)
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

    // MARK: T-3 typing `#` opens the popover of known tags

    func testT3_typingAHashOpensThePopoverListingEveryKnownTag() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion
        let textView = controller.mainView.textView

        try type("#", in: window)
        XCTAssertTrue(completion.isActive)
        XCTAssertTrue(completion.isShowing)
        XCTAssertEqual(completion.anchor, Self.end + 1)
        XCTAssertEqual(completion.items, allTags, "every tag once, in the library's spelling, sorted (T-2)")
        XCTAssertEqual(completion.selectedItem, "AppKit", "the first row starts selected")
        XCTAssertEqual(completion.tableView.numberOfRows, 4)
        XCTAssertEqual(textView.string, Self.alphaBody + "#", "the hash is typed as usual")
        XCTAssertIdentical(window.firstResponder, textView, "the editor keeps focus")
        XCTAssertFalse(controller.editorController.linkCompletion.isActive, "the [[ popover is not involved")

        // The panel's window follows the list a turn of the run loop behind (PF-3), as a child
        // of the editor's window.
        XCTAssertFalse(completion.isPanelAttached, "not inside the keystroke")
        await waitUntil("panel attached") { completion.isPanelAttached }
        XCTAssertTrue(window.childWindows?.contains { $0 is NSPanel } ?? false)
        XCTAssertIdentical(window.firstResponder, textView, "the panel did not take focus")
    }

    func testT3_theTextTypedSinceTheHashFiltersTagsByPrefixIgnoringCase() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion

        try type("#S", in: window)
        XCTAssertEqual(completion.items, ["swift"], "a prefix, ignoring case")
        try type("W", in: window)
        XCTAssertEqual(completion.items, ["swift"])
        try type("x", in: window)
        XCTAssertEqual(completion.items, [], "no tag begins with swx")
        XCTAssertFalse(completion.isShowing, "nothing to list, so nothing is shown")
        XCTAssertTrue(completion.isActive, "but the session is still open")

        try press(.delete, in: window)
        XCTAssertEqual(controller.mainView.textView.string, Self.alphaBody + "#SW")
        XCTAssertEqual(completion.items, ["swift"], "deleting back to a match shows the list again")
        XCTAssertTrue(completion.isShowing)

        try press(.delete, in: window)
        try press(.delete, in: window)
        XCTAssertEqual(completion.items, allTags, "an empty prefix lists everything")
        try type("p", in: window)
        XCTAssertEqual(completion.items, ["project/mdnotes"])
        try type("roject/", in: window)
        XCTAssertEqual(completion.items, ["project/mdnotes"], "a slash is a tag character (T-1)")
    }

    // MARK: T-3 Enter inserts the tag

    func testT3_enterInsertsTheSelectedTagAfterTheHash() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion
        let textView = controller.mainView.textView
        var inserted: (String, NSRange)?
        completion.onInsert = { inserted = ($0, $1) }

        try type("#app", in: window)
        XCTAssertEqual(completion.items, ["AppKit"])
        try press(.return, in: window)

        XCTAssertEqual(textView.string, Self.alphaBody + "#AppKit", "the typed prefix became the tag")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: Self.end + 7, length: 0), "the caret is after it")
        XCTAssertEqual(inserted?.0, "AppKit")
        XCTAssertEqual(inserted?.1, NSRange(location: Self.end, length: 7), "the range is the whole #tag")
        XCTAssertFalse(completion.isActive)
        XCTAssertFalse(completion.isShowing)
        XCTAssertIdentical(window.firstResponder, textView)
        XCTAssertEqual(controller.editorController.tag(at: Self.end + 3), "#AppKit", "the result is a tag (T-1)")
        let style =
            textView.textStorage?.attribute(EditorStyler.tokenAttribute, at: Self.end + 3, effectiveRange: nil)
            as? String
        XCTAssertEqual(style, EditorStyler.TokenStyle.tag.rawValue, "and styled as one (E-2)")

        // The insertion is an edit like any other: it is autosaved (E-4).
        XCTAssertTrue(controller.editorController.hasUnsavedEdits)
        await waitUntil("Alpha written") { (try? self.fileText(self.alpha)) == Self.alphaBody + "#AppKit" }

        // Typing on does not reopen the popover for the tag just made.
        try type(" x", in: window)
        XCTAssertFalse(completion.isActive)
        XCTAssertEqual(textView.string, Self.alphaBody + "#AppKit x")
    }

    func testT3_downMovesTheSelectionAndEnterInsertsTheSelectedTag() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion
        let textView = controller.mainView.textView

        try type("#", in: window)
        XCTAssertEqual(completion.selectedItem, "AppKit")
        try press(.down, in: window)
        XCTAssertEqual(completion.selectedItem, "golang")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: Self.end + 1, length: 0), "the caret did not move")
        try press(.return, in: window)
        XCTAssertEqual(textView.string, Self.alphaBody + "#golang")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: Self.end + 7, length: 0))
    }

    // MARK: T-3 Escape dismisses

    func testT3_escapeDismissesThePopoverAndLeavesTheTextAsTyped() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion
        let textView = controller.mainView.textView
        controller.mainView.searchField.stringValue = "alpha"
        controller.searchQueryDidChange()

        try type("#sw", in: window)
        XCTAssertTrue(completion.isShowing)
        await waitUntil("panel attached") { completion.isPanelAttached }
        try press(.escape, in: window)
        XCTAssertFalse(completion.isShowing)
        XCTAssertFalse(completion.isActive)
        await waitUntil("panel detached") { !completion.isPanelAttached }
        XCTAssertEqual(window.childWindows?.count ?? 0, 0, "the panel left the window")
        XCTAssertEqual(textView.string, Self.alphaBody + "#sw", "nothing was inserted or removed")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: Self.end + 3, length: 0))
        XCTAssertIdentical(window.firstResponder, textView, "Escape went to the popover, not to S-7")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "alpha")

        try type("i", in: window)
        XCTAssertFalse(completion.isActive, "typing on does not reopen the dismissed session")

        // A second Escape, with no popover up, is S-7's.
        try press(.escape, in: window)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "")
        XCTAssertNotIdentical(window.firstResponder, textView, "focus went to the search field")
    }

    // MARK: T-3 where a session opens and what ends it

    func testT3_aHashGluedToAWordOpensNothing() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion
        try type("C#", in: window)
        XCTAssertFalse(completion.isActive, "C# is not where a tag begins (T-1)")
        try type(" #", in: window)
        XCTAssertTrue(completion.isShowing, "after a space it is")
        XCTAssertEqual(controller.mainView.textView.string, Self.alphaBody + "C# #")
    }

    func testT3_aSpacePunctuationOrALineBreakEndsTheSession() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion
        let textView = controller.mainView.textView

        try type("# ", in: window)
        XCTAssertFalse(completion.isActive, "a heading in the making, not a tag")
        try type("Title\n#go.", in: window)
        XCTAssertFalse(completion.isActive, "trailing punctuation ends the tag (T-1)")
        XCTAssertEqual(textView.string, Self.alphaBody + "# Title\n#go.")

        try type(" #qqq", in: window)
        XCTAssertTrue(completion.isActive)
        XCTAssertFalse(completion.isShowing)
        try press(.return, in: window)
        XCTAssertEqual(
            textView.string, Self.alphaBody + "# Title\n#go. #qqq\n", "with nothing showing, Return is a newline")
        XCTAssertFalse(completion.isActive, "and the line break ends the session")
    }

    func testT3_deletingTheHashOrMovingTheCaretOutEndsTheSession() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion
        let textView = controller.mainView.textView

        try type("#", in: window)
        XCTAssertTrue(completion.isShowing)
        try press(.delete, in: window)
        XCTAssertFalse(completion.isActive, "the hash went")
        XCTAssertEqual(textView.string, Self.alphaBody)

        try type("#go", in: window)
        XCTAssertTrue(completion.isShowing)
        textView.setSelectedRange(NSRange(location: Self.end, length: 0))
        XCTAssertFalse(completion.isActive, "the caret left the tag")

        // Putting the caret back after an existing # does not open a session: typing does.
        textView.setSelectedRange(NSRange(location: Self.end + 1, length: 0))
        XCTAssertFalse(completion.isActive)
        try type("l", in: window)
        XCTAssertFalse(completion.isActive, "typing after the hash without typing it is not the trigger")
        XCTAssertEqual(textView.string, Self.alphaBody + "#lgo")
    }

    func testT3_losingFocusOrSwitchingNoteDismissesThePopover() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion
        let textView = controller.mainView.textView

        try type("#", in: window)
        XCTAssertTrue(completion.isShowing)
        try press(.commandL, in: window)
        XCTAssertNotIdentical(window.firstResponder, textView)
        XCTAssertFalse(completion.isActive, "focus left the editor")

        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        try type(" #", in: window)
        XCTAssertTrue(completion.isShowing)
        XCTAssertTrue(controller.listController.select(gamma))
        await waitForEditor(controller, toShow: gamma)
        XCTAssertFalse(completion.isActive, "the text was replaced by another note")
        XCTAssertEqual(textView.string, "gamma #Swift #golang")
    }

    func testT3_theListFollowsTheSnapshotAsTagsAreSaved() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let completion = controller.editorController.tagCompletion
        let library = try XCTUnwrap(controller.library)

        // A tag typed and autosaved is known to the index (T-2, K-5) and offered from then on.
        try type("#newtag ", in: window)
        XCTAssertFalse(completion.isActive)
        await waitUntil("newtag indexed") { library.snapshot.tags.allTags.contains("newtag") }
        XCTAssertEqual(try fileText(alpha), Self.alphaBody + "#newtag ")
        try type("#new", in: window)
        XCTAssertEqual(completion.items, ["newtag"])

        // A list left showing follows the snapshot: another note's new tag appears in it.
        try press(.escape, in: window)
        try type(" #g", in: window)
        XCTAssertEqual(completion.items, ["golang"])
        let delta = NoteID(relativePath: "Delta.md")
        let created = expectation(description: "Delta created")
        library.create(delta) { _ in created.fulfill() }
        await fulfillment(of: [created], timeout: 10)
        try "delta #gopher".write(
            to: root.appendingPathComponent(delta.relativePath), atomically: true, encoding: .utf8)
        await waitUntil("gopher indexed") { completion.items == ["golang", "gopher"] }
        XCTAssertTrue(completion.isShowing)
        try press(.down, in: window)
        try press(.return, in: window)
        XCTAssertEqual(controller.mainView.textView.string, Self.alphaBody + "#newtag #new #gopher")
    }

    // MARK: T-4 a plain click on a tag sets the search field to it

    func testT4_clickingATagSetsTheSearchFieldToItAndReloadsTheList() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let textView = controller.mainView.textView
        XCTAssertEqual(controller.mainView.searchField.stringValue, "")

        try click(onCharacterAt: range(of: "#AppKit").location + 3, in: controller, window: window)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "#AppKit", "the tag as written, # included")
        XCTAssertEqual(controller.query, "#AppKit")
        XCTAssertEqual(controller.listController.results.map(\.id), [alpha], "the list reloaded for it (S-4, S-5)")
        XCTAssertEqual(controller.listController.selectedID, alpha, "the open note is still listed and selected")
        XCTAssertEqual(controller.editorController.noteID, alpha)
        XCTAssertEqual(textView.string, Self.alphaBody, "the text is untouched")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: Self.end, length: 0), "the caret did not move")
        XCTAssertIdentical(window.firstResponder, textView, "focus stays in the editor")
        XCTAssertFalse(controller.editorController.hasUnsavedEdits)

        try click(onCharacterAt: range(of: "#swift").location, in: controller, window: window)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "#swift", "a click on the # itself")
        XCTAssertEqual(
            controller.listController.results.map(\.id), [gamma, beta, alpha],
            "#tag is an ordinary word: every note with it, ignoring case (S-2, S-4)")
        XCTAssertEqual(controller.listController.selectedID, alpha)
    }

    func testT4_clickingATagTheOpenNoteAloneCarriesKeepsItSelectedAndOneItDoesNotClearsTheSelection() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        XCTAssertTrue(controller.listController.select(gamma))
        await waitForEditor(controller, toShow: gamma)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        let golang = ("gamma #Swift #golang" as NSString).range(of: "#golang")

        try click(onCharacterAt: golang.location + 2, in: controller, window: window)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "#golang")
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma])
        XCTAssertEqual(controller.listController.selectedID, gamma)
        XCTAssertEqual(controller.editorController.noteID, gamma, "the editor stays on the note")
    }

    func testT4_aClickOutsideATagIsLeftToTheTextView() async throws {
        let (controller, _) = try await makeControllerShowingAlpha()
        controller.mainView.searchField.stringValue = "alpha"
        controller.searchQueryDidChange()
        let editor = controller.editorController

        XCTAssertNil(editor.tag(at: range(of: "here").location), "plain text")
        XCTAssertNil(editor.tag(at: range(of: "#hidden").location + 2), "a #word in a code span is not a tag (T-1)")
        XCTAssertNil(editor.tag(at: range(of: "C#").location + 1), "a # glued to a word is not a tag")
        XCTAssertNil(editor.tag(at: range(of: "#AppKit").location + 7), "the space after a tag is not the tag")
        XCTAssertNil(editor.tag(at: range(of: "#AppKit").location - 1), "nor the space before")
        XCTAssertNil(editor.tag(at: -1))
        XCTAssertNil(editor.tag(at: Self.end))
        XCTAssertEqual(editor.tag(at: range(of: "#AppKit").location), "#AppKit", "the # is part of the tag")
        XCTAssertEqual(editor.tag(at: range(of: "#AppKit").location + 6), "#AppKit", "so is the last character")
        XCTAssertEqual(editor.tagRange(at: range(of: "#swift").location + 1), range(of: "#swift"))

        XCTAssertFalse(controller.searchTag(at: range(of: "here").location), "the click is not consumed")
        XCTAssertFalse(controller.searchTag(at: range(of: "#hidden").location + 2))
        XCTAssertEqual(controller.mainView.searchField.stringValue, "alpha", "and the query is untouched")
        XCTAssertEqual(controller.query, "alpha")
    }

    func testT4_aClickLandsOnACharacterOnlyWhenThePointIsOverOne() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let textView = controller.mainView.textView
        let appKit = range(of: "#AppKit")

        let onTag = textView.convert(
            centre(ofCharacterAt: appKit.location + 3, in: controller, window: window), from: nil)
        XCTAssertEqual(textView.characterIndex(under: onTag), appKit.location + 3)
        let onHash = textView.convert(centre(ofCharacterAt: appKit.location, in: controller, window: window), from: nil)
        XCTAssertEqual(textView.characterIndex(under: onHash), appKit.location)

        // Past the end of the first line, level with it: the nearest insertion index is the line
        // end, but no character is under the pointer.
        let lastOnLine = textView.convert(
            centre(ofCharacterAt: range(of: "here").location + 3, in: controller, window: window), from: nil)
        let pastLineEnd = NSPoint(x: lastOnLine.x + 200, y: lastOnLine.y)
        XCTAssertNil(textView.characterIndex(under: pastLineEnd))
        XCTAssertEqual(textView.characterIndexForInsertion(at: pastLineEnd), range(of: "here").location + 4)

        // Below the last line.
        XCTAssertNil(textView.characterIndex(under: NSPoint(x: onTag.x, y: textView.bounds.maxY - 1)))
        XCTAssertNil(textView.characterIndex(under: NSPoint(x: -100, y: -100)))
    }
}
