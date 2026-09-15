import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for opening links from the editor (K-3). Cmd-Return is a real
/// `NSEvent` sent through the window, so it takes the path a user's key press does into
/// `EditorTextView.keyDown`; Cmd-click is a real mouse event delivered to the view the window's
/// hit test names for the point, `EditorTextView.mouseDown`. The cases where the text view's own
/// handling would follow (a click outside a link) call the controller's entry points directly,
/// because `NSTextView`'s `mouseDown` runs a tracking loop that waits for a mouse-up the test
/// process never delivers. A standard link, autolink or bare URL opens through the
/// controller's `openURL`, replaced here with one that records the URL instead of launching a
/// browser.
@MainActor
final class LinkOpeningSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Alpha holds every kind of link the tests need. Written oldest first, so the empty query
    /// lists them newest first (S-3): Zeta (daily), Zeta (archive), Gamma, Beta, Alpha.
    private static let alphaBody = """
        see [[Beta]] and [[Beta|labelled]] then [[Missing]] and [[Zeta]]
        path [[projects/New]] bad [[a:b]] code `[[Beta]]` pic ![[pic.png]]
        web [site](https://example.com/a?b=1) auto <https://example.org/x> bare https://example.net/y
        img ![i](https://example.com/i.png) rel [rel](notes/rel.md) code `https://example.com/c`

        ```
        fenced [[Beta]]
        ```
        tail

        """
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", alphaBody),
        ("daily/Beta.md", "beta body"),
        ("Gamma.md", "gamma body"),
        ("archive/Zeta.md", "older zeta"),
        ("daily/zeta.md", "newer zeta"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")
    private let olderZeta = NoteID(relativePath: "archive/Zeta.md")
    private let newerZeta = NoteID(relativePath: "daily/zeta.md")
    private let fixtureFiles = ["Alpha.md", "Gamma.md", "archive/Zeta.md", "daily/Beta.md", "daily/zeta.md"]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-links-\(UUID().uuidString)", isDirectory: true)
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
    /// editor focused, its caret at the start.
    private func makeControllerShowingAlpha() async throws -> (MainWindowController, NSWindow) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [newerZeta, olderZeta, gamma, beta, alpha])
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.listController.select(alpha))
        await waitForEditor(controller, toShow: alpha)
        XCTAssertEqual(controller.mainView.textView.string, Self.alphaBody)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        controller.mainView.textView.setSelectedRange(NSRange(location: 0, length: 0))
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

    /// The range of the `occurrence`th `needle` in Alpha's body, in UTF-16 units.
    private func range(of needle: String, occurrence: Int = 0) -> NSRange {
        let text = Self.alphaBody as NSString
        var search = NSRange(location: 0, length: text.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = text.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let next = found.location + found.length
            search = NSRange(location: next, length: text.length - next)
        }
        XCTAssertNotEqual(found.location, NSNotFound, "\(needle) is in the fixture")
        return found
    }

    /// An index strictly inside `needle`: past its opening brackets.
    private func inside(_ needle: String, occurrence: Int = 0) -> Int {
        range(of: needle, occurrence: occurrence).location + 3
    }

    private func placeCaret(at index: Int, in controller: MainWindowController) {
        controller.mainView.textView.setSelectedRange(NSRange(location: index, length: 0))
    }

    /// Sends Cmd-Return as a user's key press: a `keyDown` then a `keyUp`, each offered to the
    /// window's key equivalents first, as the running app's event loop does, then dispatched
    /// by the window to its first responder.
    private func pressCommandReturn(in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
    }

    /// Sends a Cmd-click on the character at `index` of the editor's text: a mouse-down then a
    /// mouse-up at the character's centre. The window's hit test names the editor as the view
    /// under the point, and the events go to it as `NSWindow.sendEvent` would deliver them; a
    /// window that has never been on screen does not dispatch mouse events itself.
    private func commandClick(onCharacterAt index: Int, in controller: MainWindowController, window: NSWindow) throws {
        let textView = controller.mainView.textView
        // The editor's layout manager lays out lazily (ED-8): the character's rect is an
        // estimate until its line has been laid out.
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, "the character has been laid out")
        let windowRect = window.convertFromScreen(screenRect)
        let point = NSPoint(x: windowRect.midX, y: windowRect.midY)
        XCTAssertIdentical(
            window.contentView?.hitTest(point), textView, "the point is over the editor")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { textView.mouseDown(with: event) } else { textView.mouseUp(with: event) }
        }
    }

    /// Arms `onOpenLink` to report the next settled open.
    private func expectOpen(_ controller: MainWindowController) -> (XCTestExpectation, () -> (LinkTarget, NoteID?)?) {
        let settled = expectation(description: "link open settled")
        var reported: (LinkTarget, NoteID?)?
        controller.onOpenLink = { target, id in
            reported = (target, id)
            settled.fulfill()
        }
        return (settled, { reported })
    }

    /// Every file under the root, as relative paths.
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

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    // MARK: K-3 Cmd-Enter with the caret inside a link opens the target

    func testK3_commandEnterWithTheCaretInsideALinkOpensTheResolvedNote() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        placeCaret(at: inside("[[Beta]]"), in: controller)
        let (settled, reported) = expectOpen(controller)

        try pressCommandReturn(in: window)
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(reported()?.0, LinkTarget(text: "Beta"))
        XCTAssertEqual(reported()?.1, beta)
        XCTAssertEqual(controller.editorController.noteID, beta)
        XCTAssertEqual(controller.listController.selectedID, beta, "the target is selected in the list")
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView, "and the editor keeps focus")
        await waitForEditor(controller, toShow: beta)
        XCTAssertEqual(controller.mainView.textView.string, "beta body")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing was created")
        XCTAssertNil(controller.inlineMessage)
    }

    func testK3_aLabelledLinkOpensItsTargetNotItsLabel() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        placeCaret(at: range(of: "labelled").location + 2, in: controller)
        let (settled, reported) = expectOpen(controller)
        try pressCommandReturn(in: window)
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(reported()?.0, LinkTarget(text: "Beta"))
        XCTAssertEqual(reported()?.1, beta)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "no note called labelled was created")
    }

    func testK3_theCaretAtEitherEndOfALinkIsInsideIt() async throws {
        let (controller, _) = try await makeControllerShowingAlpha()
        let link = range(of: "[[Beta]]")
        let editor = controller.editorController
        XCTAssertEqual(editor.linkTarget(at: link.location), LinkTarget(text: "Beta"), "just before the [[")
        XCTAssertEqual(
            editor.linkTarget(at: link.location + link.length), LinkTarget(text: "Beta"), "just after the ]]")
        XCTAssertNil(editor.linkTarget(at: link.location - 1), "the space before is not")
        XCTAssertNil(editor.linkTarget(at: link.location + link.length + 1), "nor the space after")
        XCTAssertNil(editor.linkTarget(at: -1))
        XCTAssertNil(editor.linkTarget(at: (Self.alphaBody as NSString).length + 1))
    }

    func testK3_commandEnterOutsideALinkOpensNothing() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        placeCaret(at: range(of: "tail").location + 1, in: controller)
        var opens = 0
        controller.onOpenLink = { _, _ in opens += 1 }
        XCTAssertNil(controller.editorController.linkTargetAtCaret())
        XCTAssertFalse(controller.openLinkAtCaret(), "the key is not consumed")

        try pressCommandReturn(in: window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(controller.editorController.noteID, alpha, "the editor stays on Alpha")
        XCTAssertEqual(controller.listController.selectedID, alpha)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testK3_linksInCodeSpansAndFencedBlocksAreNotLinks() async throws {
        let (controller, _) = try await makeControllerShowingAlpha()
        let editor = controller.editorController
        // Of the exact `[[Beta]]` spellings, the second is in a code span and the third in a
        // fenced block (E-2, T-1); the labelled link between them is not an exact match.
        XCTAssertNil(editor.linkTarget(at: inside("[[Beta]]", occurrence: 1)))
        XCTAssertNil(editor.linkTarget(at: inside("[[Beta]]", occurrence: 2)))
        placeCaret(at: inside("[[Beta]]", occurrence: 2), in: controller)
        XCTAssertFalse(controller.openLinkAtCaret())
        XCTAssertEqual(editor.noteID, alpha)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testK3_anEmbedIsNotOpenedAsANote() async throws {
        let (controller, _) = try await makeControllerShowingAlpha()
        placeCaret(at: inside("![[pic.png]]") + 1, in: controller)
        XCTAssertEqual(
            controller.editorController.linkTargetAtCaret(), LinkTarget(text: "pic.png", isEmbed: true))
        var opens = 0
        controller.onOpenLink = { _, _ in opens += 1 }
        var filesOpened: [URL] = []
        controller.openFile = { url in
            filesOpened.append(url)
            return true
        }
        let settled = expectation(description: "embed settled")
        controller.onOpenFile = { _, _ in settled.fulfill() }
        // An embed links to a file that is not a note (K-1): it goes the I-2 way, and here no
        // file has the name, so nothing opens and nothing is created.
        XCTAssertTrue(controller.openLinkAtCaret(), "the key is consumed")
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(filesOpened, [])
        XCTAssertNotNil(controller.inlineMessage)
        XCTAssertEqual(controller.editorController.noteID, alpha)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "no pic.png.md was created")
    }

    // MARK: K-3 Cmd-click opens the link under the pointer

    func testK3_commandClickOnALinkOpensTheResolvedNote() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let (settled, reported) = expectOpen(controller)

        try commandClick(onCharacterAt: inside("[[Beta|labelled]]"), in: controller, window: window)
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(reported()?.0, LinkTarget(text: "Beta"))
        XCTAssertEqual(reported()?.1, beta)
        XCTAssertEqual(controller.editorController.noteID, beta)
        XCTAssertEqual(controller.listController.selectedID, beta)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        await waitForEditor(controller, toShow: beta)
        XCTAssertEqual(controller.mainView.textView.string, "beta body")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testK3_commandClickOutsideALinkIsLeftToTheTextView() async throws {
        let (controller, _) = try await makeControllerShowingAlpha()
        var opens = 0
        controller.onOpenLink = { _, _ in opens += 1 }
        XCTAssertFalse(controller.openLink(at: range(of: "tail").location + 1), "the click is not consumed")
        XCTAssertFalse(controller.openLink(at: inside("[[Beta]]", occurrence: 1)), "nor is one in a code span")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(controller.editorController.noteID, alpha)
    }

    // MARK: K-3 an unresolved target is created with C-2 rules and opened

    func testK3_anUnresolvedLinkCreatesTheNoteAtTheRootAndOpensIt() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        placeCaret(at: inside("[[Missing]]"), in: controller)
        let (settled, reported) = expectOpen(controller)
        let created = NoteID(relativePath: "Missing.md")

        try pressCommandReturn(in: window)
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(reported()?.0, LinkTarget(text: "Missing"))
        XCTAssertEqual(reported()?.1, created)
        XCTAssertEqual(
            try filesOnDisk(),
            ["Alpha.md", "Gamma.md", "Missing.md", "archive/Zeta.md", "daily/Beta.md", "daily/zeta.md"])
        XCTAssertEqual(try fileText(created), "")
        XCTAssertEqual(try XCTUnwrap(controller.library?.snapshot.entry(for: created)).body, "", "indexed at once")
        XCTAssertEqual(controller.library?.snapshot.links.resolve("Missing"), .unique(created), "and resolves now")

        // Opened like a created note (C-4): selected, editor focused and empty, query kept.
        XCTAssertEqual(controller.editorController.noteID, created)
        XCTAssertEqual(controller.listController.selectedID, created)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        await waitForEditor(controller, toShow: created)
        XCTAssertEqual(controller.mainView.textView.string, "")
        XCTAssertTrue(controller.mainView.textView.isEditable)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "")
        XCTAssertNil(controller.inlineMessage)
    }

    func testK3_anUnresolvedPathTargetMakesFoldersAsEnterWould() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        placeCaret(at: inside("[[projects/New]]"), in: controller)
        let (settled, reported) = expectOpen(controller)
        let created = NoteID(relativePath: "projects/New.md")

        try pressCommandReturn(in: window)
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(reported()?.1, created)
        XCTAssertEqual(
            try filesOnDisk(),
            ["Alpha.md", "Gamma.md", "archive/Zeta.md", "daily/Beta.md", "daily/zeta.md", "projects/New.md"])
        XCTAssertEqual(try fileText(created), "")
        XCTAssertEqual(controller.editorController.noteID, created)
        XCTAssertEqual(controller.listController.selectedID, created)
        await waitForEditor(controller, toShow: created)
        XCTAssertEqual(controller.mainView.textView.string, "")
    }

    func testK3_aTargetThatCannotNameAFileIsRejectedInlineAndNothingIsCreated() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        placeCaret(at: inside("[[a:b]]"), in: controller)
        XCTAssertNil(controller.inlineMessage)
        let (settled, reported) = expectOpen(controller)

        try pressCommandReturn(in: window)
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(reported()?.0, LinkTarget(text: "a:b"))
        XCTAssertNil(reported()?.1)
        let message = try XCTUnwrap(controller.inlineMessage)
        XCTAssertTrue(message.contains(":"), "the message names the character (C-3): \(message)")
        XCTAssertFalse(controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
        XCTAssertEqual(controller.editorController.noteID, alpha, "the editor stays on Alpha")
        XCTAssertEqual(controller.listController.selectedID, alpha)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
    }

    func testK3_anAmbiguousTitleOpensTheMostRecentlyModifiedCandidate() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        XCTAssertTrue(controller.library?.snapshot.links.resolve("Zeta").isAmbiguous ?? false)
        placeCaret(at: inside("[[Zeta]]"), in: controller)
        let (settled, reported) = expectOpen(controller)

        try pressCommandReturn(in: window)
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(reported()?.1, newerZeta, "K-2: the newest of the notes with the title")
        XCTAssertEqual(controller.editorController.noteID, newerZeta)
        XCTAssertEqual(controller.listController.selectedID, newerZeta)
        await waitForEditor(controller, toShow: newerZeta)
        XCTAssertEqual(controller.mainView.textView.string, "newer zeta")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing was created")
    }

    // MARK: K-3 a standard link, autolink or bare URL opens with the default application

    /// Replaces `openURL` with one that records every URL and answers `opens`; the recorded
    /// URLs are read back through the returned closure.
    private func captureURLs(_ controller: MainWindowController, opens: Bool = true) -> () -> [URL] {
        var opened: [URL] = []
        controller.openURL = { url in
            opened.append(url)
            return opens
        }
        return { opened }
    }

    func testK3_commandEnterWithTheCaretInAStandardLinkOpensItsURL() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        placeCaret(at: range(of: "[site](https://example.com/a?b=1)").location + 2, in: controller)
        let opened = captureURLs(controller)
        var noteOpens = 0
        controller.onOpenLink = { _, _ in noteOpens += 1 }
        XCTAssertEqual(
            controller.editorController.linkAtCaret(),
            EditorLink(
                range: range(of: "[site](https://example.com/a?b=1)"), destination: .url("https://example.com/a?b=1")))
        XCTAssertNil(controller.editorController.linkTargetAtCaret(), "not a wikilink")

        try pressCommandReturn(in: window)
        XCTAssertEqual(
            opened(), [URL(string: "https://example.com/a?b=1")], "the opener receives the URL, not the text")
        XCTAssertEqual(noteOpens, 0, "no note is opened")
        XCTAssertEqual(controller.editorController.noteID, alpha, "the editor stays on Alpha")
        XCTAssertEqual(controller.listController.selectedID, alpha)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertNil(controller.inlineMessage)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing was created")
    }

    func testK3_commandEnterWithTheCaretInAnAutolinkOpensItsURLWithoutTheBrackets() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let link = range(of: "<https://example.org/x>")
        placeCaret(at: link.location + link.length - 1, in: controller)
        let opened = captureURLs(controller)
        try pressCommandReturn(in: window)
        XCTAssertEqual(opened(), [URL(string: "https://example.org/x")])
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testK3_commandClickOnABareURLOpensIt() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let opened = captureURLs(controller)
        try commandClick(
            onCharacterAt: range(of: "https://example.net/y").location + 10, in: controller, window: window)
        XCTAssertEqual(opened(), [URL(string: "https://example.net/y")])
        XCTAssertEqual(controller.editorController.noteID, alpha)
        XCTAssertNil(controller.inlineMessage)
    }

    func testK3_theCaretAtEitherEndOfAURLIsInsideIt() async throws {
        let (controller, _) = try await makeControllerShowingAlpha()
        let editor = controller.editorController
        let link = range(of: "https://example.net/y")
        let expected = EditorLink(range: link, destination: .url("https://example.net/y"))
        XCTAssertEqual(editor.link(at: link.location), expected, "just before the URL")
        XCTAssertEqual(editor.link(at: link.location + link.length), expected, "just after it")
        XCTAssertNil(editor.link(at: link.location - 1), "the space before is not")
        XCTAssertEqual(
            editor.link(containingCharacterAt: link.location + link.length - 1), expected, "its last character is")
        XCTAssertNil(editor.link(containingCharacterAt: link.location + link.length), "the character after is not")
        XCTAssertNil(editor.link(containingCharacterAt: -1))
        XCTAssertNil(editor.link(containingCharacterAt: (Self.alphaBody as NSString).length))
    }

    func testK3_anImageAndAURLInCodeAreNotLinks() async throws {
        let (controller, _) = try await makeControllerShowingAlpha()
        let editor = controller.editorController
        let opened = captureURLs(controller)
        XCTAssertNil(editor.link(at: range(of: "![i](https://example.com/i.png)").location + 8), "an image (ED-11)")
        XCTAssertNil(editor.link(at: range(of: "`https://example.com/c`").location + 5), "a URL in a code span (E-2)")
        XCTAssertFalse(controller.openLink(at: range(of: "![i](https://example.com/i.png)").location + 8))
        XCTAssertFalse(controller.openLink(at: range(of: "`https://example.com/c`").location + 5))
        XCTAssertEqual(opened(), [])
    }

    func testK3_aURLTheSystemWillNotOpenIsReportedInline() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let opened = captureURLs(controller, opens: false)
        placeCaret(at: range(of: "[rel](notes/rel.md)").location + 2, in: controller)
        XCTAssertNil(controller.inlineMessage)
        try pressCommandReturn(in: window)
        XCTAssertEqual(opened(), [URL(string: "notes/rel.md")], "the opener was asked")
        let message = try XCTUnwrap(controller.inlineMessage)
        XCTAssertTrue(message.contains("notes/rel.md"), "the message names the link: \(message)")
        XCTAssertFalse(controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(controller.editorController.noteID, alpha)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "no notes/rel.md was created")

        // A later successful open clears the message.
        _ = captureURLs(controller)
        placeCaret(at: range(of: "https://example.net/y").location + 3, in: controller)
        try pressCommandReturn(in: window)
        XCTAssertNil(controller.inlineMessage)
    }

    func testK3_aDestinationThatIsNotAURLIsReportedInlineAndNeverReachesTheOpener() async throws {
        let (controller, _) = try await makeControllerShowingAlpha()
        let opened = captureURLs(controller)
        XCTAssertTrue(controller.openExternalLink("http://[bad"), "acted on: reported")
        XCTAssertEqual(opened(), [])
        XCTAssertNotNil(controller.inlineMessage)
    }

    // MARK: K-3 with the rest of the window

    func testK3_aTargetTheQueryDoesNotListIsOpenedInTheEditorAloneWithTheQueryKept() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        controller.mainView.searchField.stringValue = "alpha"
        controller.searchQueryDidChange()
        XCTAssertEqual(controller.listController.results.map(\.id), [alpha])
        placeCaret(at: inside("[[Beta]]"), in: controller)
        let (settled, reported) = expectOpen(controller)

        try pressCommandReturn(in: window)
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(reported()?.1, beta)
        XCTAssertEqual(controller.editorController.noteID, beta)
        XCTAssertNil(controller.listController.selectedID, "Beta is not listed under the query, so nothing is selected")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "alpha", "the query is kept")
        XCTAssertEqual(controller.query, "alpha")
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        await waitForEditor(controller, toShow: beta)
        XCTAssertEqual(controller.mainView.textView.string, "beta body")
    }

    func testK3_openingALinkWritesUnsavedEditsToTheNoteLeftFirst() async throws {
        let (controller, window) = try await makeControllerShowingAlpha()
        let textView = controller.mainView.textView
        let end = (Self.alphaBody as NSString).length
        textView.insertText("typed", replacementRange: NSRange(location: end, length: 0))
        XCTAssertTrue(controller.editorController.hasUnsavedEdits)
        XCTAssertEqual(try fileText(alpha), Self.alphaBody, "not written yet")
        placeCaret(at: inside("[[Beta]]"), in: controller)
        let (settled, _) = expectOpen(controller)

        try pressCommandReturn(in: window)
        await fulfillment(of: [settled], timeout: 10)
        await waitForEditor(controller, toShow: beta)
        await waitUntil("Alpha written") { (try? self.fileText(self.alpha)) == Self.alphaBody + "typed" }
        XCTAssertEqual(try fileText(alpha), Self.alphaBody + "typed", "E-4: leaving a note saves it")
        XCTAssertEqual(controller.mainView.textView.string, "beta body")
    }
}
