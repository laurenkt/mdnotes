import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for Enter in the search field (C-1 to C-4). The query is typed into
/// the window's real field editor and Return is a real `NSEvent` sent through the window, so
/// the delegate sees the same `insertNewline:` a user's key press produces.
@MainActor
final class CreateSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Written oldest first, so the empty query lists Gamma, Beta, Alpha (S-3).
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "alpha body"),
        ("daily/Beta.md", "beta body"),
        ("Gamma.md", "gamma body"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-create-\(UUID().uuidString)", isDirectory: true)
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

    /// Adds a note beyond the fixture's three, before the library is started.
    private func writeExtra(_ id: NoteID, body: String, modifiedAt: Date) throws {
        let url = root.appendingPathComponent(id.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    /// A laid-out window with a ready library attached and the search field focused, as at
    /// launch. `expecting` is the list the empty query should show once the library is ready.
    private func makeController(expecting expected: [NoteID]? = nil) async throws -> (MainWindowController, NSWindow) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), expected ?? [gamma, beta, alpha])
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        XCTAssertTrue(searchFieldHasFocus(controller))
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

    /// Types `text` one character at a time into the focused search field.
    private func type(_ text: String, into controller: MainWindowController) throws {
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    /// Presses Return in the window (a `keyDown` then a `keyUp`, as the event loop delivers
    /// them) and waits for the create-or-open to settle, returning the note it reported.
    private func pressReturnAndSettle(_ controller: MainWindowController, in window: NSWindow) async throws -> NoteID? {
        let settled = expectation(description: "commit settled")
        var reported: NoteID?
        controller.onCommitQuery = { id in
            reported = id
            settled.fulfill()
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(event)
        }
        await fulfillment(of: [settled], timeout: 10)
        controller.onCommitQuery = nil
        return reported
    }

    /// A focused text field's first responder is its field editor, not the field itself.
    private func searchFieldHasFocus(_ controller: MainWindowController) -> Bool {
        guard let editor = controller.window?.firstResponder as? NSTextView else { return false }
        return editor.isFieldEditor && editor.delegate === controller.mainView.searchField
    }

    /// Every file under the root, as relative paths, hidden files included.
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

    private let fixtureFiles = ["Alpha.md", "Gamma.md", "daily/Beta.md"]

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    // MARK: C-1 Enter opens a note whose title equals the query, else creates

    func testC1_enterOpensTheNoteWhoseTitleEqualsTheQueryIgnoringCase() async throws {
        let (controller, window) = try await makeController()
        try type("ALPHA", into: controller)
        XCTAssertEqual(controller.listController.results.map(\.id), [alpha])

        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, alpha)
        XCTAssertEqual(controller.listController.selectedID, alpha, "the existing note is selected")
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView, "and the editor is focused")
        await waitForEditor(controller, toShow: alpha)
        XCTAssertEqual(controller.mainView.textView.string, "alpha body")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing was created")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "ALPHA")
        XCTAssertNil(controller.inlineMessage)
    }

    func testC1_enterOpensANestedNoteByItsTitle() async throws {
        let (controller, window) = try await makeController()
        try type("beta", into: controller)
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, beta, "the title is the filename alone (L-5), wherever the file is")
        XCTAssertEqual(controller.listController.selectedID, beta)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        await waitForEditor(controller, toShow: beta)
        XCTAssertEqual(controller.mainView.textView.string, "beta body")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "no beta.md was created at the root")
    }

    func testC1_enterOpensTheMostRecentlyModifiedOfSeveralNotesWithTheTitle() async throws {
        // Two Zetas in different folders, neither at the path the query would create.
        let older = NoteID(relativePath: "archive/Zeta.md")
        let newer = NoteID(relativePath: "daily/zeta.md")
        try writeExtra(older, body: "older zeta", modifiedAt: Self.base.addingTimeInterval(1800))
        try writeExtra(newer, body: "newer zeta", modifiedAt: Self.base.addingTimeInterval(3600))
        let (controller, window) = try await makeController(expecting: [newer, older, gamma, beta, alpha])
        try type("zeta", into: controller)
        XCTAssertEqual(controller.listController.results.map(\.id), [newer, older])

        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, newer, "the same rule as an ambiguous link (K-2): the newest candidate")
        XCTAssertEqual(controller.listController.selectedID, newer)
        await waitForEditor(controller, toShow: newer)
        XCTAssertEqual(controller.mainView.textView.string, "newer zeta")
        XCTAssertEqual(
            try filesOnDisk(), ["Alpha.md", "Gamma.md", "archive/Zeta.md", "daily/Beta.md", "daily/zeta.md"])
    }

    func testC1_enterPrefersTheNoteAtThePathTheQueryWouldCreate() async throws {
        // A second Alpha, newer than the root one, deeper in the tree. The query "Alpha" names
        // the root file, so that is the one opened: it is the file creation would write over.
        let nested = NoteID(relativePath: "archive/alpha.md")
        try writeExtra(nested, body: "nested alpha", modifiedAt: Self.base.addingTimeInterval(3600))
        let (controller, window) = try await makeController(expecting: [nested, gamma, beta, alpha])
        try type("Alpha", into: controller)
        XCTAssertEqual(controller.listController.results.map(\.id), [nested, alpha])

        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, alpha)
        XCTAssertEqual(controller.listController.selectedID, alpha)
        await waitForEditor(controller, toShow: alpha)
        XCTAssertEqual(controller.mainView.textView.string, "alpha body")
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md", "archive/alpha.md", "daily/Beta.md"])
    }

    func testC1_enterWithAPathQueryOpensTheNoteAtThatPathAndNeverOverwritesIt() async throws {
        let (controller, window) = try await makeController()
        try type("daily/beta", into: controller)
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, beta, "the file the query would create already exists, so it is opened")
        XCTAssertEqual(controller.editorController.noteID, beta)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        await waitForEditor(controller, toShow: beta)
        XCTAssertEqual(controller.mainView.textView.string, "beta body")
        XCTAssertEqual(try fileText(beta), "beta body", "the file is untouched")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testC1_enterWithNoEqualTitleCreatesEvenWhenTheListHasMatches() async throws {
        let (controller, window) = try await makeController()
        try type("alph", into: controller)
        XCTAssertEqual(controller.listController.results.map(\.id), [alpha], "a substring match is listed")

        let created = NoteID(relativePath: "alph.md")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created, "but only an equal title opens; anything else creates")
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md", "alph.md", "daily/Beta.md"])
        XCTAssertEqual(try fileText(created), "")
        XCTAssertEqual(controller.listController.selectedID, created)
    }

    func testC1_enterWithABlankQueryDoesNothing() async throws {
        let (controller, window) = try await makeController()
        var commits = 0
        controller.onCommitQuery = { _ in commits += 1 }
        XCTAssertFalse(controller.commitQuery(), "an empty query is not consumed")
        try type("   ", into: controller)
        XCTAssertFalse(controller.commitQuery(), "nor is a blank one")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
        XCTAssertTrue(searchFieldHasFocus(controller))
        XCTAssertNil(controller.editorController.noteID)
        XCTAssertNil(controller.inlineMessage)
    }

    // MARK: C-2 creation writes <query>.md at the root, folders for `/`, trimmed

    func testC2_creationWritesTheQueryAsAnEmptyMDFileAtTheRoot() async throws {
        let (controller, window) = try await makeController()
        try type("Shopping list", into: controller)
        XCTAssertEqual(controller.listController.results.count, 0)

        let created = NoteID(relativePath: "Shopping list.md")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created)
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md", "Shopping list.md", "daily/Beta.md"])
        XCTAssertEqual(try fileText(created), "")
        XCTAssertEqual(try XCTUnwrap(controller.library?.snapshot.entry(for: created)).body, "", "indexed at once")
    }

    func testC2_slashSegmentsBecomeFoldersCreatedAsNeeded() async throws {
        let (controller, window) = try await makeController()
        try type("daily/2026/06-sunday", into: controller)

        let created = NoteID(relativePath: "daily/2026/06-sunday.md")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created)
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md", "daily/2026/06-sunday.md", "daily/Beta.md"])
        XCTAssertEqual(try fileText(created), "")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("daily/2026").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the missing folder was made under the existing one")
        XCTAssertEqual(controller.editorController.noteID, created)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        await waitForEditor(controller, toShow: created)
        XCTAssertEqual(controller.mainView.textView.string, "")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "daily/2026/06-sunday", "the query is kept")
        XCTAssertNotNil(controller.library?.snapshot.entry(for: created), "the snapshot lists it")
    }

    func testC2_theQueryIsTrimmedBeforeCreation() async throws {
        let (controller, window) = try await makeController()
        try type("  Padded title ", into: controller)

        let created = NoteID(relativePath: "Padded title.md")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created)
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md", "Padded title.md", "daily/Beta.md"])
        XCTAssertEqual(controller.mainView.searchField.stringValue, "  Padded title ", "the field itself is not edited")
        XCTAssertEqual(controller.listController.results.map(\.id), [created])
        XCTAssertEqual(controller.listController.selectedID, created)
    }

    // MARK: C-3 illegal characters are rejected inline; nothing is created

    func testC3_colonIsRejectedInlineAndNothingIsCreated() async throws {
        let (controller, window) = try await makeController()
        try type("meeting: notes", into: controller)
        XCTAssertNil(controller.inlineMessage)
        XCTAssertTrue(controller.mainView.messageLabel.isHidden)

        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertNil(reported)
        let message = try XCTUnwrap(controller.inlineMessage)
        XCTAssertTrue(message.contains(":"), "the message names the character: \(message)")
        XCTAssertFalse(controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(controller.mainView.messageLabel.stringValue, message)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing was created")
        XCTAssertTrue(searchFieldHasFocus(controller), "focus stays in the field to fix the query")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "meeting: notes", "the query is kept")
        XCTAssertNil(controller.editorController.noteID)
        XCTAssertEqual(controller.listController.selectedID, nil)

        // The message is laid out under the field, above the list.
        controller.mainView.layoutSubtreeIfNeeded()
        let label = controller.mainView.messageLabel
        XCTAssertGreaterThan(label.frame.height, 0)
        XCTAssertLessThanOrEqual(label.frame.maxY, controller.mainView.searchField.frame.minY)
        XCTAssertGreaterThanOrEqual(label.frame.minY, controller.mainView.splitView.frame.maxY)

        // The next keystroke clears it.
        try type("!", into: controller)
        XCTAssertNil(controller.inlineMessage)
        XCTAssertTrue(controller.mainView.messageLabel.isHidden)
    }

    func testC3_nulIsRejectedInline() async throws {
        let (controller, _) = try await makeController()
        controller.mainView.searchField.stringValue = "nul\0here"
        controller.searchQueryDidChange()
        var reported: NoteID?? = nil
        controller.onCommitQuery = { reported = .some($0) }
        XCTAssertTrue(controller.commitQuery())
        XCTAssertEqual(reported, .some(nil))
        XCTAssertNotNil(controller.inlineMessage)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testC3_emptyAndDotSegmentsAreRejectedInline() async throws {
        let (controller, window) = try await makeController()
        for query in ["a//b", "trailing/", "/leading", "../escape", ".hidden", "daily/.hidden"] {
            controller.mainView.searchField.stringValue = query
            controller.searchQueryDidChange()
            XCTAssertNil(controller.inlineMessage, "a fresh query has no message")
            let reported = try await pressReturnAndSettle(controller, in: window)
            XCTAssertNil(reported, query)
            XCTAssertNotNil(controller.inlineMessage, query)
            XCTAssertEqual(try filesOnDisk(), fixtureFiles, "\(query) created something")
            XCTAssertTrue(searchFieldHasFocus(controller), query)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["Alpha.md", "Gamma.md", "daily"],
            "no folder was created either")
    }

    func testC3_reservedRootFoldersAreRejectedInline() async throws {
        let (controller, window) = try await makeController()
        for query in ["Trash/gone", "templates/daily"] {
            controller.mainView.searchField.stringValue = query
            controller.searchQueryDidChange()
            let reported = try await pressReturnAndSettle(controller, in: window)
            XCTAssertNil(reported, query)
            XCTAssertNotNil(controller.inlineMessage, query)
            XCTAssertEqual(try filesOnDisk(), fixtureFiles, "\(query) created something")
        }
    }

    // MARK: C-4 after creation: selected, editor focused and empty, query kept

    func testC4_afterCreationTheNewNoteIsSelectedTheEditorFocusedAndEmptyAndTheQueryKept() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        try type("Delta", into: controller)
        XCTAssertEqual(controller.listController.results.count, 0)

        let created = NoteID(relativePath: "Delta.md")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created)

        // The search field keeps the query, and the list, reloaded for it, shows the new note.
        XCTAssertEqual(controller.mainView.searchField.stringValue, "Delta")
        XCTAssertEqual(controller.query, "Delta")
        XCTAssertEqual(controller.listController.results.map(\.id), [created])
        XCTAssertEqual(table.numberOfRows, 1)

        // The new note is selected.
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(controller.listController.selectedID, created)

        // The editor is focused, shows the new note, and is empty and writable.
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertEqual(controller.editorController.noteID, created)
        XCTAssertEqual(controller.mainView.textView.string, "")
        await waitForEditor(controller, toShow: created)
        XCTAssertEqual(controller.mainView.textView.string, "")
        XCTAssertTrue(controller.mainView.textView.isEditable)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView, "the load did not move focus")
        XCTAssertNil(controller.inlineMessage)
    }

    func testC4_aNewMultiWordNoteIsListedFirstUnderItsQuery() async throws {
        let (controller, window) = try await makeController()
        // Every word of the query is in the new title, so the kept query lists it (S-2).
        try type("a fresh note", into: controller)
        XCTAssertEqual(controller.listController.results.count, 0)
        let created = NoteID(relativePath: "a fresh note.md")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created)
        XCTAssertEqual(controller.listController.results.map(\.id), [created])
        XCTAssertEqual(controller.listController.selectedID, created)

        // Widening the query to "a", which every fixture body contains, keeps the new note
        // selected and at the top: it is the newest title match (S-3).
        controller.mainView.searchField.stringValue = "a"
        controller.searchQueryDidChange()
        XCTAssertEqual(controller.listController.results.first?.id, created)
        XCTAssertEqual(controller.listController.selectedID, created)
    }

    func testC4_afterANestedCreationTheKeptQueryListsAndSelectsTheNewNote() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        try type("daily/foo", into: controller)
        XCTAssertEqual(controller.listController.results.count, 0)

        let created = NoteID(relativePath: "daily/foo.md")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created)
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md", "daily/Beta.md", "daily/foo.md"])

        // The query is kept and, matched against the path (S-2, ADR-0008), lists the new
        // note, whose title is only `foo` (L-5), so it can be selected (C-4).
        XCTAssertEqual(controller.mainView.searchField.stringValue, "daily/foo")
        XCTAssertEqual(controller.query, "daily/foo")
        XCTAssertEqual(controller.listController.results.map(\.id), [created])
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(controller.listController.selectedID, created)

        // The editor is focused, shows the new note, and is empty and writable.
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertEqual(controller.editorController.noteID, created)
        await waitForEditor(controller, toShow: created)
        XCTAssertEqual(controller.mainView.textView.string, "")
        XCTAssertTrue(controller.mainView.textView.isEditable)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView, "the load did not move focus")
        XCTAssertNil(controller.inlineMessage)
    }

    func testC4_openingANestedNoteByItsPathSelectsItInTheList() async throws {
        let (controller, window) = try await makeController()
        try type("daily/beta", into: controller)
        XCTAssertEqual(
            controller.listController.results.map(\.id), [beta], "the path-form query lists the note as typed (S-2)")

        // C-1: the note at that path is opened, and since the kept query lists it, selected.
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, beta)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "daily/beta", "the query is kept")
        XCTAssertEqual(controller.listController.results.map(\.id), [beta])
        XCTAssertEqual(controller.mainView.tableView.selectedRow, 0)
        XCTAssertEqual(controller.listController.selectedID, beta)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertEqual(controller.editorController.noteID, beta)
        await waitForEditor(controller, toShow: beta)
        XCTAssertEqual(controller.mainView.textView.string, "beta body")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing was created")
    }

    func testC4_enterOnAnAlreadyCreatedTitleReopensItInsteadOfCreatingAgain() async throws {
        let (controller, window) = try await makeController()
        try type("Twice", into: controller)
        let created = NoteID(relativePath: "Twice.md")
        let first = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(first, created)
        await waitForEditor(controller, toShow: created)
        let stamp = try XCTUnwrap(controller.library?.snapshot.entry(for: created)?.modifiedAt)

        // Back to the field, Enter again: same note, same file, no second write.
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        let second = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(second, created)
        XCTAssertEqual(controller.listController.selectedID, created)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md", "Twice.md", "daily/Beta.md"])
        XCTAssertEqual(controller.library?.snapshot.entry(for: created)?.modifiedAt, stamp)
    }
}
