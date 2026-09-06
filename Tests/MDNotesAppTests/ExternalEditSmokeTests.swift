import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for external changes to the open note (X-2, X-3, X-4). The changes are
/// made on disk behind the app's back and reach it through the real watcher; edits go through
/// the real text view, and the autosave delay runs on a clock the test advances by hand.
@MainActor
final class ExternalEditSmokeTests: XCTestCase {
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
            .appendingPathComponent("mdnotes-external-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let library: LibraryController
        let clock: ManualAutosaveClock
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

    /// A laid-out window with a ready, watched library attached, on a manual clock.
    private func makeFixture() async throws -> Fixture {
        let clock = ManualAutosaveClock()
        let controller = makeMainWindowController(autosaveClock: clock)
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma, beta, alpha])
        XCTAssertTrue(library.isWatching)
        return Fixture(controller: controller, library: library, clock: clock)
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

    /// Selects the row showing `id` and waits for the editor to show its body.
    private func select(_ id: NoteID, in fixture: Fixture) async throws {
        let row = try XCTUnwrap(fixture.list.results.firstIndex { $0.id == id })
        fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntil("editor shows \(id.relativePath)") {
            fixture.editor.noteID == id && fixture.editor.body != nil
        }
    }

    /// Types `text` at the end of the editor's text, the way a keystroke does.
    private func type(_ text: String, in fixture: Fixture) {
        let end = NSRange(location: (fixture.textView.string as NSString).length, length: 0)
        fixture.textView.insertText(text, replacementRange: end)
    }

    /// Runs `trigger` and waits for the editor's next `onSave`, returning what it reported.
    private func saveAfter(
        _ fixture: Fixture, _ trigger: () throws -> Void
    ) async throws -> (id: NoteID, result: Result<Date, any Error>)? {
        let saved = expectation(description: "note saved")
        var reported: (id: NoteID, result: Result<Date, any Error>)?
        fixture.editor.onSave = { id, result in
            reported = (id, result)
            saved.fulfill()
        }
        try trigger()
        await fulfillment(of: [saved], timeout: 10)
        fixture.editor.onSave = nil
        return reported
    }

    /// Fails if a save is reported while `body` runs and for a short while after.
    private func assertNoSave(_ fixture: Fixture, _ body: () async throws -> Void) async throws {
        var saves: [NoteID] = []
        fixture.editor.onSave = { id, _ in saves.append(id) }
        try await body()
        try await Task.sleep(for: .milliseconds(50))
        fixture.editor.onSave = nil
        XCTAssertEqual(saves, [], "nothing should have been written")
    }

    /// Writes `text` to `id`'s file the way another program would: not through the library.
    private func writeExternally(_ text: String, to id: NoteID) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(id.relativePath))
    }

    private func deleteExternally(_ id: NoteID) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(id.relativePath))
    }

    private func fileExists(_ id: NoteID) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(id.relativePath).path)
    }

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
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

    // MARK: - X-2 a clean editor reloads the changed note, preserving selection

    func testX2_externalChangeReloadsACleanEditorPreservingSelection() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        // Edit and let the autosave land, so the editor is clean but has an undo stack.
        type(" edited", in: fixture)
        _ = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.textView.undoManager?.canUndo, true)
        let observer = Observer(fixture)
        fixture.textView.setSelectedRange(NSRange(location: 6, length: 4))  // "body"

        try writeExternally("alpha body rewritten elsewhere", to: alpha)
        await waitUntil("editor shows the new content") { fixture.textView.string == "alpha body rewritten elsewhere" }

        XCTAssertEqual(fixture.editor.noteID, alpha)
        XCTAssertEqual(fixture.editor.body, .text("alpha body rewritten elsewhere"))
        XCTAssertFalse(fixture.editor.hasUnsavedEdits, "a reload is not an edit")
        XCTAssertEqual(fixture.clock.pendingCount, 0)
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 6, length: 4), "the selection is preserved")
        XCTAssertTrue(fixture.textView.isEditable)
        XCTAssertEqual(observer.loads, [alpha], "the editor reloaded the note it shows")
        XCTAssertTrue(observer.external.allSatisfy { $0 == LibraryChanges(modified: [alpha]) }, "\(observer.external)")
        XCTAssertEqual(
            fixture.textView.undoManager?.canUndo, false,
            "the old stack was recorded against text the view no longer holds (E-7)")

        // The list follows the change too: the note is now the most recently modified (S-3)
        // and stays selected where it moved.
        XCTAssertEqual(fixture.list.results.map(\.id), [alpha, gamma, beta])
        XCTAssertEqual(fixture.list.selectedID, alpha)
        XCTAssertEqual(fixture.table.selectedRow, 0)
        XCTAssertEqual(fixture.library.snapshot.entry(for: alpha)?.preview, "alpha body rewritten elsewhere")

        // Nothing was written back: the disk version is the truth.
        try await assertNoSave(fixture) { try await Task.sleep(for: watcherSettle) }
        XCTAssertEqual(try fileText(alpha), "alpha body rewritten elsewhere")
    }

    func testX2_selectionIsClampedWhenTheNewTextIsShorter() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        fixture.textView.setSelectedRange(NSRange(location: 6, length: 4))

        try writeExternally("ab", to: alpha)
        await waitUntil("editor shows the new content") { fixture.textView.string == "ab" }
        XCTAssertEqual(
            fixture.textView.selectedRange(), NSRange(location: 2, length: 0),
            "a selection past the end collapses to the end of the new text")

        fixture.textView.setSelectedRange(NSRange(location: 1, length: 1))
        try writeExternally("abc def", to: alpha)
        await waitUntil("editor shows the second change") { fixture.textView.string == "abc def" }
        XCTAssertEqual(
            fixture.textView.selectedRange(), NSRange(location: 1, length: 1), "a selection that fits is kept")
        XCTAssertEqual(fixture.editor.body, .text("abc def"))
    }

    func testX2_aChangeToAnotherNoteLeavesTheEditorAlone() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        fixture.textView.setSelectedRange(NSRange(location: 3, length: 2))
        let observer = Observer(fixture)

        try writeExternally("gamma body rewritten elsewhere", to: gamma)
        await waitUntil("the change is reported") { !observer.external.isEmpty }
        try await Task.sleep(for: watcherSettle)

        XCTAssertEqual(observer.loads, [], "the editor did not reload")
        XCTAssertEqual(fixture.textView.string, "alpha body")
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 3, length: 2))
        XCTAssertEqual(fixture.list.selectedID, alpha)
        XCTAssertEqual(fixture.library.snapshot.entry(for: gamma)?.preview, "gamma body rewritten elsewhere")
    }

    // MARK: - X-3 a dirty editor's text wins at the next autosave

    func testX3_unsavedEditsOverwriteTheExternalChangeAtTheNextAutosave() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        let observer = Observer(fixture)
        type(" edited", in: fixture)
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.clock.pendingCount, 1)

        try writeExternally("alpha body rewritten elsewhere", to: alpha)
        await waitUntil("the change is reported") { !observer.external.isEmpty }
        try await Task.sleep(for: watcherSettle)

        // The editor is untouched; the library knows the disk version until the autosave.
        XCTAssertEqual(observer.loads, [], "a dirty editor is not reloaded")
        XCTAssertEqual(fixture.textView.string, "alpha body edited")
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.editor.body, .text("alpha body"))
        XCTAssertEqual(fixture.clock.pendingCount, 1, "the autosave is still on its way")
        XCTAssertEqual(try fileText(alpha), "alpha body rewritten elsewhere")
        XCTAssertEqual(fixture.library.snapshot.entry(for: alpha)?.preview, "alpha body rewritten elsewhere")
        XCTAssertEqual(fixture.list.selectedID, alpha)
        let reportsBeforeSave = observer.external.count

        // The next autosave writes the editor's text over the disk version. No conflict copy.
        let saved = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        XCTAssertEqual(saved?.id, alpha)
        XCTAssertNoThrow(try saved?.result.get())
        XCTAssertEqual(try fileText(alpha), "alpha body edited")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "no conflict copy is made")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.editor.body, .text("alpha body edited"))
        await waitUntil("the save is folded into the snapshot") {
            fixture.library.snapshot.entry(for: self.alpha)?.preview == "alpha body edited"
        }
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(observer.external.count, reportsBeforeSave, "our own write is not an external change (E-6)")
        XCTAssertEqual(observer.loads, [])
        XCTAssertEqual(fixture.textView.string, "alpha body edited")
    }

    // MARK: - X-4 the open note is deleted

    func testX4_deletingTheOpenNoteClearsTheEditorAndSelectsTheNextRow() async throws {
        let fixture = try await makeFixture()
        try await select(beta, in: fixture)
        XCTAssertEqual(fixture.table.selectedRow, 1)
        let observer = Observer(fixture)

        try deleteExternally(beta)
        await waitUntil("the next row's note is shown") {
            fixture.editor.noteID == self.alpha && fixture.editor.body != nil
        }
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, alpha])
        XCTAssertEqual(fixture.table.selectedRow, 1, "the selection moved to the row that took the deleted one's place")
        XCTAssertEqual(fixture.list.selectedID, alpha)
        XCTAssertEqual(fixture.textView.string, "alpha body")
        XCTAssertEqual(observer.loads, [nil, alpha], "the editor was cleared, then loaded the next row")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertFalse(fixture.editor.holdsEditsOfDeletedNote)

        // Deleting the last row selects the new last row.
        try deleteExternally(alpha)
        await waitUntil("the previous row's note is shown") {
            fixture.editor.noteID == self.gamma && fixture.editor.body != nil
        }
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma])
        XCTAssertEqual(fixture.table.selectedRow, 0)
        XCTAssertEqual(fixture.textView.string, "gamma body")

        // Deleting the only note leaves nothing selected and the editor empty.
        try deleteExternally(gamma)
        await waitUntil("the list is empty") { fixture.list.results.isEmpty }
        XCTAssertEqual(fixture.table.selectedRow, -1)
        XCTAssertNil(fixture.list.selectedID)
        XCTAssertNil(fixture.editor.noteID)
        XCTAssertEqual(fixture.textView.string, "")
        XCTAssertFalse(fixture.textView.isEditable)
        try await assertNoSave(fixture) { try await Task.sleep(for: watcherSettle) }
        XCTAssertEqual(try filesOnDisk(), [], "nothing was written back")
    }

    func testX4_unsavedEditsAreKeptAndRecreateTheFileOnlyWhenTheUserTypesAgain() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        let observer = Observer(fixture)
        type(" edited", in: fixture)
        XCTAssertEqual(fixture.clock.pendingCount, 1)

        try deleteExternally(alpha)
        await waitUntil("the deleted note leaves the list") {
            fixture.list.results.map(\.id) == [self.gamma, self.beta]
        }

        // The edits stay in the view; nothing is selected; no autosave is pending.
        XCTAssertEqual(fixture.textView.string, "alpha body edited")
        XCTAssertTrue(fixture.textView.isEditable)
        XCTAssertEqual(fixture.editor.noteID, alpha)
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertTrue(fixture.editor.holdsEditsOfDeletedNote)
        XCTAssertEqual(
            fixture.clock.pendingCount, 0, "the pending autosave is cancelled, not left to recreate the file")
        XCTAssertEqual(fixture.table.selectedRow, -1)
        XCTAssertNil(fixture.list.selectedID)
        XCTAssertEqual(observer.loads, [], "the editor was neither cleared nor reloaded")

        // Time passing and focus loss write nothing: the file stays deleted.
        try await assertNoSave(fixture) { fixture.clock.advance(by: 5) }
        try await assertNoSave(fixture) {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.controller.window)
        }
        XCTAssertFalse(fileExists(alpha))
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertTrue(fixture.editor.holdsEditsOfDeletedNote)

        // Typing again recreates the file at the next autosave, with the whole text.
        type("!", in: fixture)
        fixture.textView.setSelectedRange(NSRange(location: 18, length: 0))
        XCTAssertFalse(fixture.editor.holdsEditsOfDeletedNote)
        XCTAssertEqual(fixture.clock.pendingCount, 1)
        XCTAssertFalse(fileExists(alpha), "not before the delay")
        let saved = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        XCTAssertEqual(saved?.id, alpha)
        XCTAssertNoThrow(try saved?.result.get())
        XCTAssertEqual(try fileText(alpha), "alpha body edited!")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)

        // The note is listed again and the list catches up with the editor, which is not
        // reloaded for it: the caret stays where the user was typing.
        await waitUntil("the recreated note is listed and selected") { fixture.list.selectedID == self.alpha }
        XCTAssertEqual(fixture.list.results.map(\.id), [alpha, gamma, beta], "recreated, it is the most recent (S-3)")
        XCTAssertEqual(fixture.table.selectedRow, 0)
        XCTAssertEqual(fixture.textView.string, "alpha body edited!")
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 18, length: 0))
        XCTAssertEqual(observer.loads, [])
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(observer.external, [LibraryChanges(removed: [alpha])], "the recreate is our own write (E-6)")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testX4_leavingHeldEditsDropsThemWithoutRecreatingTheFile() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        type(" edited", in: fixture)
        try deleteExternally(alpha)
        await waitUntil("the edits are held") { fixture.editor.holdsEditsOfDeletedNote }

        // Quitting does not write them either: the app is allowed to quit at once.
        let delegate = AppDelegate(mainWindowController: fixture.controller)
        var replies: [Bool] = []
        delegate.replyToTerminate = { _, shouldTerminate in replies.append(shouldTerminate) }
        try await assertNoSave(fixture) {
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        }
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(fileExists(alpha))
        XCTAssertEqual(fixture.textView.string, "alpha body edited", "the text is still in the view")

        // Selecting another note replaces the text; the deleted note is not written.
        try await assertNoSave(fixture) {
            let row = try XCTUnwrap(fixture.list.results.firstIndex { $0.id == gamma })
            fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await waitUntil("editor shows gamma") { fixture.editor.noteID == self.gamma && fixture.editor.body != nil }
        }
        XCTAssertEqual(fixture.textView.string, "gamma body")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertFalse(fixture.editor.holdsEditsOfDeletedNote)
        XCTAssertFalse(fileExists(alpha))
        XCTAssertEqual(try filesOnDisk(), ["Gamma.md", "daily/Beta.md"])
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta])
    }
}
