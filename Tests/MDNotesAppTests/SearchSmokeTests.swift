import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the search field (S-1) driving the list on every keystroke (S-5).
/// Keystrokes go through the window's real field editor, so they take the path a user's do.
@MainActor
final class SearchSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Written oldest first, so the empty query lists Gamma, Beta, Alpha (S-3).
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "alpha body mentions beta once"),
        ("daily/Beta.md", "Beta body with a #tag"),
        ("Gamma.md", "gamma has nothing in common but this"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-search-\(UUID().uuidString)", isDirectory: true)
        for (i, note) in Self.notes.enumerated() {
            try write(note.path, body: note.body, modifiedAt: Self.base.addingTimeInterval(Double(i) * 60))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    private func write(_ relativePath: String, body: String, modifiedAt: Date) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    /// A laid-out window with a ready library attached and the search field focused.
    private func makeController() async throws -> (MainWindowController, LibraryController) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        // No watcher: these tests feed changes through apply(_:) themselves.
        let library = LibraryController(root: root, watchesFileSystem: false)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        return (controller, library)
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

    /// The field editor currently editing the search field.
    private func fieldEditor(_ controller: MainWindowController) throws -> NSTextView {
        try XCTUnwrap(
            controller.mainView.searchField.currentEditor() as? NSTextView, "search field is not being edited")
    }

    /// Types `text` one character at a time, as key presses would.
    private func type(_ text: String, into controller: MainWindowController) throws {
        let editor = try fieldEditor(controller)
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    private func listedIDs(_ controller: MainWindowController) -> [NoteID] {
        controller.listController.results.map(\.id)
    }

    // MARK: S-1 one field, both search box and (later) new-note box

    func testS1_theSearchFieldIsTheWindowsInitialFirstResponderAndDrivesTheList() async throws {
        let (controller, _) = try await makeController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertIdentical(window.initialFirstResponder, controller.mainView.searchField)
        XCTAssertIdentical(controller.mainView.searchField.delegate, controller)
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(listedIDs(controller), [gamma, beta, alpha])

        try type("gamma", into: controller)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "gamma")
        XCTAssertEqual(controller.query, "gamma")
        XCTAssertEqual(listedIDs(controller), [gamma])
    }

    // MARK: S-5 every keystroke reloads

    func testS5_everyKeystrokeReQueriesAndReloadsTheTable() async throws {
        let (controller, library) = try await makeController()
        let table = controller.mainView.tableView
        var reloads: [(query: String, rows: Int)] = []
        let editor = try fieldEditor(controller)

        for character in "beta" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            reloads.append((controller.query, table.numberOfRows))
            XCTAssertEqual(
                listedIDs(controller), library.snapshot.query(controller.query).map(\.id),
                "after typing \"\(controller.query)\" the list shows that query's results")
        }
        XCTAssertEqual(reloads.map(\.query), ["b", "be", "bet", "beta"], "one reload per keystroke")
        // "b" is in every body; "be" onwards only in Beta (title) and Alpha (body), title first (S-3).
        XCTAssertEqual(reloads.map(\.rows), [3, 2, 2, 2])
        XCTAssertEqual(listedIDs(controller), [beta, alpha])

        // Deleting is a keystroke too.
        editor.deleteBackward(nil)
        XCTAssertEqual(controller.query, "bet")
        editor.deleteBackward(nil)
        editor.deleteBackward(nil)
        editor.deleteBackward(nil)
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(listedIDs(controller), [gamma, beta, alpha])

        // A query nothing matches empties the list; the table agrees with the results.
        try type("zqx", into: controller)
        XCTAssertEqual(listedIDs(controller), [])
        XCTAssertEqual(table.numberOfRows, 0)
    }

    func testS5_theCancelButtonActionClearsTheQueryAndReloads() async throws {
        let (controller, _) = try await makeController()
        try type("alpha", into: controller)
        XCTAssertEqual(listedIDs(controller), [alpha])

        // The cancel button empties the field and sends the field's action, not a keystroke.
        let field = controller.mainView.searchField
        field.stringValue = ""
        XCTAssertTrue(field.sendAction(field.action, to: field.target))
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(listedIDs(controller), [gamma, beta, alpha])
    }

    func testS5_aSnapshotPublishedMidQueryIsShownThroughTheQuery() async throws {
        let (controller, library) = try await makeController()
        try type("beta", into: controller)
        XCTAssertEqual(listedIDs(controller), [beta, alpha])

        let fresh = NoteID(relativePath: "Betamax.md")
        try write(fresh.relativePath, body: "brand new", modifiedAt: Self.base.addingTimeInterval(3600))
        library.apply(LibraryChanges(added: [fresh]))
        await waitUntil("snapshot with the new note") { library.snapshot.count == 4 }

        XCTAssertEqual(controller.query, "beta", "a publish never resets the query")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "beta")
        XCTAssertEqual(listedIDs(controller), [fresh, beta, alpha], "the newest title match leads (S-3)")
    }

    func testS5_narrowingKeepsTheSelectedNoteWhileItIsStillListed() async throws {
        let (controller, _) = try await makeController()
        let table = controller.mainView.tableView
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(controller.listController.selectedID, alpha)
        await waitUntil("editor shows alpha") { controller.editorController.noteID == self.alpha }

        try type("beta", into: controller)
        XCTAssertEqual(listedIDs(controller), [beta, alpha])
        XCTAssertEqual(table.selectedRow, 1, "the selection follows Alpha to its new row")
        XCTAssertEqual(controller.listController.selectedID, alpha)

        try type(" tag", into: controller)
        XCTAssertEqual(listedIDs(controller), [beta])
        XCTAssertEqual(table.selectedRow, -1, "Alpha dropped out, so nothing is selected")
        XCTAssertNil(controller.listController.selectedID)
        await waitUntil("editor cleared") { controller.editorController.noteID == nil }
    }
}
