import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for undo (E-7). Edits go through the real text view, so they register
/// with the undo manager the way keystrokes do, and undo is invoked as Cmd-Z is: the `undo:`
/// action sent up the responder chain from the text view, which reaches the window and the
/// first responder's undo manager.
@MainActor
final class UndoSmokeTests: XCTestCase {
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
            .appendingPathComponent("mdnotes-undo-\(UUID().uuidString)", isDirectory: true)
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
        var textView: NSTextView { controller.mainView.textView }
        var table: NSTableView { controller.mainView.tableView }
        var undoManager: UndoManager? { textView.undoManager }
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

    /// Selects the row showing `id`, waits for the editor to show its body, and focuses the
    /// editor as Tab does (S-8), so Cmd-Z would go to it.
    private func select(_ id: NoteID, in fixture: Fixture) async throws {
        let row = try XCTUnwrap(fixture.controller.listController.results.firstIndex { $0.id == id })
        fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntil("editor shows \(id.relativePath)") {
            fixture.editor.noteID == id && fixture.editor.body != nil
        }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
    }

    /// Types `text` at the end of the editor's text, the way keystrokes do, as one typing run:
    /// the text view coalesces consecutive typing into a single undo until something else
    /// (a click, an arrow key, a pause the view notices) breaks the run, so each call ends
    /// its run and lets the run loop turn to close the undo group as the end of a key event
    /// would.
    private func type(_ text: String, in fixture: Fixture) async {
        let end = NSRange(location: (fixture.textView.string as NSString).length, length: 0)
        fixture.textView.insertText(text, replacementRange: end)
        fixture.textView.breakUndoCoalescing()
        try? await Task.sleep(for: .milliseconds(1))
    }

    /// Cmd-Z: the Undo menu item's action, sent up the responder chain from the text view.
    private func undo(_ fixture: Fixture) {
        XCTAssertTrue(fixture.textView.tryToPerform(Selector(("undo:")), with: nil), "nothing handled undo:")
    }

    /// Cmd-Shift-Z.
    private func redo(_ fixture: Fixture) {
        XCTAssertTrue(fixture.textView.tryToPerform(Selector(("redo:")), with: nil), "nothing handled redo:")
    }

    /// Runs `trigger` and waits for the editor's next `onSave`.
    private func saveAfter(_ fixture: Fixture, _ trigger: () throws -> Void) async throws {
        let saved = expectation(description: "note saved")
        fixture.editor.onSave = { _, _ in saved.fulfill() }
        try trigger()
        await fulfillment(of: [saved], timeout: 10)
        fixture.editor.onSave = nil
    }

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    // MARK: - E-7 undo works

    func testE7_undoRevertsTheLastEditAndRedoReappliesIt() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        XCTAssertTrue(fixture.textView.allowsUndo)
        let manager = try XCTUnwrap(fixture.undoManager)
        XCTAssertFalse(manager.canUndo, "loading a note registers nothing")
        XCTAssertFalse(manager.canRedo)

        await type(" one", in: fixture)
        await type(" two", in: fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body one two")
        XCTAssertTrue(manager.canUndo)

        undo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body one", "the last typing run is undone")
        XCTAssertTrue(manager.canRedo)
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body")
        XCTAssertFalse(manager.canUndo)
        redo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body one")
        redo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body one two")
        XCTAssertFalse(manager.canRedo)
    }

    func testE7_undoIsAnEditForAutosave() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        await type(" edited", in: fixture)
        try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        XCTAssertEqual(try fileText(alpha), "alpha body edited")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)

        undo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body")
        XCTAssertTrue(fixture.editor.hasUnsavedEdits, "the undone text is not yet on disk")
        XCTAssertEqual(fixture.clock.pendingCount, 1)
        try await saveAfter(fixture) { fixture.clock.advance(by: 0.3) }
        XCTAssertEqual(try fileText(alpha), "alpha body", "the file is exactly the text in the view (E-1)")
    }

    // MARK: - E-7 per note

    func testE7_eachNoteHasItsOwnUndoStack() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        let alphaManager = try XCTUnwrap(fixture.undoManager)
        await type(" one", in: fixture)

        try await select(beta, in: fixture)
        let betaManager = try XCTUnwrap(fixture.undoManager)
        XCTAssertFalse(betaManager === alphaManager, "a different note, a different manager")
        XCTAssertFalse(betaManager.canUndo, "alpha's edit is not undoable from beta")
        XCTAssertTrue(alphaManager.canUndo, "and is still undoable in alpha")
        XCTAssertEqual(fixture.textView.string, "beta body")
        _ = fixture.textView.tryToPerform(Selector(("undo:")), with: nil)
        XCTAssertEqual(fixture.textView.string, "beta body", "undo with an empty stack changes nothing")
        XCTAssertEqual(try fileText(alpha), "alpha body one", "and alpha's edit stays written")

        await type(" two", in: fixture)
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, "beta body")
        XCTAssertFalse(betaManager.canUndo)
        XCTAssertTrue(alphaManager.canUndo, "undoing in beta leaves alpha's stack alone")
    }

    // MARK: - E-7 survives switching away and back

    func testE7_undoSurvivesSwitchingAwayAndBack() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        let alphaManager = try XCTUnwrap(fixture.undoManager)
        await type(" one", in: fixture)
        await type(" two", in: fixture)

        try await select(gamma, in: fixture)
        await type("!", in: fixture)
        try await select(alpha, in: fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body one two", "what the switch wrote")
        XCTAssertTrue(fixture.undoManager === alphaManager, "the same stack as before")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)

        undo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body one")
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body")
        redo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body one")

        // Deselecting empties the editor; reselecting brings the stack back, redo included.
        try await saveAfter(fixture) { fixture.table.deselectAll(nil) }
        XCTAssertNil(fixture.editor.noteID)
        XCTAssertEqual(fixture.textView.string, "")
        try await select(alpha, in: fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body one")
        XCTAssertTrue(fixture.undoManager === alphaManager)
        redo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body one two")
        undo(fixture)
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, "alpha body")

        // Gamma's own stack is intact too.
        try await select(gamma, in: fixture)
        XCTAssertEqual(fixture.textView.string, "gamma body!")
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, "gamma body")
    }

    func testE7_aNoteChangedOnDiskWhileAwayStartsAFreshStack() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        let alphaManager = try XCTUnwrap(fixture.undoManager)
        await type(" one", in: fixture)
        try await select(beta, in: fixture)
        XCTAssertEqual(try fileText(alpha), "alpha body one")

        // Something else rewrites the file: the stack was recorded against text that is gone.
        try "rewritten elsewhere".write(
            to: root.appendingPathComponent(alpha.relativePath), atomically: true, encoding: .utf8)
        try await select(alpha, in: fixture)
        XCTAssertEqual(fixture.textView.string, "rewritten elsewhere")
        XCTAssertTrue(fixture.undoManager === alphaManager)
        XCTAssertFalse(alphaManager.canUndo, "a stack for other text is dropped, not replayed")
        _ = fixture.textView.tryToPerform(Selector(("undo:")), with: nil)
        XCTAssertEqual(fixture.textView.string, "rewritten elsewhere")

        // From here the note undoes normally again.
        await type("?", in: fixture)
        undo(fixture)
        XCTAssertEqual(fixture.textView.string, "rewritten elsewhere")
    }

    func testE7_loadingAndReloadingRegisterNothing() async throws {
        let fixture = try await makeFixture()
        try await select(alpha, in: fixture)
        let alphaManager = try XCTUnwrap(fixture.undoManager)
        XCTAssertFalse(alphaManager.canUndo)
        try await select(beta, in: fixture)
        try await select(alpha, in: fixture)
        XCTAssertFalse(alphaManager.canUndo, "switching a clean note back and forth adds nothing to undo")
        XCTAssertFalse(alphaManager.canRedo)
        _ = fixture.textView.tryToPerform(Selector(("undo:")), with: nil)
        XCTAssertEqual(fixture.textView.string, "alpha body")
    }
}
