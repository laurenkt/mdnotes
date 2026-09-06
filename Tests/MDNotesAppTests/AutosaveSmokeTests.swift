import AppKit
import Darwin
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for autosave (E-4), its atomic write (E-5) and the record it leaves
/// for the watcher (E-6). Edits go through the real text view, so they take the same
/// text-storage path a keystroke does, and the autosave delay runs on a clock the test
/// advances by hand.
@MainActor
final class AutosaveSmokeTests: XCTestCase {
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
            .appendingPathComponent("mdnotes-autosave-\(UUID().uuidString)", isDirectory: true)
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
        chmod(root.path, 0o755)
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
        var textView: NSTextView { controller.mainView.textView }
        var table: NSTableView { controller.mainView.tableView }
    }

    /// A laid-out window with a ready library attached, on a manual clock.
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
        let row = try XCTUnwrap(fixture.controller.listController.results.firstIndex { $0.id == id })
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
        _ fixture: Fixture, timeout: TimeInterval = 10, _ trigger: () throws -> Void
    ) async throws -> (id: NoteID, result: Result<Date, any Error>)? {
        let saved = expectation(description: "note saved")
        var reported: (id: NoteID, result: Result<Date, any Error>)?
        fixture.editor.onSave = { id, result in
            reported = (id, result)
            saved.fulfill()
        }
        try trigger()
        await fulfillment(of: [saved], timeout: timeout)
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

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    private func modificationDate(_ id: NoteID) throws -> Date {
        try NoteStore(root: root).modificationDate(of: id)
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

    // MARK: - E-4 300 ms after the last edit

    func testE4_writesTheFile300msAfterTheLastEdit() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.clock.pendingCount, 0, "loading a note schedules nothing")

        type(" edited", in: fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body edited")
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.clock.pendingCount, 1)
        XCTAssertEqual(try fileText(alpha), "alpha body", "nothing is written on the keystroke itself")

        try await assertNoSave(fixture) { fixture.clock.advance(by: 0.299) }
        XCTAssertEqual(try fileText(alpha), "alpha body")
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)

        let saved = try await saveAfter(fixture) { fixture.clock.advance(by: 0.001) }
        XCTAssertEqual(saved?.id, alpha)
        XCTAssertNoThrow(try saved?.result.get())
        XCTAssertEqual(try fileText(alpha), "alpha body edited")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.clock.pendingCount, 0)
        XCTAssertEqual(fixture.editor.body, .text("alpha body edited"), "the editor now knows what is on disk")
        XCTAssertEqual(EditorController.autosaveDelay, 0.3)
    }

    func testE4_everyEditRestartsTheDelay() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)

        try await assertNoSave(fixture) {
            type(" one", in: fixture)
            fixture.clock.advance(by: 0.2)
            type(" two", in: fixture)
            fixture.clock.advance(by: 0.2)
        }
        XCTAssertEqual(try fileText(alpha), "alpha body", "400 ms after the first edit, but only 200 ms after the last")
        XCTAssertEqual(fixture.clock.pendingCount, 1, "one timer, restarted, not one per keystroke")

        let saved = try await saveAfter(fixture) { fixture.clock.advance(by: 0.1) }
        XCTAssertEqual(saved?.id, alpha)
        XCTAssertEqual(try fileText(alpha), "alpha body one two", "both edits land in one write")
    }

    func testE4_loadingANoteIsNotAnEdit() async throws {
        let fixture = try await makeFixture()
        let before = try modificationDate(alpha)
        try await select(alpha, in: fixture)
        try await assertNoSave(fixture) { fixture.clock.advance(by: 5) }
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(try modificationDate(alpha), before)
        try await select(beta, in: fixture)
        try await assertNoSave(fixture) { fixture.clock.advance(by: 5) }
        XCTAssertEqual(try modificationDate(alpha), before, "switching a clean note writes nothing")
    }

    // MARK: - E-4 immediately on note switch, focus loss and quit

    func testE4_switchingNoteWritesImmediately() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        type(" edited", in: fixture)
        XCTAssertEqual(fixture.clock.pendingCount, 1)

        // The clock does not move: selecting another row is what triggers the write.
        let saved = try await saveAfter(fixture) {
            let row = try XCTUnwrap(fixture.controller.listController.results.firstIndex { $0.id == gamma })
            fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        XCTAssertEqual(saved?.id, alpha)
        XCTAssertEqual(try fileText(alpha), "alpha body edited")
        XCTAssertEqual(fixture.clock.pendingCount, 0, "the pending timer is cancelled, not left to write again")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)

        await waitUntil("editor shows gamma") { fixture.editor.noteID == self.gamma && fixture.editor.body != nil }
        XCTAssertEqual(fixture.textView.string, "gamma body")
        try await assertNoSave(fixture) { fixture.clock.advance(by: 5) }

        // Straight back: the reread is queued behind the write, so it shows the saved text.
        try await select(alpha, in: fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body edited")
    }

    func testE4_deselectingWritesImmediately() async throws {
        let fixture = try await makeFixture()
        try await select(beta, in: fixture)
        type("!", in: fixture)
        let saved = try await saveAfter(fixture) { fixture.table.deselectAll(nil) }
        XCTAssertEqual(saved?.id, beta)
        XCTAssertEqual(try fileText(beta), "beta body!")
        XCTAssertNil(fixture.editor.noteID)
        XCTAssertEqual(fixture.textView.string, "")
        XCTAssertEqual(fixture.clock.pendingCount, 0)
    }

    func testE4_losingWindowFocusWritesImmediately() async throws {
        let fixture = try await makeFixture()
        let window = try XCTUnwrap(fixture.controller.window)
        try await select(alpha, in: fixture)
        type(" edited", in: fixture)

        let saved = try await saveAfter(fixture) {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        XCTAssertEqual(saved?.id, alpha)
        XCTAssertEqual(try fileText(alpha), "alpha body edited")
        XCTAssertEqual(fixture.clock.pendingCount, 0)
        XCTAssertEqual(fixture.editor.noteID, alpha, "focus loss does not change what the editor shows")
        XCTAssertEqual(fixture.textView.string, "alpha body edited")

        // Another window resigning key is not this window losing focus.
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        other.isReleasedWhenClosed = false
        type("!", in: fixture)
        try await assertNoSave(fixture) {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        }
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
    }

    func testE4_quitWaitsForTheWriteToLand() async throws {
        let fixture = try await makeFixture()
        let delegate = AppDelegate(mainWindowController: fixture.controller)
        XCTAssertIdentical(delegate.mainWindowController, fixture.controller)
        var replies: [Bool] = []
        delegate.replyToTerminate = { _, shouldTerminate in replies.append(shouldTerminate) }

        try await select(alpha, in: fixture)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow, "nothing to write: quit at once")
        XCTAssertEqual(replies, [])

        type(" edited", in: fixture)
        let replied = expectation(description: "termination resumed")
        delegate.replyToTerminate = { _, shouldTerminate in
            replies.append(shouldTerminate)
            replied.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        await fulfillment(of: [replied], timeout: 10)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(
            try fileText(alpha), "alpha body edited", "the file is complete before the app is allowed to quit")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.clock.pendingCount, 0)
    }

    func testE4_thereIsNoSaveMenuItem() throws {
        func items(in menu: NSMenu?) -> [NSMenuItem] {
            guard let menu else { return [] }
            return menu.items.flatMap { [$0] + items(in: $0.submenu) }
        }
        let saves = items(in: NSApp.mainMenu).filter {
            $0.action == #selector(NSDocument.save(_:)) || $0.title.lowercased().hasPrefix("save")
        }
        XCTAssertEqual(saves.map(\.title), [])
    }

    func testE4_aFailedWriteKeepsTheEditsForTheNextAttempt() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores directory permissions")
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        type(" edited", in: fixture)

        // The directory refuses the temp file, so the atomic write cannot even start.
        XCTAssertEqual(chmod(root.path, 0o555), 0)
        let failed = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        XCTAssertEqual(failed?.id, alpha)
        XCTAssertThrowsError(try failed?.result.get())
        XCTAssertEqual(try fileText(alpha), "alpha body", "the old file is intact (E-5)")
        XCTAssertTrue(fixture.editor.hasUnsavedEdits, "the edits are still pending")
        XCTAssertEqual(fixture.textView.string, "alpha body edited", "and still in the view")
        XCTAssertEqual(fixture.clock.pendingCount, 0, "no retry loop: the next edit or flush tries again")

        XCTAssertEqual(chmod(root.path, 0o755), 0)
        type("!", in: fixture)
        let saved = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        XCTAssertNoThrow(try saved?.result.get())
        XCTAssertEqual(try fileText(alpha), "alpha body edited!")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
    }

    // MARK: - E-5 atomic write, modification date, and the list

    func testE5_autosaveReplacesTheFileWholeAndTheListShowsTheNewDate() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        var loads = 0
        fixture.editor.onLoad = { _ in loads += 1 }
        let before = try modificationDate(alpha)

        type(" edited", in: fixture)
        let saved = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        let modifiedAt = try XCTUnwrap(saved?.result.get())
        XCTAssertEqual(try fileText(alpha), "alpha body edited")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "no temp file is left beside the note")
        XCTAssertEqual(modifiedAt, try modificationDate(alpha), "the reported date is the file's")
        XCTAssertGreaterThan(modifiedAt, before, "the modification date reflects the write")
        XCTAssertLessThanOrEqual(abs(modifiedAt.timeIntervalSinceNow), 5)

        // The snapshot is updated from the write itself, without rereading the file, and the
        // list follows: the note is now the most recently modified (S-3) with a new snippet.
        await waitUntil("list shows alpha first") {
            fixture.controller.listController.results.first?.id == self.alpha
        }
        let entry = try XCTUnwrap(fixture.library.snapshot.entry(for: alpha))
        XCTAssertEqual(entry.modifiedAt, modifiedAt)
        XCTAssertEqual(entry.preview, "alpha body edited")
        XCTAssertEqual(fixture.controller.listController.results.map(\.id), [alpha, gamma, beta])
        XCTAssertEqual(fixture.controller.listController.selectedID, alpha, "the selection follows the note")
        XCTAssertEqual(fixture.table.selectedRow, 0)
        XCTAssertEqual(loads, 0, "the editor is not reloaded by its own write")
        XCTAssertEqual(fixture.textView.string, "alpha body edited")
    }

    func testE5_writesTheTextByteForByte() async throws {
        let fixture = try await makeFixture()
        try await select(gamma, in: fixture)
        // A BOM, CRLF and non-ASCII are text (L-8); nothing is normalised on the way out.
        let extra = "\r\n\u{FEFF}františek [[link]] #tag\t"
        type(extra, in: fixture)
        _ = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        let bytes = try Data(contentsOf: root.appendingPathComponent(gamma.relativePath))
        XCTAssertEqual(Array(bytes), Array(("gamma body" + extra).utf8))
    }

    // MARK: - E-6 own writes are recorded for the watcher

    func testE6_autosaveRecordsItsWriteSoTheWatcherCanIgnoreIt() async throws {
        let fixture = try await makeFixture()
        let writes = fixture.library.ownWrites
        XCTAssertEqual(writes.count, 0)
        try await select(alpha, in: fixture)
        type(" edited", in: fixture)
        let saved = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        let modifiedAt = try XCTUnwrap(saved?.result.get())

        XCTAssertTrue(
            writes.contains(alpha, modifiedAt: try modificationDate(alpha)),
            "the record carries the date the watcher will read off the file")
        XCTAssertEqual(writes.lastWrite(of: alpha), modifiedAt)
        XCTAssertNil(writes.lastWrite(of: gamma), "notes we did not write are not recorded")
        XCTAssertFalse(writes.contains(alpha, modifiedAt: Self.base), "an older date on the file is an external change")

        // A second write replaces the record; the first date is no longer ours.
        try await Task.sleep(for: .milliseconds(20))
        type("!", in: fixture)
        let again = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        let later = try XCTUnwrap(again?.result.get())
        XCTAssertEqual(writes.lastWrite(of: alpha), later)
        XCTAssertEqual(writes.count, 1)
    }

    // MARK: - E-6 the watcher drops the echo of our writes

    /// Counts the snapshots the library publishes, and collects the external changes it reports,
    /// while still forwarding each snapshot to the window.
    @MainActor
    private final class Reloads {
        private(set) var publishes = 0
        private(set) var external: [LibraryChanges] = []

        init(_ library: LibraryController) {
            let forward = library.onSnapshotChange
            library.onSnapshotChange = { [weak self] snapshot in
                self?.publishes += 1
                forward?(snapshot)
            }
            library.onExternalChanges = { [weak self] changes in self?.external.append(changes) }
        }
    }

    /// Long enough for the watcher (0.1 s latency) to have delivered anything it was going to.
    private let watcherSettle: Duration = .seconds(1)

    func testE6_autosaveDoesNotTriggerAReload() async throws {
        let fixture = try await makeFixture()
        XCTAssertTrue(fixture.library.isWatching, "the library watches its root once scanned (X-1)")
        try await select(alpha, in: fixture)
        let reloads = Reloads(fixture.library)

        type(" edited", in: fixture)
        _ = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        await waitUntil("the save's own fold is published") { reloads.publishes >= 1 }
        try await Task.sleep(for: watcherSettle)

        XCTAssertEqual(reloads.publishes, 1, "the save folds its text once; the watcher's echo adds nothing")
        XCTAssertEqual(reloads.external, [], "our own write is not an external change")
        XCTAssertEqual(fixture.library.snapshot.query("edited").map(\.id), [alpha])
        XCTAssertEqual(fixture.editor.body, .text("alpha body edited"))
        XCTAssertEqual(fixture.textView.string, "alpha body edited")

        // The watcher is alive: a write by someone else, with its own date, does reload.
        try Data("alpha body rewritten elsewhere".utf8).write(to: root.appendingPathComponent(alpha.relativePath))
        await waitUntil("external change reported", timeout: 10) { !reloads.external.isEmpty }
        XCTAssertEqual(reloads.external, [LibraryChanges(modified: [alpha])])
        XCTAssertEqual(reloads.publishes, 2, "the snapshot is published before the change is reported")
        XCTAssertEqual(fixture.library.snapshot.query("elsewhere").map(\.id), [alpha])
        XCTAssertEqual(fixture.library.snapshot.entry(for: alpha)?.modifiedAt, try modificationDate(alpha))
    }

    func testE6_twoAutosavesInARowTriggerNoReload() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        let reloads = Reloads(fixture.library)

        type(" one", in: fixture)
        _ = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        type(" two", in: fixture)
        _ = try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        await waitUntil("both folds published") { reloads.publishes >= 2 }
        try await Task.sleep(for: watcherSettle)

        XCTAssertEqual(reloads.publishes, 2)
        XCTAssertEqual(reloads.external, [])
        XCTAssertEqual(try fileText(alpha), "alpha body one two")
    }

    func testE6_creatingANoteDoesNotTriggerAReload() async throws {
        let fixture = try await makeFixture()
        let reloads = Reloads(fixture.library)
        let fresh = NoteID(relativePath: "Fresh.md")
        let created = expectation(description: "created")
        fixture.library.create(fresh) { _ in created.fulfill() }
        await fulfillment(of: [created], timeout: 10)
        XCTAssertEqual(reloads.publishes, 1, "create publishes the note once, before its completion")
        try await Task.sleep(for: watcherSettle)

        XCTAssertEqual(reloads.publishes, 1, "the watcher's echo of the create adds nothing")
        XCTAssertEqual(reloads.external, [])
        XCTAssertEqual(fixture.library.snapshot.count, 4)
    }

    func testE6_creatingANoteRecordsItsWrite() async throws {
        let fixture = try await makeFixture()
        let fresh = NoteID(relativePath: "Fresh.md")
        let created = expectation(description: "created")
        var outcome: Result<NoteStore.Creation, any Error>?
        fixture.library.create(fresh) { result in
            outcome = result
            created.fulfill()
        }
        await fulfillment(of: [created], timeout: 10)
        XCTAssertNoThrow(try XCTUnwrap(outcome).get())
        XCTAssertTrue(fixture.library.ownWrites.contains(fresh, modifiedAt: try modificationDate(fresh)))

        // Creating over an existing note writes nothing (C-1) and records nothing.
        let existing = expectation(description: "existing")
        fixture.library.create(alpha) { _ in existing.fulfill() }
        await fulfillment(of: [existing], timeout: 10)
        XCTAssertNil(fixture.library.ownWrites.lastWrite(of: alpha))
    }
}
