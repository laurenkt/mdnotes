import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for renaming a note inline in the list (R-1, R-2, D-2). Cmd-R, Return
/// and Escape are real `NSEvent`s sent through the window, the new title is typed into the
/// row's real field editor, and the file really moves on disk.
@MainActor
final class RenameSmokeTests: XCTestCase {
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
            .appendingPathComponent("mdnotes-rename-\(UUID().uuidString)", isDirectory: true)
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
        let window: NSWindow
        var editor: EditorController { controller.editorController }
        var list: NoteListController { controller.listController }
        var textView: NSTextView { controller.mainView.textView }
        var table: NSTableView { controller.mainView.tableView }
        var searchField: NSSearchField { controller.mainView.searchField }
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
    /// the root unless told not to, and is stopped at teardown so a rename still in flight when
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

    // MARK: - Keys

    private enum Key {
        case commandR, `return`, escape

        var characters: String {
            switch self {
            case .commandR: "r"
            case .return: "\r"
            case .escape: "\u{1B}"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .commandR: 15
            case .return: 36
            case .escape: 53
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .commandR: .command
            case .return, .escape: []
            }
        }
    }

    /// Presses `key` as a user does: a `keyDown` then a `keyUp`. The running app offers every
    /// `keyDown` to the key window's key equivalents before the window dispatches it to its
    /// first responder; a headless test process has no key window, so that step is taken here
    /// by hand and the rest is the window's own `sendEvent`.
    private func press(_ key: Key, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: key.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                    isARepeat: false, keyCode: key.keyCode))
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
    }

    // MARK: - The title field

    /// The row view showing `id`, if the table has made one.
    private func rowView(for id: NoteID, in fixture: Fixture) -> NoteRowView? {
        guard let row = fixture.list.results.firstIndex(where: { $0.id == id }) else { return nil }
        return fixture.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteRowView
    }

    /// The field editor with focus, if it is editing `id`'s title label.
    private func titleEditor(of id: NoteID, in fixture: Fixture) -> NSTextView? {
        guard let view = rowView(for: id, in: fixture), let editor = fixture.window.firstResponder as? NSTextView,
            editor.isFieldEditor, editor.delegate === view.titleLabel
        else { return nil }
        return editor
    }

    /// Selects `id`, presses Cmd-R, and returns the field editor now editing its title.
    private func beginRenaming(_ id: NoteID, in fixture: Fixture) async throws -> NSTextView {
        try await select(id, in: fixture)
        try press(.commandR, in: fixture.window)
        XCTAssertEqual(fixture.list.editingTitleOfID, id)
        return try XCTUnwrap(titleEditor(of: id, in: fixture), "the title of \(id) is not being edited")
    }

    /// Replaces the field editor's text with `text`, as typing over the selected title does.
    private func type(_ text: String, into editor: NSTextView) {
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// Types `text` at the end of the note editor's text, the way a keystroke does.
    private func typeInNote(_ text: String, in fixture: Fixture) {
        let end = NSRange(location: (fixture.textView.string as NSString).length, length: 0)
        fixture.textView.insertText(text, replacementRange: end)
    }

    /// Runs `trigger` and waits for the rename it begins to settle, returning what was reported.
    /// `observe` runs inside the report, before anything else has had the main thread, to record
    /// the state at that moment. The report handler is removed afterwards.
    private func renameAfter(
        _ fixture: Fixture, observing observe: (@MainActor () -> Void)? = nil, _ trigger: () throws -> Void
    ) async throws -> (from: NoteID, to: NoteID, result: Result<Date, any Error>)? {
        let settled = expectation(description: "rename settled")
        var reported: (from: NoteID, to: NoteID, result: Result<Date, any Error>)?
        fixture.controller.onRenameNote = { from, to, result in
            reported = (from, to, result)
            observe?()
            settled.fulfill()
        }
        try trigger()
        await fulfillment(of: [settled], timeout: 10)
        fixture.controller.onRenameNote = nil
        return reported
    }

    // MARK: - Disk

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

    private func modificationDate(_ id: NoteID) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(id.relativePath).path)[
                .modificationDate] as? Date)
    }

    // MARK: - R-1 Cmd-R or a double-click on the title edits it inline

    func testR1_commandRWithARowSelectedEditsTheTitleInline() async throws {
        let fixture = try await makeFixture()
        try await select(beta, in: fixture)
        XCTAssertNil(fixture.list.editingTitleOfID)
        let row = try XCTUnwrap(rowView(for: beta, in: fixture))
        XCTAssertFalse(row.isEditingTitle)
        XCTAssertFalse(row.titleLabel.isEditable, "a title is a plain label until it is edited")

        try press(.commandR, in: fixture.window)
        XCTAssertEqual(fixture.list.editingTitleOfID, beta)
        XCTAssertTrue(row.isEditingTitle)
        XCTAssertTrue(row.titleLabel.isEditable)
        let editor = try XCTUnwrap(titleEditor(of: beta, in: fixture), "focus is in the title's field editor")
        XCTAssertEqual(editor.string, "Beta", "the field holds the title (L-5), not the path")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 4), "with all of it selected")
        XCTAssertEqual(fixture.table.selectedRow, 1, "the row stays selected")
        XCTAssertEqual(fixture.editor.noteID, beta)

        // Cmd-R again while editing changes nothing.
        try press(.commandR, in: fixture.window)
        XCTAssertEqual(fixture.list.editingTitleOfID, beta)
        XCTAssertIdentical(fixture.window.firstResponder, editor)

        // Escape puts the label back and returns focus to the list (R-1 edits, R-2 commits).
        try press(.escape, in: fixture.window)
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertFalse(row.isEditingTitle)
        XCTAssertFalse(row.titleLabel.isEditable)
        XCTAssertEqual(row.titleLabel.stringValue, "Beta")
        XCTAssertIdentical(fixture.window.firstResponder, fixture.table)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testR1_commandRWorksFromTheEditorAndTheSearchFieldWhileARowIsSelected() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        try press(.commandR, in: fixture.window)
        XCTAssertEqual(fixture.list.editingTitleOfID, alpha, "a row is selected, so Cmd-R renames it")
        XCTAssertNotNil(titleEditor(of: alpha, in: fixture))
        fixture.list.cancelEditingTitle()
        XCTAssertNil(fixture.list.editingTitleOfID)

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.searchField))
        try press(.commandR, in: fixture.window)
        XCTAssertEqual(fixture.list.editingTitleOfID, alpha)
        XCTAssertNotNil(titleEditor(of: alpha, in: fixture))
        fixture.list.cancelEditingTitle()
    }

    func testR1_commandRWithNoRowSelectedEditsNothing() async throws {
        let fixture = try await makeFixture()
        XCTAssertEqual(fixture.table.selectedRow, -1)
        XCTAssertFalse(fixture.controller.renameSelectedNote(), "nothing selected: the key is not consumed")
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.table))
        try press(.commandR, in: fixture.window)
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertIdentical(fixture.window.firstResponder, fixture.table)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testR1_doubleClickOnATitleEditsItAndOnTheRestOfTheRowDoesNot() async throws {
        let fixture = try await makeFixture()
        XCTAssertIdentical(fixture.table.target, fixture.list, "the table's double action reaches the list")
        XCTAssertNotNil(fixture.table.doubleAction)
        fixture.table.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(rowView(for: beta, in: fixture))
        let onTitle = row.convert(
            NSPoint(x: row.titleLabel.frame.midX, y: row.titleLabel.frame.midY), to: fixture.table)
        let onSnippet = row.convert(
            NSPoint(x: row.snippetLabel.frame.midX, y: row.snippetLabel.frame.midY), to: fixture.table)

        XCTAssertFalse(fixture.list.beginEditingTitle(at: onSnippet), "the snippet is not the title")
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertEqual(fixture.table.selectedRow, -1)

        XCTAssertTrue(fixture.list.beginEditingTitle(at: onTitle))
        XCTAssertEqual(fixture.list.editingTitleOfID, beta)
        XCTAssertEqual(fixture.table.selectedRow, 1, "the double-clicked row is selected")
        XCTAssertEqual(fixture.editor.noteID, beta, "and shown in the editor (S-8)")
        let editor = try XCTUnwrap(titleEditor(of: beta, in: fixture))
        XCTAssertEqual(editor.string, "Beta")
        fixture.list.cancelEditingTitle()
        XCTAssertFalse(fixture.list.beginEditingTitle(at: NSPoint(x: 10, y: 10_000)), "below the last row")
    }

    // MARK: - R-2 committing renames the file within its folder; D-2 the list follows at once

    func testR2_returnRenamesTheFileWithinItsFolderAndTheEditorAndSelectionFollow() async throws {
        let fixture = try await makeFixture()
        let editor = try await beginRenaming(beta, in: fixture)
        let stamp = try modificationDate(beta)
        let observer = Observer(fixture)
        type("Delta", into: editor)

        let delta = NoteID(relativePath: "daily/Delta.md")
        var listWhenSettled: [NoteID]?
        let reported = try await renameAfter(
            fixture, observing: { listWhenSettled = fixture.list.results.map(\.id) }
        ) { try press(.return, in: fixture.window) }
        XCTAssertEqual(reported?.from, beta)
        XCTAssertEqual(reported?.to, delta)
        XCTAssertEqual(try reported?.result.get(), stamp, "a rename does not touch the modification date")

        // The file moved within its folder, keeping its contents and date.
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md", "daily/Delta.md"])
        XCTAssertEqual(try fileText(delta), "beta body")
        XCTAssertEqual(try modificationDate(delta), stamp)

        // The list showed the new title when the rename settled (D-2), in the same place (S-3).
        XCTAssertEqual(listWhenSettled, [gamma, delta, alpha])
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, delta, alpha])
        XCTAssertNil(fixture.library.snapshot.entry(for: beta))
        XCTAssertEqual(fixture.library.snapshot.entry(for: delta)?.body, "beta body", "indexed under the new id")
        let row = try XCTUnwrap(rowView(for: delta, in: fixture))
        XCTAssertEqual(row.titleLabel.stringValue, "Delta")
        XCTAssertFalse(row.isEditingTitle)

        // The selection and the editor followed the note; nothing was reloaded or cleared.
        XCTAssertEqual(fixture.table.selectedRow, 1)
        XCTAssertEqual(fixture.list.selectedID, delta)
        XCTAssertEqual(fixture.editor.noteID, delta)
        XCTAssertEqual(fixture.textView.string, "beta body")
        XCTAssertEqual(observer.loads, [], "the editor kept its text; the note only changed name")
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertIdentical(fixture.window.firstResponder, fixture.table, "focus returns to the list")
        XCTAssertNil(fixture.controller.inlineMessage)

        // Typing now saves under the new name.
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        typeInNote(" more", in: fixture)
        let saved = expectation(description: "saved")
        fixture.editor.onSave = { id, _ in
            XCTAssertEqual(id, delta)
            saved.fulfill()
        }
        fixture.clock.advance(by: 0.3)
        await fulfillment(of: [saved], timeout: 10)
        XCTAssertEqual(try fileText(delta), "beta body more")
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Gamma.md", "daily/Delta.md"], "nothing recreated Beta.md")

        // The watcher's reports of the rename and the save were recognised as ours (E-6).
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(observer.external, [])
        XCTAssertEqual(fixture.list.results.map(\.id), [delta, gamma, alpha], "the save moved it to the top (S-3)")
    }

    func testR2_unsavedEditsAreWrittenUnderTheOldNameBeforeTheRename() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        typeInNote(" edited", in: fixture)
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.clock.pendingCount, 1)
        try press(.commandR, in: fixture.window)
        let editor = try XCTUnwrap(titleEditor(of: alpha, in: fixture))
        type("Omega", into: editor)

        let omega = NoteID(relativePath: "Omega.md")
        let reported = try await renameAfter(fixture) { try press(.return, in: fixture.window) }
        XCTAssertEqual(reported?.to, omega)
        XCTAssertEqual(try fileText(omega), "alpha body edited", "the renamed file holds what the editor showed")
        XCTAssertEqual(try filesOnDisk(), ["Gamma.md", "Omega.md", "daily/Beta.md"])
        XCTAssertEqual(fixture.clock.pendingCount, 0, "the pending autosave was flushed, not left to fire")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.editor.noteID, omega)
        XCTAssertEqual(fixture.textView.string, "alpha body edited")
        // The save made it the newest note, so it leads the list (S-3), still selected.
        XCTAssertEqual(fixture.list.results.map(\.id), [omega, gamma, beta])
        XCTAssertEqual(fixture.list.selectedID, omega)
        XCTAssertEqual(fixture.table.selectedRow, 0)
    }

    func testR2_aChangeOfCaseAloneIsARenameNotACollision() async throws {
        let fixture = try await makeFixture()
        let editor = try await beginRenaming(alpha, in: fixture)
        let observer = Observer(fixture)
        type("alpha", into: editor)

        let lower = NoteID(relativePath: "alpha.md")
        let reported = try await renameAfter(fixture) { try press(.return, in: fixture.window) }
        XCTAssertEqual(reported?.to, lower)
        XCTAssertNoThrow(try reported?.result.get())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["Gamma.md", "alpha.md", "daily"])
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta, lower])
        XCTAssertEqual(fixture.list.selectedID, lower)
        XCTAssertEqual(fixture.editor.noteID, lower)
        XCTAssertEqual(try XCTUnwrap(rowView(for: lower, in: fixture)).titleLabel.stringValue, "alpha")
        XCTAssertNil(fixture.controller.inlineMessage)

        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(observer.external, [], "the watcher's report of our rename was dropped (E-6)")
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta, lower], "and the old id did not come back")
    }

    func testR2_collisionWithAnotherNoteInTheFolderIsRejectedInlineIgnoringCase() async throws {
        let fixture = try await makeFixture()
        let editor = try await beginRenaming(alpha, in: fixture)
        var reports = 0
        fixture.controller.onRenameNote = { _, _, _ in reports += 1 }
        type("gamma", into: editor)
        try press(.return, in: fixture.window)

        let message = try XCTUnwrap(fixture.controller.inlineMessage, "the collision is reported")
        XCTAssertTrue(message.contains("Gamma"), "the message names the other note: \(message)")
        XCTAssertEqual(fixture.controller.mainView.messageLabel.stringValue, message)
        XCTAssertFalse(fixture.controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(fixture.list.editingTitleOfID, alpha, "the title stays up to be fixed")
        XCTAssertIdentical(fixture.window.firstResponder, editor)
        XCTAssertEqual(editor.string, "gamma")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing moved")
        XCTAssertEqual(reports, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta, alpha])

        // "Beta" collides with nothing at the root: the other Beta is in `daily/` (R-2 renames
        // within the folder). Fixing the title and pressing Return again renames.
        type("Beta", into: editor)
        let rootBeta = NoteID(relativePath: "Beta.md")
        let reported = try await renameAfter(fixture) { try press(.return, in: fixture.window) }
        XCTAssertEqual(reported?.to, rootBeta)
        XCTAssertEqual(try filesOnDisk(), ["Beta.md", "Gamma.md", "daily/Beta.md"])
        XCTAssertNil(fixture.controller.inlineMessage, "the message went with the accepted title")
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta, rootBeta])
    }

    func testR2_illegalTitlesAreRejectedInlineAndNothingMoves() async throws {
        let fixture = try await makeFixture()
        let editor = try await beginRenaming(beta, in: fixture)
        var reports = 0
        fixture.controller.onRenameNote = { _, _, _ in reports += 1 }
        for (title, needle) in [
            ("meeting: notes", ":"), ("daily/nested", "/"), ("", "empty"), ("   ", "empty"),
            (".hidden", "dot"), ("..", ".."),
        ] {
            type(title, into: editor)
            try press(.return, in: fixture.window)
            let message = try XCTUnwrap(fixture.controller.inlineMessage, "\(title) was not rejected")
            XCTAssertTrue(message.contains(needle), "\(title): \(message)")
            XCTAssertEqual(fixture.list.editingTitleOfID, beta, title)
            XCTAssertIdentical(fixture.window.firstResponder, editor, title)
            XCTAssertEqual(try filesOnDisk(), fixtureFiles, "\(title) moved something")
        }
        XCTAssertEqual(reports, 0)

        // Escape gives up: the label shows the unchanged title, the list has focus.
        try press(.escape, in: fixture.window)
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertEqual(try XCTUnwrap(rowView(for: beta, in: fixture)).titleLabel.stringValue, "Beta")
        XCTAssertIdentical(fixture.window.firstResponder, fixture.table)
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, beta, alpha])
        XCTAssertEqual(fixture.editor.noteID, beta)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testR2_anUnchangedTitleEndsTheEditWithoutRenaming() async throws {
        let fixture = try await makeFixture()
        _ = try await beginRenaming(gamma, in: fixture)
        var reports = 0
        fixture.controller.onRenameNote = { _, _, _ in reports += 1 }
        try press(.return, in: fixture.window)
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertIdentical(fixture.window.firstResponder, fixture.table)

        // Whitespace around the title trims away to the same name: accepted, nothing renamed.
        try press(.commandR, in: fixture.window)
        let again = try XCTUnwrap(titleEditor(of: gamma, in: fixture))
        type("  Gamma ", into: again)
        try press(.return, in: fixture.window)
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertNil(fixture.controller.inlineMessage)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, 0)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
        XCTAssertEqual(try XCTUnwrap(rowView(for: gamma, in: fixture)).titleLabel.stringValue, "Gamma")
    }

    func testR2_focusLeavingTheFieldCommitsAValidTitleAndDropsAnInvalidOne() async throws {
        let fixture = try await makeFixture()
        let editor = try await beginRenaming(gamma, in: fixture)
        type("Omega", into: editor)
        let omega = NoteID(relativePath: "Omega.md")
        let reported = try await renameAfter(fixture) {
            XCTAssertTrue(fixture.window.makeFirstResponder(fixture.searchField))
        }
        XCTAssertEqual(reported?.to, omega)
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Omega.md", "daily/Beta.md"])
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertEqual(fixture.list.results.map(\.id), [omega, beta, alpha])
        XCTAssertEqual(fixture.editor.noteID, omega)

        // An invalid title cannot be kept up once focus has gone: it is dropped, with the reason shown.
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.table))
        try press(.commandR, in: fixture.window)
        let again = try XCTUnwrap(titleEditor(of: omega, in: fixture))
        type("a:b", into: again)
        var reports = 0
        fixture.controller.onRenameNote = { _, _, _ in reports += 1 }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertIdentical(fixture.window.firstResponder, fixture.textView)
        XCTAssertNotNil(fixture.controller.inlineMessage)
        XCTAssertEqual(try XCTUnwrap(rowView(for: omega, in: fixture)).titleLabel.stringValue, "Omega")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reports, 0)
        XCTAssertEqual(try filesOnDisk(), ["Alpha.md", "Omega.md", "daily/Beta.md"])
    }

    func testR2_aRenameFailingOnDiskLeavesTheNoteAsItWasAndShowsWhy() async throws {
        let fixture = try await makeFixture()
        let editor = try await beginRenaming(alpha, in: fixture)
        // A file the snapshot cannot know about takes the name between the check and the rename.
        try "squatter".write(to: root.appendingPathComponent("Omega.md"), atomically: true, encoding: .utf8)
        type("Omega", into: editor)
        let reported = try await renameAfter(fixture) { try press(.return, in: fixture.window) }
        XCTAssertEqual(reported?.to, NoteID(relativePath: "Omega.md"))
        XCTAssertThrowsError(try reported?.result.get()) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try fileText(NoteID(relativePath: "Omega.md")), "squatter", "nothing was written over")
        XCTAssertEqual(try fileText(alpha), "alpha body")
        XCTAssertNotNil(fixture.controller.inlineMessage)
        XCTAssertEqual(fixture.editor.noteID, alpha)
        XCTAssertEqual(fixture.list.selectedID, alpha)
    }

    // MARK: - D-2 the list reflects the rename at once, not only after the watcher fires

    func testD2_theListShowsTheNewTitleWithoutAWatcher() async throws {
        let fixture = try await makeFixture(watching: false)
        let editor = try await beginRenaming(beta, in: fixture)
        type("Delta", into: editor)
        let delta = NoteID(relativePath: "daily/Delta.md")
        var listWhenSettled: [NoteID]?
        var titleWhenSettled: String?
        let reported = try await renameAfter(
            fixture,
            observing: {
                listWhenSettled = fixture.list.results.map(\.id)
                // The reload has happened; the rows are made when the table next lays out.
                fixture.table.layoutSubtreeIfNeeded()
                titleWhenSettled = self.rowView(for: delta, in: fixture)?.titleLabel.stringValue
            }
        ) { try press(.return, in: fixture.window) }
        XCTAssertEqual(reported?.to, delta)
        XCTAssertFalse(fixture.library.isWatching, "no watcher can have reported the rename")
        XCTAssertEqual(listWhenSettled, [gamma, delta, alpha], "the list had the new id when the rename settled")
        XCTAssertEqual(titleWhenSettled, "Delta")
        XCTAssertEqual(fixture.list.selectedID, delta)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.list.results.map(\.id), [gamma, delta, alpha], "and stays that way")
    }

    func testD2_aSnapshotArrivingMidEditWaitsForTheEditToEnd() async throws {
        let fixture = try await makeFixture(watching: false)
        let editor = try await beginRenaming(alpha, in: fixture)
        type("Alp", into: editor)
        let omega = NoteID(relativePath: "Omega.md")
        try "omega body".write(to: root.appendingPathComponent(omega.relativePath), atomically: true, encoding: .utf8)
        fixture.library.apply(LibraryChanges(added: [omega]))
        await waitUntil("snapshot lists omega") { fixture.library.snapshot.entry(for: omega) != nil }

        XCTAssertEqual(
            fixture.list.results.map(\.id), [gamma, beta, alpha], "the list is held while a title is edited")
        XCTAssertEqual(fixture.list.editingTitleOfID, alpha)
        XCTAssertIdentical(fixture.window.firstResponder, editor)
        XCTAssertEqual(editor.string, "Alp")

        try press(.escape, in: fixture.window)
        XCTAssertNil(fixture.list.editingTitleOfID)
        XCTAssertEqual(fixture.list.results.map(\.id), [omega, gamma, beta, alpha], "the held snapshot is shown")
        XCTAssertEqual(fixture.list.selectedID, alpha)
        XCTAssertEqual(fixture.table.selectedRow, 3)
    }
}
