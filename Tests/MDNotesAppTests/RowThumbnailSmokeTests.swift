import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// Headless smoke tests for row thumbnails (S-11): the 34 pt square at the row's right end
/// for a note with an image, empty until the cache has the image and filled from the cache on
/// redisplay (PF-8), a stale completion dropped by a recycled row, a click on the square
/// landing on the row, and the list rendered with thumbnails to `build/snapshots/` (V-1).
@MainActor
final class RowThumbnailSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    private let photo = NoteID(relativePath: "Photo.md")
    private let plain = NoteID(relativePath: "Plain.md")
    private let broken = NoteID(relativePath: "Broken.md")
    private let missing = NoteID(relativePath: "Missing.md")

    /// Written oldest first, so the empty query lists Missing, Broken, Plain, Photo (S-3).
    private static let notes: [(path: String, body: String)] = [
        ("Photo.md", "![[photo.png]]\n\nA note with a picture in it."),
        ("Plain.md", "No picture here, only words."),
        ("Broken.md", "![[bad.png]]\n\nThe file exists but is no image."),
        ("Missing.md", "![[gone.png]]\n\nThe file does not exist."),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-rowthumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("i", isDirectory: true), withIntermediateDirectories: true)
        try SyntheticLibrary.pngData(seed: 3, width: 64, height: 40).write(
            to: root.appendingPathComponent("i/photo.png"))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("i/bad.png"))
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

    /// A laid-out window showing the whole library through the list controller, with the
    /// image root set as `attach` would set it, so rows look thumbnails up under `root`.
    private func makeControllerShowingIndex(
        size: NSSize = NSSize(width: 800, height: 600)
    ) throws -> (MainWindowController, SearchIndex) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(size)
        controller.mainView.layoutSubtreeIfNeeded()
        controller.listController.imageRoot = root
        let index = SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: NoteStore(root: root))
        controller.listController.show(index.query(""))
        return (controller, index)
    }

    private func rowView(_ controller: MainWindowController, showing id: NoteID) throws -> NoteRowView {
        let row = try XCTUnwrap(controller.listController.results.firstIndex { $0.id == id })
        let view = try XCTUnwrap(
            controller.mainView.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NoteRowView)
        view.layoutSubtreeIfNeeded()
        return view
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

    /// Asks `cache` for `url` and waits for the answer, which arrives after any request for
    /// the same file made before it.
    private func awaitThumbnail(_ cache: ThumbnailCache, _ url: URL, pixelSize: Int) async -> CGImage? {
        let done = expectation(description: "thumbnail of \(url.lastPathComponent)")
        let box = ImageBox()
        cache.request(url, pixelSize: pixelSize) { image in
            box.image = image
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 20)
        return box.image
    }

    @MainActor
    private final class ImageBox {
        var image: CGImage?
    }

    // MARK: S-11 the square, empty until ready, then the image

    func testS11_rowWithAnImageReservesTheSquareAndShowsTheThumbnailOnceCached() async throws {
        let (controller, index) = try makeControllerShowingIndex()
        XCTAssertEqual(try XCTUnwrap(index.entry(for: photo)).firstImagePath, "i/photo.png")
        let list = controller.listController
        XCTAssertEqual(list.thumbnails.count, 0, "nothing is cached before a row is shown")

        let row = try rowView(controller, showing: photo)
        XCTAssertEqual(row.thumbnailPath, "i/photo.png")
        XCTAssertFalse(row.thumbnailView.isHidden, "the square is there from the first draw")
        XCTAssertNil(row.thumbnailView.image, "but empty until the thumbnail is ready")

        // The square: 34 pt, at the trailing inset, centred on the row's height, and the date,
        // title and snippet all end before it.
        let side = NoteRowView.thumbnailSize
        XCTAssertEqual(side, 34)
        let square = row.thumbnailView.frame
        XCTAssertEqual(square.size, NSSize(width: side, height: side))
        XCTAssertEqual(square.maxX, row.bounds.width - 8, accuracy: 0.5)
        XCTAssertEqual(square.midY, row.bounds.height / 2, accuracy: 0.5)
        XCTAssertLessThanOrEqual(row.dateLabel.frame.maxX, square.minX - 8)
        XCTAssertLessThanOrEqual(row.titleLabel.frame.maxX, row.dateLabel.frame.minX)
        XCTAssertLessThanOrEqual(row.snippetLabel.frame.maxX, square.minX - 8)
        let dateWidth = row.dateLabel.sizeThatFits(NSSize(width: 1000, height: 100)).width
        XCTAssertGreaterThanOrEqual(row.dateLabel.frame.width, dateWidth, "S-10 still holds beside a thumbnail")

        // Requested on display, delivered on main, shown in place.
        await waitUntil("thumbnail shown") { row.thumbnailView.image != nil }
        let image = try XCTUnwrap(row.thumbnailView.image)
        XCTAssertEqual(image.size, NSSize(width: side, height: side), "cropped to a square")
        XCTAssertEqual(list.thumbnails.count, 1)
        XCTAssertNotNil(
            list.thumbnails.cachedImage(
                for: root.appendingPathComponent("i/photo.png"),
                pixelSize: list.thumbnailPixelSize))
    }

    func testS11_rowWithoutAnImageHasNoSquareAndKeepsTheDateAtTheTrailingEdge() throws {
        let (controller, index) = try makeControllerShowingIndex()
        XCTAssertNil(try XCTUnwrap(index.entry(for: plain)).firstImagePath)
        XCTAssertNil(try XCTUnwrap(index.entry(for: missing)).firstImagePath, "an embed of a missing file is no image")
        for id in [plain, missing] {
            let row = try rowView(controller, showing: id)
            XCTAssertNil(row.thumbnailPath)
            XCTAssertTrue(row.thumbnailView.isHidden)
            XCTAssertEqual(row.dateLabel.frame.maxX, row.bounds.width - 8, accuracy: 0.5)
        }
    }

    func testS11_redisplayDrawsFromTheCacheWithoutWaiting() async throws {
        let (controller, _) = try makeControllerShowingIndex()
        let list = controller.listController
        let first = try rowView(controller, showing: photo)
        await waitUntil("thumbnail shown") { first.thumbnailView.image != nil }

        // A reload makes the rows again; the square is filled on the way out of `viewFor`.
        list.tableView.reloadData()
        let again = try rowView(controller, showing: photo)
        XCTAssertNotNil(again.thumbnailView.image, "a cached thumbnail is drawn with the row")
        XCTAssertEqual(list.thumbnails.count, 1, "no second entry for the same file and size")
    }

    func testS11_fileThatIsNotAnImageLeavesTheSquareEmpty() async throws {
        let (controller, index) = try makeControllerShowingIndex()
        XCTAssertEqual(
            try XCTUnwrap(index.entry(for: broken)).firstImagePath, "i/bad.png",
            "the index goes by extension; the decoder has the last word")
        let list = controller.listController
        let row = try rowView(controller, showing: broken)
        XCTAssertFalse(row.thumbnailView.isHidden)
        let answer = await awaitThumbnail(
            list.thumbnails, root.appendingPathComponent("i/bad.png"), pixelSize: list.thumbnailPixelSize)
        XCTAssertNil(answer)
        XCTAssertNil(row.thumbnailView.image, "nothing to show, so nothing is shown")
        XCTAssertNil(
            list.thumbnails.cachedImage(
                for: root.appendingPathComponent("i/bad.png"), pixelSize: list.thumbnailPixelSize),
            "nothing is cached for it either")
    }

    func testS11_noRootMeansNoLookup() throws {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        XCTAssertNil(controller.listController.imageRoot, "no library attached yet")
        let index = SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: NoteStore(root: root))
        controller.listController.show(index.query(""))
        let row = try rowView(controller, showing: photo)
        XCTAssertNil(controller.listController.thumbnailURL(for: try XCTUnwrap(index.entry(for: photo))))
        XCTAssertNil(row.thumbnailView.image)
        XCTAssertEqual(controller.listController.thumbnails.count, 0)
    }

    func testS11_attachingALibrarySetsTheRootAndDetachingClearsIt() async throws {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root, watchesFileSystem: false)
        controller.attach(library)
        XCTAssertEqual(controller.listController.imageRoot, root)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        let row = try rowView(controller, showing: photo)
        await waitUntil("thumbnail shown") { row.thumbnailView.image != nil }
        controller.detachLibrary()
        XCTAssertNil(controller.listController.imageRoot)
    }

    // MARK: S-11 a recycled row drops a stale completion

    func testS11_recycledRowDropsAThumbnailForTheNoteItNoLongerShows() async throws {
        let (controller, index) = try makeControllerShowingIndex()
        let list = controller.listController
        let answer = await awaitThumbnail(
            list.thumbnails, root.appendingPathComponent("i/photo.png"), pixelSize: list.thumbnailPixelSize)
        let image = try XCTUnwrap(answer)
        let row = NoteRowView(frame: NSRect(x: 0, y: 0, width: 300, height: NoteListController.rowHeight))
        row.configure(entry: try XCTUnwrap(index.entry(for: photo)), dateText: "Today 11:53")
        XCTAssertEqual(row.thumbnailPath, "i/photo.png")

        // The row is reused for a note without an image before the completion lands.
        row.configure(entry: try XCTUnwrap(index.entry(for: plain)), dateText: "Today 11:54")
        XCTAssertFalse(row.showThumbnail(image, for: "i/photo.png"))
        XCTAssertNil(row.thumbnailView.image)
        XCTAssertTrue(row.thumbnailView.isHidden)

        // Back on the note with the image: the completion is taken and the square filled.
        row.configure(entry: try XCTUnwrap(index.entry(for: photo)), dateText: "Today 11:53")
        XCTAssertNil(row.thumbnailView.image, "configuring empties the square")
        XCTAssertTrue(row.showThumbnail(image, for: "i/photo.png"))
        XCTAssertNotNil(row.thumbnailView.image)
    }

    // MARK: S-11 a click on the thumbnail selects the note

    func testS11_clickOnTheThumbnailIsKeptByTheTableWhichSelectsTheRow() async throws {
        let (controller, _) = try makeControllerShowingIndex()
        let window = try XCTUnwrap(controller.window)
        let table = controller.mainView.tableView
        let row = try rowView(controller, showing: photo)
        await waitUntil("thumbnail shown") { row.thumbnailView.image != nil }
        let rowIndex = try XCTUnwrap(controller.listController.results.firstIndex { $0.id == photo })

        // Whether the hit test names the table or the image view under the pointer, the
        // mouse-down reaches the table only if the subview may not take it: the window asks
        // `validateProposedFirstResponder`, the image view is refused, and the table treats
        // the click as one on the row under the pointer and selects it.
        let centre = row.convert(NSPoint(x: row.thumbnailView.frame.midX, y: row.thumbnailView.frame.midY), to: nil)
        let hit = try XCTUnwrap(window.contentView?.hitTest(centre))
        XCTAssertTrue(hit === table || hit.isDescendant(of: table), "the click lands inside the table")
        XCTAssertEqual(table.row(at: table.convert(centre, from: nil)), rowIndex, "the pointer is on the note's row")
        XCTAssertIdentical(
            row.hitTest(
                row.convert(row.thumbnailView.frame.origin.applying(.init(translationX: 17, y: 17)), to: row.superview)),
            row.thumbnailView, "and over the image view")
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: centre, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertFalse(
            table.validateProposedFirstResponder(row.thumbnailView, for: event),
            "the image view does not take the click, so the table keeps it for selection")
        XCTAssertFalse(row.thumbnailView.acceptsFirstResponder)
        XCTAssertFalse(row.thumbnailView.isEditable)
    }

    // MARK: V-1 snapshot

    func testV1_rendersTheListWithThumbnails() async throws {
        let long = "A sixty character title long enough to overflow a narrow row"
        try SyntheticLibrary.pngData(seed: 7, width: 40, height: 64).write(
            to: root.appendingPathComponent("i/tall.png"))
        try write(
            long + ".md", body: "![[tall.png]]\n\nA long title beside a thumbnail: the title yields, the date stays.",
            modifiedAt: Date().addingTimeInterval(-3600))
        let (controller, _) = try makeControllerShowingIndex(size: NSSize(width: 480, height: 400))
        // The newest note, so the selection highlight is under a thumbnail without scrolling.
        controller.listController.select(NoteID(relativePath: long + ".md"))
        let table = controller.mainView.tableView
        var rows: [NoteRowView] = []
        for row in 0..<table.numberOfRows {
            rows.append(try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NoteRowView))
        }
        let withImages = rows.filter { $0.thumbnailPath != nil && $0.thumbnailPath != "i/bad.png" }
        XCTAssertEqual(withImages.count, 2)
        await waitUntil("thumbnails shown") { withImages.allSatisfy { $0.thumbnailView.image != nil } }
        let written = try writeWindowSnapshots(of: controller, named: "note-list-thumbnails")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }
}
