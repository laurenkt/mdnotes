import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// Headless smoke tests for image files that arrive, change or go under `i/` on their own
/// (I-8: an iCloud sync landing the picture after the note, a Finder drop), reaching the app
/// through the real watcher (X-1) without the note itself changing: the row's square fills,
/// refreshes and empties (S-11), and so does the inline thumbnail in the open note (E-9),
/// while the note is neither reread into the editor nor written back.
@MainActor
final class ImageChangeSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Written oldest first, so the empty query lists Late, Plain (S-3).
    private static let notes: [(path: String, body: String)] = [
        ("Plain.md", "No picture here, only words."),
        ("Late.md", "![[late.png]]\n\nWaiting for its picture.\n"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let late = NoteID(relativePath: "Late.md")
    private let plain = NoteID(relativePath: "Plain.md")

    /// The first picture is wider than tall; the second is a smaller square, so the row's
    /// centre crop and the inline thumbnail both change size when the file changes.
    private static let first = (seed: 3, width: 64, height: 40)
    private static let second = (seed: 4, width: 20, height: 20)

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-imagechange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (i, note) in Self.notes.enumerated() {
            let url = root.appendingPathComponent(note.path)
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
        var editor: EditorController { controller.editorController }
        var list: NoteListController { controller.listController }
        var table: NSTableView { controller.mainView.tableView }
        var textView: NSTextView { controller.mainView.textView }

        /// The inline thumbnails on show, in storage order.
        var thumbnails: [ThumbnailAttachment] {
            var found: [ThumbnailAttachment] = []
            for run in editor.attachmentRanges {
                for index in run.location..<NSMaxRange(run) {
                    if let attachment = editor.thumbnails.attachment(atCharacter: index) { found.append(attachment) }
                }
            }
            return found
        }

        /// The row showing `id`, made if it is not on show yet.
        func row(showing id: NoteID) -> NoteRowView? {
            guard let row = list.results.firstIndex(where: { $0.id == id }) else { return nil }
            return table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NoteRowView
        }

        /// The pixel width of the image the row for `id` shows: its centre square's side.
        func rowImageWidth(_ id: NoteID) -> Int? {
            row(showing: id)?.thumbnailView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width
        }

        /// The thumbnail the list's cache holds for `url` at the list's size.
        func cached(_ url: URL) -> CGImage? {
            list.thumbnails.cachedImage(for: url, pixelSize: list.thumbnailPixelSize)
        }
    }

    /// Width over height, which tells the two pictures apart whatever size they are decoded at.
    private func aspect(_ image: CGImage?) -> Double? {
        image.map { Double($0.width) / Double($0.height) }
    }

    private func aspect(_ image: (seed: Int, width: Int, height: Int)) -> Double {
        Double(image.width) / Double(image.height)
    }

    /// Collects what the editor loads and saves and what the library reports as external.
    @MainActor
    private final class Observer {
        private(set) var loads: [NoteID?] = []
        private(set) var saves: [NoteID] = []
        private(set) var external: [LibraryChanges] = []

        init(_ fixture: Fixture) {
            fixture.editor.onLoad = { [weak self] id in self?.loads.append(id) }
            fixture.editor.onSave = { [weak self] id, _ in self?.saves.append(id) }
            let forward = fixture.library.onExternalChanges
            fixture.library.onExternalChanges = { [weak self] changes in
                self?.external.append(changes)
                forward?(changes)
            }
        }
    }

    /// A laid-out window with a ready, watched library attached.
    private func makeFixture() async throws -> Fixture {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [late, plain])
        XCTAssertTrue(library.isWatching)
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
    private func show(_ id: NoteID, in fixture: Fixture) async throws {
        let row = try XCTUnwrap(fixture.list.results.firstIndex { $0.id == id })
        fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntil("editor shows \(id.relativePath)") {
            fixture.editor.noteID == id && fixture.editor.body != nil
        }
    }

    private var imageURL: URL { root.appendingPathComponent("i/late.png", isDirectory: false) }

    /// Writes the picture the way another program, or iCloud, would: not through the library.
    private func writeImage(_ image: (seed: Int, width: Int, height: Int), modifiedAt: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyntheticLibrary.pngData(seed: image.seed, width: image.width, height: image.height).write(to: imageURL)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: imageURL.path)
        }
    }

    private func noteText() throws -> String {
        try String(contentsOf: root.appendingPathComponent(late.relativePath), encoding: .utf8)
    }

    /// Long enough for the watcher (0.1 s latency) to have delivered anything it was going to.
    private let watcherSettle: Duration = .seconds(1)

    // MARK: - S-11: the row follows the image

    func testS11_anImageArrivingUnderIFillsTheRowSquareWithoutTheNoteChanging() async throws {
        let fixture = try await makeFixture()
        let before = try XCTUnwrap(fixture.row(showing: late))
        XCTAssertNil(before.thumbnailPath, "the embed names nothing yet, so the row has no square")
        XCTAssertTrue(before.thumbnailView.isHidden)
        let observer = Observer(fixture)

        try writeImage(Self.first)
        await waitUntil("the row shows the picture") { fixture.rowImageWidth(self.late) != nil }
        let row = try XCTUnwrap(fixture.row(showing: late))
        XCTAssertEqual(row.thumbnailPath, "i/late.png")
        XCTAssertFalse(row.thumbnailView.isHidden)
        let cached = try XCTUnwrap(fixture.cached(imageURL))
        XCTAssertEqual(aspect(cached), aspect(Self.first))
        XCTAssertEqual(fixture.rowImageWidth(late), min(cached.width, cached.height), "the centre square")
        XCTAssertEqual(fixture.library.snapshot.entry(for: late)?.firstImagePath, "i/late.png")
        XCTAssertNil(fixture.library.snapshot.entry(for: plain)?.firstImagePath)
        XCTAssertNil(fixture.row(showing: plain)?.thumbnailPath)

        // The note was not touched: not on disk, not in the snapshot's text, not in order.
        XCTAssertEqual(try noteText(), Self.notes[1].body)
        XCTAssertEqual(fixture.list.results.map(\.id), [late, plain])
        XCTAssertEqual(fixture.library.snapshot.entry(for: late)?.modifiedAt, Self.base.addingTimeInterval(60))
        try await Task.sleep(for: watcherSettle)
        XCTAssertTrue(
            observer.external.contains { $0.images.contains("i/late.png") },
            "the image was reported by path: \(observer.external)")
        XCTAssertTrue(
            observer.external.allSatisfy { $0.added.isEmpty && $0.modified.isEmpty && $0.removed.isEmpty },
            "and never as a note: \(observer.external)")
        XCTAssertEqual(observer.saves, [])
    }

    func testS11_aChangedImageRefreshesTheRowSquare() async throws {
        try writeImage(Self.first, modifiedAt: Self.base)
        let fixture = try await makeFixture()
        await waitUntil("the row shows the first picture") { fixture.rowImageWidth(self.late) != nil }
        let first = try XCTUnwrap(fixture.cached(imageURL))
        XCTAssertEqual(aspect(first), aspect(Self.first))
        let firstSide = min(first.width, first.height)
        XCTAssertEqual(fixture.rowImageWidth(late), firstSide)

        try writeImage(Self.second)
        await waitUntil("the row shows the second picture") {
            let side = fixture.rowImageWidth(self.late)
            return side != nil && side != firstSide
        }
        let second = try XCTUnwrap(fixture.cached(imageURL))
        XCTAssertEqual(
            aspect(second), aspect(Self.second), "the cache holds the new picture, for rows made from now on")
        XCTAssertEqual(fixture.rowImageWidth(late), min(second.width, second.height))
        XCTAssertEqual(fixture.library.snapshot.entry(for: late)?.firstImagePath, "i/late.png")
        XCTAssertEqual(try noteText(), Self.notes[1].body)
    }

    func testS11_aRemovedImageEmptiesTheRowSquare() async throws {
        try writeImage(Self.first, modifiedAt: Self.base)
        let fixture = try await makeFixture()
        await waitUntil("the row shows the picture") { fixture.rowImageWidth(self.late) != nil }

        try FileManager.default.removeItem(at: imageURL)
        await waitUntil("the row has no square") { fixture.row(showing: self.late)?.thumbnailPath == nil }
        XCTAssertNil(fixture.library.snapshot.entry(for: late)?.firstImagePath, "the embed resolves to nothing")
        XCTAssertEqual(try XCTUnwrap(fixture.row(showing: late)).thumbnailView.isHidden, true)
        XCTAssertEqual(fixture.list.results.map(\.id), [late, plain])
        XCTAssertEqual(try noteText(), Self.notes[1].body)
    }

    // MARK: - E-9: the inline thumbnail follows the image

    func testE9_anImageArrivingShowsItsThumbnailBelowTheEmbedInTheOpenNote() async throws {
        let fixture = try await makeFixture()
        try await show(late, in: fixture)
        XCTAssertEqual(fixture.thumbnails.count, 0, "nothing to show yet")
        let observer = Observer(fixture)

        try writeImage(Self.first)
        await waitUntil("the thumbnail appears") { fixture.thumbnails.count == 1 }
        let thumbnail = try XCTUnwrap(fixture.thumbnails.first)
        XCTAssertEqual(thumbnail.target, "late.png")
        XCTAssertEqual(thumbnail.url, imageURL)
        XCTAssertEqual(aspect(thumbnail.cgImage), aspect(Self.first))
        XCTAssertTrue(fixture.textView.string.hasPrefix("![[late.png]]\n\u{FFFC}\n"), "directly below the embed")
        XCTAssertEqual(fixture.editor.text, Self.notes[1].body, "the file's text is untouched")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits, "a thumbnail arriving is not an edit")
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(observer.loads, [], "the note was not reread into the editor")
        XCTAssertEqual(observer.saves, [])
        XCTAssertEqual(fixture.thumbnails.count, 1)
    }

    func testE9_aChangedImageReplacesTheInlineThumbnailAndARemovedOneTakesItAway() async throws {
        try writeImage(Self.first, modifiedAt: Self.base)
        let fixture = try await makeFixture()
        try await show(late, in: fixture)
        await waitUntil("the first thumbnail") {
            self.aspect(fixture.thumbnails.first?.cgImage) == self.aspect(Self.first)
        }
        let observer = Observer(fixture)

        try writeImage(Self.second)
        await waitUntil("the second thumbnail") {
            self.aspect(fixture.thumbnails.first?.cgImage) == self.aspect(Self.second)
        }
        XCTAssertEqual(fixture.thumbnails.count, 1, "replaced, not stacked")
        XCTAssertEqual(fixture.thumbnails.first?.target, "late.png")
        XCTAssertTrue(fixture.textView.string.hasPrefix("![[late.png]]\n\u{FFFC}\n"))
        XCTAssertEqual(fixture.editor.text, Self.notes[1].body)
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)

        try FileManager.default.removeItem(at: imageURL)
        await waitUntil("the thumbnail is gone") { fixture.thumbnails.isEmpty }
        XCTAssertEqual(fixture.textView.string, Self.notes[1].body, "no attachment line is left behind")
        XCTAssertEqual(fixture.editor.text, Self.notes[1].body)
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(observer.loads, [], "the note was never reread")
        XCTAssertEqual(observer.saves, [], "and never written")
        XCTAssertEqual(fixture.thumbnails.count, 0)
    }

    func testE9_aThumbnailOfAnUnchangedFileIsLeftAloneWhenTheFileIsReportedAgain() async throws {
        try writeImage(Self.first, modifiedAt: Self.base)
        let fixture = try await makeFixture()
        try await show(late, in: fixture)
        await waitUntil("the thumbnail") { fixture.thumbnails.count == 1 }
        let shown = try XCTUnwrap(fixture.thumbnails.first)

        // A report of the file as it is, such as iCloud touching it or our own paste's echo.
        fixture.editor.thumbnails.imagesDidChange(["i/late.png"])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.thumbnails.count, 1)
        XCTAssertIdentical(fixture.thumbnails.first, shown, "the same attachment, never taken down")
    }
}
