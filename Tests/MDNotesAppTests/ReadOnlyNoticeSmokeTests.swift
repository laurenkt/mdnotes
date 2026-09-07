import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the read-only notice (L-8, L-7): a note whose body cannot be
/// written back is shown read-only with one line above the editor saying why, and the line
/// goes away when a writable note is loaded next. The undecodable note is a fabricated
/// non-UTF-8 file; the other bodies are covered through the notice text alone, since a real
/// evicted placeholder cannot be made in a temp directory.
@MainActor
final class ReadOnlyNoticeSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    private let good = NoteID(relativePath: "Good.md")
    private let bad = NoteID(relativePath: "Bad.md")

    /// Latin-1 bytes that are not a valid UTF-8 sequence: "caf\u{E9}" with a lone 0xE9.
    private static let invalidBytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x0A]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "good body".write(to: root.appendingPathComponent(good.relativePath), atomically: true, encoding: .utf8)
        try Data(Self.invalidBytes).write(to: root.appendingPathComponent(bad.relativePath))
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
        var editor: EditorController { controller.editorController }
        var list: NoteListController { controller.listController }
        var view: MainView { controller.mainView }
        var textView: NSTextView { controller.mainView.textView }
        var table: NSTableView { controller.mainView.tableView }
    }

    /// A laid-out window with a ready library attached.
    private func makeFixture() async throws -> Fixture {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root, watchesFileSystem: false)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(Set(controller.listController.results.map(\.id)), [good, bad])
        return Fixture(controller: controller, library: library)
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
        fixture.view.layoutSubtreeIfNeeded()
    }

    // MARK: - L-8

    func testL8_undecodableNoteIsShownReadOnlyWithANoticeAboveTheEditor() async throws {
        let fixture = try await makeFixture()
        XCTAssertTrue(fixture.view.readOnlyNotice.isHidden, "no notice before anything is loaded")

        try await select(bad, in: fixture)
        guard case .invalidUTF8 = fixture.editor.body else {
            return XCTFail("expected an undecodable body, got \(String(describing: fixture.editor.body))")
        }
        XCTAssertFalse(fixture.textView.isEditable)
        XCTAssertEqual(fixture.textView.string, "caf\u{FFFD}\n", "lossy text is shown, never written")

        let notice = try XCTUnwrap(fixture.editor.readOnlyNotice)
        XCTAssertEqual(fixture.view.readOnlyNotice.notice, notice)
        XCTAssertEqual(fixture.view.readOnlyNotice.label.stringValue, notice)
        XCTAssertFalse(fixture.view.readOnlyNotice.isHidden)
        XCTAssertTrue(notice.localizedCaseInsensitiveContains("read-only"))
        XCTAssertTrue(notice.localizedCaseInsensitiveContains("UTF-8"))

        // The bar sits above the editor, inside the split's bottom pane, one line high.
        let bar = fixture.view.readOnlyNotice.frame
        let editor = fixture.view.editorScrollView.frame
        let pane = fixture.view.editorPane.frame
        XCTAssertEqual(bar.height, ReadOnlyNoticeBar.height, accuracy: 0.5)
        XCTAssertEqual(bar.width, pane.width, accuracy: 0.5)
        XCTAssertEqual(bar.maxY, pane.height, accuracy: 0.5)
        XCTAssertEqual(editor.maxY, bar.minY, accuracy: 0.5)
        XCTAssertEqual(editor.minY, 0, accuracy: 0.5)
    }

    func testL8_noticeIsClearedWhenAWritableNoteIsLoadedNext() async throws {
        let fixture = try await makeFixture()
        var changes: [String?] = []
        let forward = fixture.editor.onReadOnlyNoticeChange
        fixture.editor.onReadOnlyNoticeChange = { notice in
            changes.append(notice)
            forward?(notice)
        }

        try await select(bad, in: fixture)
        XCTAssertNotNil(fixture.editor.readOnlyNotice)
        XCTAssertFalse(fixture.view.readOnlyNotice.isHidden)

        try await select(good, in: fixture)
        XCTAssertTrue(fixture.textView.isEditable)
        XCTAssertEqual(fixture.textView.string, "good body")
        XCTAssertNil(fixture.editor.readOnlyNotice)
        XCTAssertNil(fixture.view.readOnlyNotice.notice)
        XCTAssertTrue(fixture.view.readOnlyNotice.isHidden)
        XCTAssertEqual(fixture.view.editorScrollView.frame.size, fixture.view.editorPane.frame.size)
        XCTAssertEqual(changes.count, 2, "one change per load: shown, then cleared")
        XCTAssertNotNil(changes.first ?? nil)
        XCTAssertNil(changes.last ?? nil)
    }

    func testL8_clearingTheEditorClearsTheNotice() async throws {
        let fixture = try await makeFixture()
        try await select(bad, in: fixture)
        XCTAssertFalse(fixture.view.readOnlyNotice.isHidden)

        fixture.editor.clear()
        XCTAssertNil(fixture.editor.readOnlyNotice)
        XCTAssertTrue(fixture.view.readOnlyNotice.isHidden)
    }

    // MARK: - L-7

    func testL7_notDownloadedBodyHasANoticeAndWritableBodyHasNone() {
        let notDownloaded = EditorController.readOnlyNotice(for: .notDownloaded)
        XCTAssertNotNil(notDownloaded)
        XCTAssertTrue(notDownloaded?.localizedCaseInsensitiveContains("downloaded") ?? false)
        XCTAssertTrue(notDownloaded?.localizedCaseInsensitiveContains("read-only") ?? false)
        XCTAssertNil(EditorController.readOnlyNotice(for: .text("anything")))
        XCTAssertNotNil(EditorController.readOnlyNotice(for: .invalidUTF8(lossyText: "")))
        XCTAssertNotNil(EditorController.readOnlyNotice(for: nil), "an unreadable file is read-only too")
        XCTAssertEqual(EditorController.readOnlyNotice(for: .notDownloaded)?.contains("\n"), false, "one line")
    }
}
