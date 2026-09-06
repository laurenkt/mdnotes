import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the note list (S-6) and for selection driving the editor (S-8).
@MainActor
final class NoteListSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Three notes, written oldest first, so list order is Gamma, Beta, Alpha (S-3).
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "# Alpha\n\nFirst line of alpha.\nSecond line."),
        ("daily/Beta.md", "Beta body with  Mixed CASE\n\tand tabs"),
        ("Gamma.md", ""),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-list-\(UUID().uuidString)", isDirectory: true)
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

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    /// A laid-out window whose list shows the whole library, read synchronously off a scan.
    private func makeControllerShowingIndex() throws -> (MainWindowController, SearchIndex) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let index = SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: NoteStore(root: root))
        controller.listController.show(index.query(""))
        return (controller, index)
    }

    /// A laid-out window with a started library attached, returned once the library is ready.
    private func makeControllerWithLibrary(noteCount: Int = 3) async throws -> (
        MainWindowController, LibraryController
    ) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.count, noteCount)
        return (controller, library)
    }

    /// Spins the main queue until `condition` holds, failing after `timeout`.
    private func waitUntil(
        _ what: String, timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Runs `trigger` and waits for the editor's next `onLoad`, returning the id it reported.
    private func loadAfter(_ editor: EditorController, _ trigger: () -> Void) async -> NoteID?? {
        let loaded = expectation(description: "editor loaded")
        var reported: NoteID?? = nil
        editor.onLoad = { id in
            reported = .some(id)
            loaded.fulfill()
        }
        trigger()
        await fulfillment(of: [loaded], timeout: 10)
        editor.onLoad = nil
        return reported
    }

    private func rowView(_ controller: MainWindowController, _ row: Int) throws -> NoteRowView {
        try XCTUnwrap(controller.mainView.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NoteRowView)
    }

    // MARK: S-6 rows

    func testS6_rowShowsTitleModifiedDateAndSingleLineSnippet() throws {
        let (controller, index) = try makeControllerShowingIndex()
        let list = controller.listController
        XCTAssertEqual(list.results.map(\.id), [gamma, beta, alpha])
        XCTAssertEqual(controller.mainView.tableView.numberOfRows, 3)

        let row = try rowView(controller, 1)
        let entry = try XCTUnwrap(index.entry(for: beta))
        XCTAssertEqual(row.titleLabel.stringValue, "Beta", "title is the filename without .md (L-5)")
        XCTAssertEqual(row.dateLabel.stringValue, list.dateText(for: entry.modifiedAt))
        XCTAssertFalse(row.dateLabel.stringValue.isEmpty)
        XCTAssertEqual(row.snippetLabel.stringValue, "Beta body with Mixed CASE and tabs")
        XCTAssertFalse(row.snippetLabel.stringValue.contains(where: \.isNewline))
        XCTAssertEqual(row.snippetLabel.maximumNumberOfLines, 1)

        XCTAssertEqual(try rowView(controller, 0).titleLabel.stringValue, "Gamma")
        XCTAssertEqual(try rowView(controller, 0).snippetLabel.stringValue, "", "empty body, empty snippet")
        XCTAssertEqual(try rowView(controller, 2).snippetLabel.stringValue, "# Alpha First line of alpha. Second line.")

        // The three labels sit inside the row, date at the trailing edge, snippet below the title.
        row.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(row.titleLabel.frame.width, 0)
        XCTAssertGreaterThan(row.dateLabel.frame.width, 0)
        XCTAssertLessThanOrEqual(row.titleLabel.frame.maxX, row.dateLabel.frame.minX)
        XCTAssertLessThanOrEqual(row.dateLabel.frame.maxX, row.bounds.width)
        XCTAssertGreaterThan(row.snippetLabel.frame.minY, row.titleLabel.frame.minY)
        XCTAssertLessThanOrEqual(row.snippetLabel.frame.maxY, row.bounds.height)
    }

    func testS6_rowsAreUniformHeight() throws {
        let (controller, _) = try makeControllerShowingIndex()
        let table = controller.mainView.tableView
        XCTAssertFalse(table.usesAutomaticRowHeights)
        XCTAssertEqual(table.rowHeight, NoteListController.rowHeight)
        let heights = (0..<table.numberOfRows).map { table.rect(ofRow: $0).height }
        XCTAssertEqual(Set(heights).count, 1)
        XCTAssertEqual(heights.first ?? 0, NoteListController.rowHeight + table.intercellSpacing.height)
        for row in 0..<table.numberOfRows {
            XCTAssertEqual(try rowView(controller, row).frame.height, NoteListController.rowHeight, accuracy: 0.5)
        }
    }

    // MARK: S-8 selection loads the editor

    func testS8_selectingARowLoadsTheEditorWithTheFileBody() async throws {
        let (controller, _) = try await makeControllerWithLibrary()
        let table = controller.mainView.tableView
        let editor = controller.editorController
        XCTAssertNil(editor.noteID)
        XCTAssertEqual(controller.mainView.textView.string, "")

        let reported = await loadAfter(editor) {
            table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        }
        XCTAssertEqual(reported, .some(alpha))
        XCTAssertEqual(editor.noteID, alpha)
        XCTAssertEqual(controller.listController.selectedID, alpha)
        XCTAssertEqual(controller.mainView.textView.string, try fileText(alpha))
        XCTAssertTrue(controller.mainView.textView.isEditable)

        let next = await loadAfter(editor) { table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) }
        XCTAssertEqual(next, .some(beta))
        XCTAssertEqual(controller.mainView.textView.string, try fileText(beta))
    }

    func testS8_selectionDoesNotStealFocusFromTheList() async throws {
        let (controller, _) = try await makeControllerWithLibrary()
        let window = try XCTUnwrap(controller.window)
        let table = controller.mainView.tableView
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertIdentical(window.firstResponder, table)

        _ = await loadAfter(controller.editorController) {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        XCTAssertEqual(controller.editorController.noteID, gamma)
        XCTAssertIdentical(window.firstResponder, table, "loading the editor must not move focus")
    }

    func testS8_reloadKeepsTheSelectedNoteWithoutReloadingTheEditor() async throws {
        let (controller, library) = try await makeControllerWithLibrary()
        let table = controller.mainView.tableView
        let list = controller.listController
        _ = await loadAfter(controller.editorController) {
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        }
        XCTAssertEqual(list.selectedID, beta)
        var loads = 0
        controller.editorController.onLoad = { _ in loads += 1 }

        // Alpha becomes the newest note, so it moves to row 0 and Beta shifts down to row 2.
        try write(alpha.relativePath, body: "changed", modifiedAt: Self.base.addingTimeInterval(3600))
        library.apply(LibraryChanges(modified: [alpha]))
        await waitUntil("list reloaded") { list.results.first?.id == self.alpha }

        XCTAssertEqual(list.results.map(\.id), [alpha, gamma, beta])
        XCTAssertEqual(table.selectedRow, 2, "the selection follows the note to its new row")
        XCTAssertEqual(list.selectedID, beta)
        XCTAssertEqual(controller.editorController.noteID, beta)
        XCTAssertEqual(loads, 0, "the editor is not reloaded because the list around it changed")
        XCTAssertEqual(try rowView(controller, 0).snippetLabel.stringValue, "changed")
    }

    func testS8_deselectingClearsTheEditor() async throws {
        let (controller, _) = try await makeControllerWithLibrary()
        let table = controller.mainView.tableView
        let editor = controller.editorController
        _ = await loadAfter(editor) { table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false) }
        XCTAssertEqual(controller.mainView.textView.string, try fileText(alpha))

        let reported = await loadAfter(editor) { table.deselectAll(nil) }
        XCTAssertEqual(reported, .some(nil))
        XCTAssertNil(editor.noteID)
        XCTAssertNil(controller.listController.selectedID)
        XCTAssertEqual(controller.mainView.textView.string, "")
        XCTAssertFalse(controller.mainView.textView.isEditable)
    }

    func testS8_aSlowerEarlierLoadNeverOverwritesTheLaterSelection() async throws {
        let (controller, library) = try await makeControllerWithLibrary()
        let editor = controller.editorController
        let loaded = expectation(description: "beta loaded")
        editor.onLoad = { id in
            if id == self.beta { loaded.fulfill() }
        }
        editor.load(alpha, from: library)
        editor.load(beta, from: library)
        await fulfillment(of: [loaded], timeout: 10)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.noteID, beta)
        XCTAssertEqual(controller.mainView.textView.string, try fileText(beta))
    }

    func testL8_undecodableNoteIsShownReadOnly() async throws {
        let bad = NoteID(relativePath: "Bad.md")
        try Data([0xFF, 0xFE] + Array("hi".utf8)).write(to: root.appendingPathComponent(bad.relativePath))
        let (controller, library) = try await makeControllerWithLibrary(noteCount: 4)
        let editor = controller.editorController
        let reported = await loadAfter(editor) { editor.load(bad, from: library) }
        XCTAssertEqual(reported, .some(bad))
        XCTAssertFalse(controller.mainView.textView.isEditable)
        XCTAssertTrue(controller.mainView.textView.string.hasSuffix("hi"))
        XCTAssertEqual(editor.body?.isWritable, false)
    }
}
