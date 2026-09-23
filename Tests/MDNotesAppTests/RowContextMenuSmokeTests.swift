import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for a note row's context menu (R-4). The menu is asked of the table
/// with a real right-click (or Ctrl-click) `NSEvent` at the row, as AppKit asks it, and its
/// items are performed through `NSMenu`, so each acts through its own target and action. Copy
/// Link writes to a private pasteboard, Show in Finder to a stub, and Move to Trash moves a
/// file of the temporary library to the Trash, removed again at teardown.
@MainActor
final class RowContextMenuSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    /// Files this test put in the Trash, removed again at teardown.
    private var trashed: [URL] = []
    /// The private pasteboard Copy Link writes to, released at teardown.
    private var pasteboard: NSPasteboard?

    /// Written oldest first, so the empty query lists archive/Gamma, Gamma, Beta, Alpha (S-3).
    /// Two notes are titled Gamma; the root one owns the bare title (K-2, ADR-0023).
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "alpha body"),
        ("daily/Beta.md", "beta body"),
        ("Gamma.md", "gamma body"),
        ("archive/Gamma.md", "archived gamma body"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")
    private let archivedGamma = NoteID(relativePath: "archive/Gamma.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-row-menu-\(UUID().uuidString)", isDirectory: true)
        for (i, note) in Self.notes.enumerated() {
            try write(note.path, note.body, modifiedAt: Self.base.addingTimeInterval(Double(i) * 60))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        for url in trashed { try? FileManager.default.removeItem(at: url) }
        trashed = []
        pasteboard?.releaseGlobally()
        pasteboard = nil
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let library: LibraryController
        let window: NSWindow
        var editor: EditorController { controller.editorController }
        var list: NoteListController { controller.listController }
        var table: NoteTableView { controller.mainView.tableView }
    }

    /// Main-actor box so a library can ride inside a `@Sendable` teardown block.
    @MainActor
    private final class LibraryBox {
        let library: LibraryController
        init(_ library: LibraryController) { self.library = library }
    }

    private func write(_ relativePath: String, _ body: String, modifiedAt: Date) throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    /// A laid-out window with a ready, watching library attached, Copy Link writing to a
    /// private pasteboard and Show in Finder recording into nothing until a test says so.
    private func makeFixture() async throws -> Fixture {
        let controller = makeMainWindowController(autosaveClock: ManualAutosaveClock())
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let board = NSPasteboard(name: NSPasteboard.Name("mdnotes-row-menu-\(UUID().uuidString)"))
        pasteboard = board
        controller.pasteboard = board
        controller.revealInFinder = { _ in XCTFail("nothing should be revealed") }
        let library = LibraryController(root: root)
        let box = LibraryBox(library)
        addTeardownBlock { await MainActor.run { box.library.stop() } }
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [archivedGamma, gamma, beta, alpha])
        let window = try XCTUnwrap(controller.window)
        return Fixture(controller: controller, library: library, window: window)
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

    /// Selects the row showing `id`, focuses the list, and waits for the editor to show the body.
    private func select(_ id: NoteID, in fixture: Fixture) async throws {
        let row = try XCTUnwrap(fixture.list.results.firstIndex { $0.id == id })
        fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.table))
        await waitUntil("editor shows \(id.relativePath)") {
            fixture.editor.noteID == id && fixture.editor.body != nil
        }
    }

    private func row(of id: NoteID, in fixture: Fixture) throws -> Int {
        try XCTUnwrap(fixture.list.results.firstIndex { $0.id == id }, "\(id) is not listed")
    }

    /// A right-click (or, with `control`, a Ctrl-click) at `point` in the table's coordinates.
    private func click(at point: NSPoint, control: Bool = false, in fixture: Fixture) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: control ? .leftMouseDown : .rightMouseDown,
                location: fixture.table.convert(point, to: nil), modifierFlags: control ? .control : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The menu AppKit would show for a right-click in the middle of `row`, or nil.
    private func rowMenu(forRow row: Int, control: Bool = false, in fixture: Fixture) throws -> NSMenu? {
        let rect = fixture.table.rect(ofRow: row)
        return fixture.table.menu(
            for: try click(at: NSPoint(x: rect.midX, y: rect.midY), control: control, in: fixture))
    }

    /// Right-clicks the row showing `id` and performs the item titled `title` of its menu.
    private func perform(_ title: String, on id: NoteID, in fixture: Fixture) throws {
        let menu = try XCTUnwrap(try rowMenu(forRow: try row(of: id, in: fixture), in: fixture), "no menu for \(id)")
        let index = menu.indexOfItem(withTitle: title)
        XCTAssertGreaterThanOrEqual(index, 0, "no \(title) item")
        XCTAssertTrue(menu.items[index].isEnabled)
        menu.performActionForItem(at: index)
        fixture.table.didCloseMenu(menu, with: nil)
    }

    /// Presses Return in the window as a user does: a `keyDown` then a `keyUp`.
    private func pressReturn(in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                    keyCode: 36))
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
    }

    /// Runs `trigger` and waits for the deletion it begins to settle, returning what was
    /// reported. The file that went to the Trash is remembered for teardown.
    private func trashAfter(
        _ fixture: Fixture, _ trigger: () throws -> Void
    ) async throws -> (id: NoteID, result: Result<URL, any Error>)? {
        let settled = expectation(description: "deletion settled")
        var reported: (id: NoteID, result: Result<URL, any Error>)?
        fixture.controller.onDeleteNote = { [weak self] id, result in
            reported = (id, result)
            if case .success(let url) = result { self?.trashed.append(url) }
            settled.fulfill()
        }
        try trigger()
        await fulfillment(of: [settled], timeout: 10)
        fixture.controller.onDeleteNote = nil
        return reported
    }

    /// The pasteboard holds a string and nothing richer: no RTF, HTML or file URL.
    private func assertPlainTextOnly(file: StaticString = #filePath, line: UInt = #line) {
        let types = pasteboard?.types ?? []
        XCTAssertTrue(types.contains(.string), "\(types)", file: file, line: line)
        for rich: NSPasteboard.PasteboardType in [.rtf, .rtfd, .html, .fileURL, .URL] {
            XCTAssertFalse(types.contains(rich), "\(types)", file: file, line: line)
        }
    }

    private func fileExists(_ id: NoteID) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(id.relativePath).path)
    }

    // MARK: - R-4

    func testR4_menuItemsInOrder() async throws {
        let fixture = try await makeFixture()
        let menu = try XCTUnwrap(try rowMenu(forRow: 2, in: fixture))
        XCTAssertEqual(
            menu.items.map(\.title),
            [
                MainWindowController.renameRowItemTitle, MainWindowController.showInFinderRowItemTitle,
                MainWindowController.copyLinkRowItemTitle, "", MainWindowController.moveToTrashRowItemTitle,
            ])
        XCTAssertEqual(menu.items.map(\.title), ["Rename", "Show in Finder", "Copy Link", "", "Move to Trash"])
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), [false, false, false, true, false])
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(item.isEnabled, item.title)
            XCTAssertIdentical(item.target, fixture.controller, item.title)
            XCTAssertEqual(item.representedObject as? NoteID, beta, item.title)
        }
        XCTAssertIdentical(fixture.table.menu, menu, "shown through the table's own menu, for its outline")
        XCTAssertEqual(fixture.table.clickedRow, 2)
        fixture.table.didCloseMenu(menu, with: nil)
        XCTAssertNil(fixture.table.menu, "the menu is not kept for the next click")

        // A Ctrl-click is a right-click.
        let controlMenu = try XCTUnwrap(try rowMenu(forRow: 0, control: true, in: fixture))
        XCTAssertEqual(controlMenu.items.map(\.title), menu.items.map(\.title))
        XCTAssertEqual(controlMenu.items.first?.representedObject as? NoteID, archivedGamma)
        fixture.table.didCloseMenu(controlMenu, with: nil)

        // Empty space below the last row has no menu.
        let below = NSPoint(x: 20, y: fixture.table.rect(ofRow: 3).maxY + 20)
        XCTAssertEqual(fixture.table.row(at: below), -1)
        XCTAssertNil(fixture.table.menu(for: try click(at: below, in: fixture)))
        XCTAssertNil(fixture.table.menu(for: try click(at: below, control: true, in: fixture)))
    }

    func testR4_actsOnClickedRowNotSelection() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        let selectedRow = fixture.table.selectedRow
        var revealed: [[URL]] = []
        fixture.controller.revealInFinder = { revealed.append($0) }

        let menu = try XCTUnwrap(try rowMenu(forRow: try row(of: beta, in: fixture), in: fixture))
        XCTAssertEqual(fixture.table.clickedRow, try row(of: beta, in: fixture), "AppKit outlines the clicked row")
        XCTAssertEqual(fixture.table.selectedRow, selectedRow, "the right-click leaves the selection")
        menu.performActionForItem(at: menu.indexOfItem(withTitle: MainWindowController.copyLinkRowItemTitle))
        menu.performActionForItem(at: menu.indexOfItem(withTitle: MainWindowController.showInFinderRowItemTitle))
        fixture.table.didCloseMenu(menu, with: nil)

        XCTAssertEqual(pasteboard?.string(forType: .string), "[[Beta]]", "the clicked note's link, not Alpha's")
        XCTAssertEqual(
            revealed.map { $0.map(\.standardizedFileURL) },
            [[root.appendingPathComponent("daily/Beta.md").standardizedFileURL]])
        XCTAssertEqual(fixture.table.selectedRow, selectedRow)
        XCTAssertEqual(fixture.list.selectedID, alpha)
        XCTAssertEqual(fixture.editor.noteID, alpha)
        XCTAssertIdentical(fixture.window.firstResponder, fixture.table)
    }

    func testR4_renameEditsClickedRow() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        let loads = LoadRecorder(fixture.editor)

        try perform(MainWindowController.renameRowItemTitle, on: beta, in: fixture)
        XCTAssertEqual(fixture.list.editingTitleOfID, beta, "the clicked row's title is edited")
        XCTAssertEqual(fixture.list.selectedID, alpha, "the selection stays on Alpha")
        XCTAssertEqual(fixture.table.selectedRow, try row(of: alpha, in: fixture))
        let betaRow = try XCTUnwrap(
            fixture.table.view(atColumn: 0, row: try row(of: beta, in: fixture), makeIfNecessary: false)
                as? NoteRowView)
        XCTAssertTrue(betaRow.isEditingTitle)
        let fieldEditor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        XCTAssertIdentical(fieldEditor.delegate, betaRow.titleLabel)
        XCTAssertEqual(fieldEditor.string, "Beta")

        // Committing renames through R-2 like any other inline edit.
        fieldEditor.selectAll(nil)
        fieldEditor.insertText("Delta", replacementRange: fieldEditor.selectedRange())
        let settled = expectation(description: "rename settled")
        var reported: (NoteID, NoteID)?
        fixture.controller.onRenameNote = { from, to, _ in
            reported = (from, to)
            settled.fulfill()
        }
        try pressReturn(in: fixture.window)
        await fulfillment(of: [settled], timeout: 10)
        fixture.controller.onRenameNote = nil

        let delta = NoteID(relativePath: "daily/Delta.md")
        XCTAssertEqual(reported?.0, beta)
        XCTAssertEqual(reported?.1, delta)
        XCTAssertFalse(fileExists(beta))
        XCTAssertTrue(fileExists(delta))
        await waitUntil("list shows Delta") { fixture.list.results.contains { $0.id == delta } }
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertEqual(fixture.list.selectedID, alpha, "the selection never moved")
        XCTAssertEqual(fixture.table.selectedRow, try row(of: alpha, in: fixture))
        XCTAssertEqual(fixture.editor.noteID, alpha)
        XCTAssertEqual(loads.ids, [], "the editor was not reloaded")
    }

    func testR4_showInFinderRevealsFile() async throws {
        let fixture = try await makeFixture()
        var revealed: [[URL]] = []
        fixture.controller.revealInFinder = { revealed.append($0) }
        try perform(MainWindowController.showInFinderRowItemTitle, on: archivedGamma, in: fixture)
        XCTAssertEqual(
            revealed.map { $0.map(\.standardizedFileURL) },
            [[root.appendingPathComponent("archive/Gamma.md").standardizedFileURL]])
        XCTAssertNil(fixture.list.selectedID, "revealing selects nothing in the list")
        XCTAssertTrue(fileExists(archivedGamma))
    }

    func testR4_copyLinkTitle() async throws {
        // The default is the general pasteboard; only read here, never written.
        XCTAssertIdentical(makeMainWindowController().pasteboard, NSPasteboard.general)

        let fixture = try await makeFixture()
        pasteboard?.clearContents()
        pasteboard?.setString("old", forType: .string)
        try perform(MainWindowController.copyLinkRowItemTitle, on: alpha, in: fixture)
        XCTAssertEqual(pasteboard?.string(forType: .string), "[[Alpha]]")
        assertPlainTextOnly()

        // A title in a folder that is unique is still copied as the title.
        try perform(MainWindowController.copyLinkRowItemTitle, on: beta, in: fixture)
        XCTAssertEqual(pasteboard?.string(forType: .string), "[[Beta]]")
        XCTAssertEqual(fixture.controller.wikilink(to: beta), "[[Beta]]")
        XCTAssertEqual(fixture.library.snapshot.links.resolve("Beta"), .unique(beta), "the copied link names the note")
    }

    func testR4_copyLinkAmbiguousUsesPath() async throws {
        // A second Beta in another folder: neither is at the root, so the title is ambiguous.
        let fixture = try await makeFixture()
        let otherBeta = NoteID(relativePath: "other/Beta.md")
        var created = false
        fixture.library.create(otherBeta) { result in
            if case .failure(let error) = result { XCTFail("create failed: \(error)") }
            created = true
        }
        await waitUntil("second Beta indexed") {
            created && fixture.library.snapshot.links.resolve("Beta").isAmbiguous
        }
        try perform(MainWindowController.copyLinkRowItemTitle, on: beta, in: fixture)
        XCTAssertEqual(pasteboard?.string(forType: .string), "[[daily/Beta]]")
        assertPlainTextOnly()
        XCTAssertEqual(
            fixture.library.snapshot.links.resolve("daily/Beta"), .unique(beta), "the copied link names the note")
        XCTAssertEqual(fixture.controller.wikilink(to: otherBeta), "[[other/Beta]]")
    }

    func testR4_copyLinkRootNoteSharedTitle() async throws {
        // Gamma.md is at the root and archive/Gamma.md is newer: the bare title is the root's.
        let fixture = try await makeFixture()
        XCTAssertEqual(fixture.library.snapshot.links.resolve("Gamma"), .unique(gamma))
        try perform(MainWindowController.copyLinkRowItemTitle, on: gamma, in: fixture)
        XCTAssertEqual(pasteboard?.string(forType: .string), "[[Gamma]]")
        assertPlainTextOnly()
    }

    func testR4_copyLinkNestedSharedTitleUsesPath() async throws {
        let fixture = try await makeFixture()
        XCTAssertNotEqual(fixture.library.snapshot.links.resolve("Gamma").target, archivedGamma)
        try perform(MainWindowController.copyLinkRowItemTitle, on: archivedGamma, in: fixture)
        XCTAssertEqual(pasteboard?.string(forType: .string), "[[archive/Gamma]]")
        assertPlainTextOnly()
        XCTAssertEqual(
            fixture.library.snapshot.links.resolve("archive/Gamma"), .unique(archivedGamma),
            "the copied link names the note")
    }

    func testR4_moveToTrashUnselectedKeepsSelection() async throws {
        let fixture = try await makeFixture()
        try await select(gamma, in: fixture)
        XCTAssertEqual(fixture.table.selectedRow, 1)
        let loads = LoadRecorder(fixture.editor)

        // Beta is not selected: it goes, and Gamma stays selected and open.
        let first = try await trashAfter(fixture) {
            try perform(MainWindowController.moveToTrashRowItemTitle, on: beta, in: fixture)
        }
        XCTAssertEqual(first?.id, beta)
        let betaInTrash = try XCTUnwrap(try first?.result.get())
        XCTAssertFalse(betaInTrash.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path))
        XCTAssertEqual(try String(contentsOf: betaInTrash, encoding: .utf8), "beta body")
        XCTAssertFalse(fileExists(beta))
        await waitUntil("list drops Beta") { !fixture.list.results.contains { $0.id == beta } }
        XCTAssertEqual(fixture.list.results.map(\.id), [archivedGamma, gamma, alpha])
        XCTAssertEqual(fixture.list.selectedID, gamma)
        XCTAssertEqual(fixture.table.selectedRow, 1)
        XCTAssertEqual(fixture.editor.noteID, gamma)
        XCTAssertEqual(loads.ids, [], "the open note was left alone")

        // Gamma is the selected one: the selection moves to the row that took its place (D-1).
        let second = try await trashAfter(fixture) {
            try perform(MainWindowController.moveToTrashRowItemTitle, on: gamma, in: fixture)
        }
        XCTAssertEqual(second?.id, gamma)
        XCTAssertFalse(fileExists(gamma))
        await waitUntil("selection moves to Alpha") { fixture.list.selectedID == alpha }
        XCTAssertEqual(fixture.list.results.map(\.id), [archivedGamma, alpha])
        XCTAssertEqual(fixture.table.selectedRow, 1)
        await waitUntil("editor shows Alpha") { fixture.editor.noteID == alpha && fixture.editor.body != nil }
    }

    func testR4_noMenuOnTemplateRows() async throws {
        try write("templates/daily.md", "---\npath: daily/{{date:yyyy-MM-dd}}\n---\n", modifiedAt: Self.base)
        let fixture = try await makeFixture()
        await waitUntil("templates listed") { !fixture.library.templateNames.isEmpty }
        XCTAssertNotNil(fixture.controller.contextMenu(forRow: 0), "a note row has a menu")

        fixture.controller.search(for: "@")
        XCTAssertTrue(fixture.list.isShowingTemplates)
        XCTAssertEqual(fixture.list.templateRows?.map(\.name), ["daily"])
        XCTAssertEqual(fixture.table.numberOfRows, 1)
        XCTAssertNil(try rowMenu(forRow: 0, in: fixture), "a template row has no menu")
        XCTAssertNil(try rowMenu(forRow: 0, control: true, in: fixture))
        XCTAssertNil(fixture.controller.contextMenu(forRow: 0))
        XCTAssertNil(fixture.table.menu)

        // Back in note mode the rows have their menu again.
        fixture.controller.search(for: "")
        XCTAssertNotNil(try rowMenu(forRow: 0, in: fixture))
    }
}

/// Records every note the editor loads.
@MainActor
private final class LoadRecorder {
    private(set) var ids: [NoteID?] = []

    init(_ editor: EditorController) {
        editor.onLoad = { [weak self] id in self?.ids.append(id) }
    }
}
