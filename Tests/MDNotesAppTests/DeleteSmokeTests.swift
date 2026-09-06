import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for deleting the selected note (D-1, D-2). Cmd-Delete is a real
/// `NSEvent` sent through the window, the file really goes to the Trash through
/// `NSWorkspace.recycle`, and the list is checked before the watcher can have reported it.
@MainActor
final class DeleteSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    /// Files this test put in the Trash, removed again at teardown.
    private var trashed: [URL] = []

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
            .appendingPathComponent("mdnotes-delete-\(UUID().uuidString)", isDirectory: true)
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
        for url in trashed { try? FileManager.default.removeItem(at: url) }
        trashed = []
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
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
        var list: NoteListController { controller.listController }
        var textView: NSTextView { controller.mainView.textView }
        var table: NSTableView { controller.mainView.tableView }
    }

    /// Collects what the editor loads and what the library reports as external changes.
    @MainActor
    private final class Observer {
        private(set) var loads: [NoteID?] = []
        private(set) var external: [LibraryChanges] = []

        init(_ fixture: Fixture) {
            fixture.editor.onLoad = { [weak self] id in self?.loads.append(id) }
            let forward = fixture.library.onExternalChanges
            fixture.library.onExternalChanges = { [weak self] changes in
                self?.external.append(changes)
                forward?(changes)
            }
        }
    }

    /// Long enough for the watcher (0.1 s latency) to have delivered anything it was going to.
    private let watcherSettle: Duration = .seconds(1)

    /// Main-actor box so a library can ride inside a `@Sendable` teardown block.
    @MainActor
    private final class LibraryBox {
        let library: LibraryController
        init(_ library: LibraryController) { self.library = library }
    }

    /// A laid-out window with a ready library attached, on a manual clock. The library watches
    /// the root unless told not to, and is stopped at teardown so a move still in flight when
    /// the test ends is dropped rather than reported to a window that is gone.
    private func makeFixture(watching: Bool = true) async throws -> Fixture {
        let clock = ManualAutosaveClock()
        let controller = makeMainWindowController(autosaveClock: clock)
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root, watchesFileSystem: watching)
        let box = LibraryBox(library)
        addTeardownBlock { await MainActor.run { box.library.stop() } }
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma, beta, alpha])
        XCTAssertEqual(library.isWatching, watching)
        let window = try XCTUnwrap(controller.window)
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

    /// Selects the row showing `id`, focuses the list, and waits for the editor to show the body.
    private func select(_ id: NoteID, in fixture: Fixture) async throws {
        let row = try XCTUnwrap(fixture.list.results.firstIndex { $0.id == id })
        fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.table))
        await waitUntil("editor shows \(id.relativePath)") {
            fixture.editor.noteID == id && fixture.editor.body != nil
        }
    }

    /// Types `text` at the end of the editor's text, the way a keystroke does.
    private func type(_ text: String, in fixture: Fixture) {
        let end = NSRange(location: (fixture.textView.string as NSString).length, length: 0)
        fixture.textView.insertText(text, replacementRange: end)
    }

    /// Presses Cmd-Delete as a user does: a `keyDown` then a `keyUp`. The running app offers
    /// every `keyDown` to the key window's key equivalents before the window dispatches it to
    /// its first responder; a headless test process has no key window, so that step is taken
    /// here by hand and the rest is the window's own `sendEvent`.
    private func pressCommandDelete(in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false,
                    keyCode: 51))
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
    }

    /// Runs `trigger` and waits for the deletion it begins to settle, returning what was
    /// reported. `observe` runs inside the report, before anything else has had the main thread,
    /// to record the state at that moment. The file that went to the Trash is remembered for
    /// teardown. The report handler is removed afterwards, so nothing it captured outlives the
    /// call.
    private func deleteAfter(
        _ fixture: Fixture, observing observe: (@MainActor () -> Void)? = nil, _ trigger: () throws -> Void
    ) async throws -> (id: NoteID, result: Result<URL, any Error>)? {
        let settled = expectation(description: "deletion settled")
        var reported: (id: NoteID, result: Result<URL, any Error>)?
        fixture.controller.onDeleteNote = { [weak self] id, result in
            reported = (id, result)
            if case .success(let url) = result { self?.trashed.append(url) }
            observe?()
            settled.fulfill()
        }
        try trigger()
        await fulfillment(of: [settled], timeout: 10)
        fixture.controller.onDeleteNote = nil
        return reported
    }

    private func fileExists(_ id: NoteID) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(id.relativePath).path)
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

    /// Asserts that `url` is where `recycle` put a file: in a Trash folder outside the library,
    /// still holding `body`.
    private func assertInTrash(_ url: URL?, body: String, _ message: String = "") throws {
        let url = try XCTUnwrap(url, message)
        XCTAssertFalse(
            url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path), "\(url) is inside the library")
        XCTAssertTrue(
            url.deletingLastPathComponent().lastPathComponent.hasPrefix(".Trash"), "\(url) is not in a Trash folder")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), body, message)
    }

    // MARK: - D-1 Cmd-Delete with a row selected trashes it; no confirmation; next row selected

    func testD1_commandDeleteMovesTheSelectedNoteToTheTrashAndSelectsTheNextRow() async throws {
        let fixture = try await makeFixture()
        try await select(beta, in: fixture)
        XCTAssertEqual(fixture.table.selectedRow, 1)
        let observer = Observer(fixture)

        let reported = try await deleteAfter(fixture) { try pressCommandDelete(in: fixture.window) }
        XCTAssertEqual(reported?.id, beta)
        try assertInTrash(try reported?.result.get(), body: "beta body")
        XCTAssertFalse(fileExists(beta), "the file is gone from the library")
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md"])
        XCTAssertNil(fixture.window.attachedSheet, "no confirmation was asked (D-1)")
        XCTAssertNil(fixture.controller.inlineMessage)

        // The list no longer shows the note and the selection moved to the row that took its
        // place, whose note went into the editor (X-4 as D-1 wants it).
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, alpha])
        XCTAssertNil(fixture.library.snapshot.entry(for: beta))
        XCTAssertEqual(fixture.table.selectedRow, 1)
        XCTAssertEqual(fixture.list.selectedID, alpha)
        XCTAssertIdentical(fixture.window.firstResponder, fixture.table, "focus stays in the list")
        await waitUntil("the next row's note is shown") {
            fixture.editor.noteID == self.alpha && fixture.editor.body != nil
        }
        XCTAssertEqual(fixture.textView.string, "alpha body")
        XCTAssertEqual(observer.loads, [nil, alpha], "the editor was cleared, then loaded the next row")

        // Deleting the last row selects the new last row; deleting the only note leaves nothing.
        let second = try await deleteAfter(fixture) { try pressCommandDelete(in: fixture.window) }
        XCTAssertEqual(second?.id, alpha)
        try assertInTrash(try second?.result.get(), body: "alpha body")
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma])
        XCTAssertEqual(fixture.table.selectedRow, 0)
        await waitUntil("gamma is shown") { fixture.editor.noteID == self.gamma && fixture.editor.body != nil }
        let third = try await deleteAfter(fixture) { try pressCommandDelete(in: fixture.window) }
        XCTAssertEqual(third?.id, gamma)
        try assertInTrash(try third?.result.get(), body: "gamma body")
        XCTAssertTrue(fixture.list.results.isEmpty)
        XCTAssertEqual(fixture.table.selectedRow, -1)
        XCTAssertNil(fixture.list.selectedID)
        XCTAssertNil(fixture.editor.noteID)
        XCTAssertEqual(fixture.textView.string, "")
        XCTAssertEqual(try filesOnDisk(), [])

        // The watcher's reports of the moves were recognised as ours (E-6): nothing external.
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(observer.external, [])
        XCTAssertEqual(try filesOnDisk(), [], "nothing was written back")
    }

    func testD1_commandDeleteWorksFromTheEditorAndTheSearchFieldWhileARowIsSelected() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setSelectedRange(NSRange(location: 5, length: 0))

        let fromEditor = try await deleteAfter(fixture) { try pressCommandDelete(in: fixture.window) }
        XCTAssertEqual(fromEditor?.id, alpha, "a row is selected, so Cmd-Delete deletes rather than editing text")
        try assertInTrash(try fromEditor?.result.get(), body: "alpha body")
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta])
        XCTAssertEqual(fixture.list.selectedID, beta, "alpha was the last row; the new last row is selected")
        await waitUntil("beta is shown") { fixture.editor.noteID == self.beta && fixture.editor.body != nil }

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.mainView.searchField))
        let fromField = try await deleteAfter(fixture) { try pressCommandDelete(in: fixture.window) }
        XCTAssertEqual(fromField?.id, beta)
        try assertInTrash(try fromField?.result.get(), body: "beta body")
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma])
        XCTAssertEqual(try filesOnDisk(), ["Gamma.md"])
    }

    func testD1_commandDeleteWithNoRowSelectedDeletesNothing() async throws {
        let fixture = try await makeFixture()
        XCTAssertEqual(fixture.table.selectedRow, -1)
        var reports = 0
        fixture.controller.onDeleteNote = { _, _ in reports += 1 }
        XCTAssertFalse(fixture.controller.deleteSelectedNote(), "nothing selected: the key is not consumed")

        // In the search field the key keeps its text meaning: delete to the start of the line.
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.controller.mainView.searchField))
        let editor = try XCTUnwrap(fixture.controller.mainView.searchField.currentEditor() as? NSTextView)
        editor.insertText("zzz", replacementRange: editor.selectedRange())
        XCTAssertTrue(fixture.list.results.isEmpty, "no note matches, so none is selected")
        try pressCommandDelete(in: fixture.window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.controller.mainView.searchField.stringValue, "", "the field editor took the key")
        XCTAssertEqual(reports, 0)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta, alpha])
    }

    func testD1_unsavedEditsAreWrittenBeforeTheNoteGoesToTheTrash() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        type(" edited", in: fixture)
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.clock.pendingCount, 1)
        let observer = Observer(fixture)

        let reported = try await deleteAfter(fixture) { try pressCommandDelete(in: fixture.window) }
        XCTAssertEqual(reported?.id, alpha)
        try assertInTrash(
            try reported?.result.get(), body: "alpha body edited", "the Trash holds what the editor showed")
        XCTAssertFalse(fileExists(alpha))
        XCTAssertEqual(fixture.clock.pendingCount, 0, "the pending autosave went with the note")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertFalse(fixture.editor.holdsEditsOfDeletedNote)
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta])
        // The save made alpha the most recent note (S-3), so it was the first row; the next row
        // is now gamma.
        XCTAssertEqual(fixture.list.selectedID, gamma)
        XCTAssertEqual(fixture.table.selectedRow, 0)
        await waitUntil("gamma is shown") { fixture.editor.noteID == self.gamma && fixture.editor.body != nil }

        // Nothing recreates the file: not time passing, not the watcher.
        fixture.clock.advance(by: 5)
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(try filesOnDisk(), ["Gamma.md", "daily/Beta.md"])
        XCTAssertEqual(observer.external, [], "our own save and delete are not external changes (E-6)")
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta])
    }

    // MARK: - D-2 the list reflects the delete at once, not only after the watcher fires

    func testD2_theListDropsTheNoteWithoutAWatcher() async throws {
        let fixture = try await makeFixture(watching: false)
        try await select(beta, in: fixture)
        var listWhenSettled: [NoteID]?
        var snapshotListedBetaWhenSettled: Bool?

        let reported = try await deleteAfter(
            fixture,
            observing: {
                listWhenSettled = fixture.list.results.map(\.id)
                snapshotListedBetaWhenSettled = fixture.library.snapshot.entry(for: self.beta) != nil
            }
        ) { XCTAssertTrue(fixture.controller.deleteSelectedNote()) }
        XCTAssertEqual(reported?.id, beta)

        XCTAssertFalse(fixture.library.isWatching, "no watcher can have reported the removal")
        XCTAssertEqual(
            listWhenSettled, [gamma, alpha], "the list had already dropped the note when the delete settled")
        XCTAssertEqual(snapshotListedBetaWhenSettled, false)
        XCTAssertFalse(fileExists(beta))
        XCTAssertEqual(fixture.list.selectedID, alpha)
        XCTAssertEqual(fixture.table.selectedRow, 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, alpha], "and stays that way")
    }

    func testD2_theListDropsTheNoteBeforeTheWatcherReportsAnything() async throws {
        let fixture = try await makeFixture()
        try await select(gamma, in: fixture)
        let observer = Observer(fixture)
        var externalWhenSettled: [LibraryChanges]?
        var listWhenSettled: [NoteID]?
        let reported = try await deleteAfter(
            fixture,
            observing: {
                externalWhenSettled = observer.external
                listWhenSettled = fixture.list.results.map(\.id)
            }
        ) { XCTAssertTrue(fixture.controller.deleteSelectedNote()) }
        XCTAssertEqual(reported?.id, gamma)

        XCTAssertEqual(listWhenSettled, [beta, alpha])
        XCTAssertEqual(externalWhenSettled, [], "the list updated on the library's own account, not the watcher's")
        XCTAssertEqual(fixture.table.selectedRow, 0, "the first row's place was taken by the next note")
        XCTAssertEqual(fixture.list.selectedID, beta)
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(observer.external, [], "the watcher's report of our move was dropped (E-6)")
        XCTAssertEqual(fixture.list.results.map(\.id), [beta, alpha])
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "daily/Beta.md"])
    }
}
