import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import Synchronization
import XCTest

/// Headless smoke tests for the editor's inline thumbnails (E-9, ADR-0012): a real library
/// with real PNGs under `i/`, the note shown through the real list selection, the thumbnails
/// looked up off the main thread and placed below the embeds that resolve, and only those; an
/// edit that stops an embed resolving takes its thumbnail away; a click on one opens the image;
/// the file never holds one; the thumbnails come from the cache the list rows share (PF-8);
/// and the editor rendered with thumbnails to `build/snapshots/` (V-1).
@MainActor
final class EditorThumbnailSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// An embed of a wide image, one of a file that is not there, two on one line (a tall and
    /// a tiny image), one inside a code span, and one of a file that is not an image.
    private static let picsBody = """
        # Pics

        ![[one.png]]
        after #tag

        ![[missing.png]]

        ![[tall.png]] and ![[tiny.png]]

        `![[one.png]]` in code

        ![[notes.txt]]

        """
    private static let otherBody = "# Other\n\nNothing to see.\n"

    /// `picsBody` with its first embed (not the spelling inside the code span) replaced.
    private static func picsBody(withFirstEmbed replacement: String) -> String {
        let body = picsBody as NSString
        return body.replacingCharacters(in: body.range(of: "![[one.png]]"), with: replacement)
    }

    private let pics = NoteID(relativePath: "Pics.md")
    private let other = NoteID(relativePath: "Other.md")

    /// Pixel sizes of the generated images, all stating no DPI, so a pixel is a point: `one`
    /// is 3:2, `tall` 1:4 and `tiny` smaller than any editor.
    private static let images: [(name: String, width: Int, height: Int)] = [
        ("one.png", 480, 320), ("tall.png", 100, 400), ("tiny.png", 40, 30),
    ]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-thumbnails-\(UUID().uuidString)", isDirectory: true)
        let images = root.appendingPathComponent("i", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for (i, image) in Self.images.enumerated() {
            try SyntheticLibrary.pngData(seed: i + 1, width: image.width, height: image.height)
                .write(to: images.appendingPathComponent(image.name))
        }
        try Data("not an image".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, note) in [("Other.md", Self.otherBody), ("Pics.md", Self.picsBody)].enumerated() {
            let url = root.appendingPathComponent(note.0)
            try Data(note.1.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(Double(i) * 60)], ofItemAtPath: url.path)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// Counts the decodes a cache does and the threads they run on, through `willGenerate`.
    private final class Decodes: Sendable {
        private let seen = Mutex<[(path: String, onMain: Bool)]>([])
        var count: Int { seen.withLock { $0.count } }
        var paths: [String] { seen.withLock { $0.map(\.path) } }
        var anyOnMain: Bool { seen.withLock { $0.contains { $0.onMain } } }
        func record(_ url: URL) {
            let onMain = Thread.isMainThread
            seen.withLock { $0.append((url.lastPathComponent, onMain)) }
        }
    }

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let library: LibraryController
        let clock: ManualAutosaveClock
        let decodes: Decodes
        var editor: EditorController { controller.editorController }
        var textView: EditorTextView { controller.mainView.textView }
        var storage: NSTextStorage { textView.textStorage ?? NSTextStorage() }
        var table: NSTableView { controller.mainView.tableView }
        var window: NSWindow { controller.window ?? NSWindow() }

        /// The storage's text, attachment characters included.
        var shown: String { storage.string }

        /// The thumbnails on show, in storage order, with the index of each attachment character.
        var thumbnails: [(index: Int, attachment: ThumbnailAttachment)] {
            var found: [(Int, ThumbnailAttachment)] = []
            for run in editor.attachmentRanges {
                for index in run.location..<NSMaxRange(run) {
                    if let attachment = editor.thumbnails.attachment(atCharacter: index) {
                        found.append((index, attachment))
                    }
                }
            }
            return found
        }

        /// The targets of the thumbnails on show, in storage order.
        var targets: [String] { thumbnails.map(\.attachment.target) }

        /// Types `text` at storage index `location`, as a keystroke does.
        func type(_ text: String, at location: Int) {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.insertText(text, replacementRange: textView.selectedRange())
        }

        /// The storage index of the first occurrence of `needle` in the shown text.
        func location(of needle: String) -> Int {
            (shown as NSString).range(of: needle).location
        }
    }

    /// A laid-out window with a ready library attached, on a manual clock, with a cache whose
    /// decodes are counted.
    private func makeFixture(size: NSSize = NSSize(width: 800, height: 600)) async throws -> Fixture {
        let clock = ManualAutosaveClock()
        let decodes = Decodes()
        let cache = ThumbnailCache(maximumBytes: ThumbnailCache.defaultMaximumBytes, concurrentJobs: 2) { url in
            decodes.record(url)
        }
        let controller = makeMainWindowController(autosaveClock: clock, thumbnails: cache)
        controller.window?.setContentSize(size)
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        return Fixture(controller: controller, library: library, clock: clock, decodes: decodes)
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
        let row = try XCTUnwrap(fixture.controller.listController.results.firstIndex { $0.id == id })
        fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntil("editor shows \(id.relativePath)") {
            fixture.editor.noteID == id && fixture.editor.body != nil
        }
    }

    /// The Pics note shown with its three thumbnails on show.
    private func showPics(size: NSSize = NSSize(width: 800, height: 600)) async throws -> Fixture {
        let fixture = try await makeFixture(size: size)
        try await show(pics, in: fixture)
        await waitUntil("three thumbnails") { fixture.thumbnails.count == 3 }
        return fixture
    }

    /// Runs `trigger` and waits for the editor's next `onSave`.
    private func saveAfter(_ fixture: Fixture, _ trigger: () throws -> Void) async throws {
        let saved = expectation(description: "note saved")
        fixture.editor.onSave = { _, result in
            if case .failure(let error) = result { XCTFail("save failed: \(error)") }
            saved.fulfill()
        }
        try trigger()
        await fulfillment(of: [saved], timeout: 10)
        fixture.editor.onSave = nil
    }

    private static let run = "\n\u{FFFC}"

    // MARK: - Placement (E-9)

    func testE9_anEmbedThatResolvesToAnImageGetsAThumbnailOnTheLineBelowIt() async throws {
        let fixture = try await showPics()
        XCTAssertEqual(fixture.editor.text, Self.picsBody, "the file's text is untouched")
        XCTAssertEqual(
            fixture.shown,
            """
            # Pics

            ![[one.png]]\(Self.run)
            after #tag

            ![[missing.png]]

            ![[tall.png]] and ![[tiny.png]]\(Self.run)\(Self.run)

            `![[one.png]]` in code

            ![[notes.txt]]

            """,
            "one thumbnail per resolving embed, each directly below its line; none for a missing file, "
                + "a spelling inside code or a file that is not an image")
        XCTAssertEqual(fixture.targets.first, "one.png")
        XCTAssertEqual(Set(fixture.targets.dropFirst()), ["tall.png", "tiny.png"], "two embeds on one line stack")
        for (_, attachment) in fixture.thumbnails {
            XCTAssertEqual(attachment.url, root.appendingPathComponent("i/\(attachment.target)"), attachment.target)
            XCTAssertNotNil(attachment.image, "the thumbnail carries its image")
        }
        // The attachment lines are display-only: the marker is on both of their characters.
        for run in fixture.editor.attachmentRanges {
            for index in run.location..<NSMaxRange(run) {
                XCTAssertNotNil(
                    fixture.storage.attribute(EditorText.displayOnlyAttribute, at: index, effectiveRange: nil))
            }
        }
    }

    // MARK: - Fitting the editor (E-9, ADR-0021)

    private let sizes = NoteID(relativePath: "Sizes.md")

    /// The images the Sizes note embeds, beyond `tiny`: `wide` (6:1) and `column` (1:10) far
    /// bigger than any editor, and `retina` a 400 by 200 pixel image stating 144 DPI, so
    /// 200 by 100 points.
    private static let sizesBody = """
        # Sizes

        ![[tiny.png]]

        ![[retina.png]]

        ![[wide.png]]

        ![[column.png]]

        """

    /// Writes the Sizes note and its images, then shows it with its four thumbnails on show.
    private func showSizes(size: NSSize = NSSize(width: 800, height: 600)) async throws -> Fixture {
        let images = root.appendingPathComponent("i", isDirectory: true)
        try SyntheticLibrary.pngData(seed: 11, width: 1200, height: 200).write(
            to: images.appendingPathComponent("wide.png"))
        try SyntheticLibrary.pngData(seed: 12, width: 120, height: 1200)
            .write(to: images.appendingPathComponent("column.png"))
        try SyntheticLibrary.pngData(seed: 13, width: 400, height: 200, dpi: 144)
            .write(to: images.appendingPathComponent("retina.png"))
        try Data(Self.sizesBody.utf8).write(to: root.appendingPathComponent(sizes.relativePath))
        let fixture = try await makeFixture(size: size)
        try await show(sizes, in: fixture)
        await waitUntil("four thumbnails") { fixture.thumbnails.count == 4 }
        return fixture
    }

    /// The thumbnail on show for `target`.
    private func thumbnail(_ target: String, in fixture: Fixture) throws -> ThumbnailAttachment {
        try XCTUnwrap(fixture.thumbnails.first { $0.attachment.target == target }?.attachment, target)
    }

    /// The text's usable width, measured apart from `fitBox`: the container's width less its
    /// line fragment padding on both sides (the text container inset is outside it).
    private func usableWidth(_ fixture: Fixture) throws -> CGFloat {
        let container = try XCTUnwrap(fixture.textView.textContainer)
        return container.size.width - 2 * container.lineFragmentPadding
    }

    /// The height of the editor scroll view's visible area.
    private func visibleHeight(_ fixture: Fixture) -> CGFloat {
        fixture.controller.mainView.editorScrollView.contentView.bounds.height
    }

    /// The line fragment the thumbnail's attachment character is laid out in.
    private func lineFragment(of thumbnail: ThumbnailAttachment, in fixture: Fixture) throws -> NSRect {
        let index = try XCTUnwrap(fixture.thumbnails.first { $0.attachment === thumbnail }?.index)
        let layoutManager = try XCTUnwrap(fixture.textView.layoutManager)
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// Waits until `thumbnail`'s image has been asked for again at the pixel size its drawn
    /// size wants on this window, and checks the image is that size.
    private func waitUntilSharp(_ thumbnail: ThumbnailAttachment, in fixture: Fixture) async {
        let scale = fixture.window.backingScaleFactor
        let wanted = EditorThumbnails.pixelSize(forDrawnSize: thumbnail.bounds.size, of: thumbnail.source, scale: scale)
        await waitUntil("\(thumbnail.target) at \(wanted) pixels") { thumbnail.pixelSize == wanted }
        XCTAssertEqual(
            max(thumbnail.cgImage.width, thumbnail.cgImage.height), wanted,
            "\(thumbnail.target) decoded at the drawn size")
    }

    func testE9_wideImageFillsTextWidth() async throws {
        let fixture = try await showSizes()
        let wide = try thumbnail("wide.png", in: fixture)
        let width = try usableWidth(fixture)
        XCTAssertGreaterThan(width, 300, "the editor is laid out")
        XCTAssertEqual(fixture.editor.thumbnails.fitBox.width, width, accuracy: 0.01)
        XCTAssertEqual(wide.bounds.width, width, accuracy: 0.01, "the full usable width, margins and padding excluded")
        XCTAssertEqual(wide.bounds.height, width / 6, accuracy: 0.01)
        // It fits on its line: the fragment starts at the container's edge, holds the image
        // whole, and no wider than the container.
        let fragment = try lineFragment(of: wide, in: fixture)
        XCTAssertGreaterThanOrEqual(fragment.height, wide.bounds.height)
        XCTAssertLessThanOrEqual(fragment.maxX, try XCTUnwrap(fixture.textView.textContainer).size.width + 0.01)
        await waitUntilSharp(wide, in: fixture)
    }

    func testE9_tallImageFitsVisibleHeight() async throws {
        let fixture = try await showSizes()
        let column = try thumbnail("column.png", in: fixture)
        let height = visibleHeight(fixture)
        XCTAssertGreaterThan(height, 100, "the editor is laid out")
        XCTAssertLessThan(height, 1200, "the image is taller than the editor")
        XCTAssertEqual(fixture.editor.thumbnails.fitBox.height, height, accuracy: 0.01)
        XCTAssertEqual(column.bounds.height, height, accuracy: 0.01, "the visible height, not the width, bounds it")
        XCTAssertEqual(column.bounds.width, height / 10, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(try lineFragment(of: column, in: fixture).height, column.bounds.height)
        await waitUntilSharp(column, in: fixture)
    }

    func testE9_smallImageAtNaturalPointSize() async throws {
        let fixture = try await showSizes()
        let tiny = try thumbnail("tiny.png", in: fixture)
        XCTAssertEqual(tiny.source.points, CGSize(width: 40, height: 30), "no DPI stated: a pixel is a point")
        XCTAssertEqual(tiny.bounds.size, NSSize(width: 40, height: 30), "its own size, never enlarged to the width")
        // Asked for in full: the window's scale never asks for more pixels than the file has.
        XCTAssertEqual(tiny.pixelSize, 40)
        XCTAssertEqual(tiny.cgImage.width, 40)
        XCTAssertEqual(tiny.cgImage.height, 30)
    }

    func testE9_retinaImageAtPointSizeNotPixels() async throws {
        let fixture = try await showSizes()
        let retina = try thumbnail("retina.png", in: fixture)
        XCTAssertEqual(retina.source.pixels, CGSize(width: 400, height: 200))
        XCTAssertEqual(retina.source.points.width, 200, accuracy: 0.1, "144 DPI: pixels over a scale of two")
        XCTAssertEqual(retina.source.points.height, 100, accuracy: 0.1)
        XCTAssertEqual(retina.bounds.width, 200, accuracy: 0.1, "drawn at its point size, not its pixel size")
        XCTAssertEqual(retina.bounds.height, 100, accuracy: 0.1)
        // Its pixels are what the window's scale needs of the drawn size, at most the file's.
        let scale = fixture.window.backingScaleFactor
        XCTAssertEqual(retina.pixelSize, min(Int(ceil(retina.bounds.width * scale)), 400))
        XCTAssertEqual(retina.cgImage.width, retina.pixelSize)
        XCTAssertEqual(
            EditorThumbnails.pixelSize(forDrawnSize: NSSize(width: 200, height: 100), of: retina.source, scale: 2), 400)
        XCTAssertEqual(
            EditorThumbnails.pixelSize(forDrawnSize: NSSize(width: 200, height: 100), of: retina.source, scale: 1), 200)
        XCTAssertEqual(
            EditorThumbnails.pixelSize(forDrawnSize: NSSize(width: 200, height: 100), of: retina.source, scale: 3), 400)
    }

    func testE9_refitsOnEditorResize() async throws {
        let fixture = try await showSizes(size: NSSize(width: 900, height: 700))
        let wide = try thumbnail("wide.png", in: fixture)
        let column = try thumbnail("column.png", in: fixture)
        let tiny = try thumbnail("tiny.png", in: fixture)
        await waitUntilSharp(wide, in: fixture)
        let before = wide.bounds.size

        // A narrower window: the wide image follows the text width at once, its line laid out
        // again, and its image is asked for again at the new pixel size.
        fixture.window.setContentSize(NSSize(width: 600, height: 700))
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        let narrower = try usableWidth(fixture)
        XCTAssertLessThan(narrower, before.width - 100)
        XCTAssertEqual(wide.bounds.width, narrower, accuracy: 0.01, "refitted on the resize, not on the next edit")
        XCTAssertEqual(wide.bounds.height, narrower / 6, accuracy: 0.01)
        let fragment = try lineFragment(of: wide, in: fixture)
        XCTAssertGreaterThanOrEqual(fragment.height, wide.bounds.height)
        XCTAssertLessThan(fragment.height, before.height, "the line shrank with it")
        await waitUntilSharp(wide, in: fixture)
        XCTAssertEqual(tiny.bounds.size, NSSize(width: 40, height: 30), "a small image stays as it is")

        // A split drag: the editor's visible height changes and the column follows it.
        let split = fixture.controller.mainView.splitView
        let heightBefore = visibleHeight(fixture)
        split.setPosition(split.minPossiblePositionOfDivider(at: 0) + 60, ofDividerAt: 0)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        let heightAfter = visibleHeight(fixture)
        XCTAssertNotEqual(heightAfter, heightBefore, accuracy: 1, "the split moved")
        XCTAssertEqual(column.bounds.height, heightAfter, accuracy: 0.01)
        XCTAssertEqual(column.bounds.width, heightAfter / 10, accuracy: 0.01)
        await waitUntilSharp(column, in: fixture)

        // A wider window again: back up to the new width, never past the image's own size.
        fixture.window.setContentSize(NSSize(width: 1000, height: 700))
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        XCTAssertEqual(wide.bounds.width, try usableWidth(fixture), accuracy: 0.01)
        XCTAssertEqual(tiny.bounds.size, NSSize(width: 40, height: 30))

        // Cmd-plus (E-8): the font size changes and every thumbnail is fitted again.
        defer { UserDefaults.standard.removeObject(forKey: EditorFontPreference.sizeDefaultsKey) }
        fixture.controller.makeTextBigger(nil)
        for (_, thumbnail) in fixture.thumbnails {
            XCTAssertEqual(
                thumbnail.bounds.size,
                EditorThumbnails.displaySize(
                    forPointSize: thumbnail.source.points, fitting: fixture.editor.thumbnails.fitBox),
                thumbnail.target)
        }
        XCTAssertFalse(fixture.editor.hasUnsavedEdits, "refitting is not an edit")
    }

    func testE9_aspectRatioLocked() async throws {
        let fixture = try await showSizes()
        func checkProportions(_ when: String) {
            for (_, thumbnail) in fixture.thumbnails {
                let source = thumbnail.source.pixels
                XCTAssertEqual(
                    thumbnail.bounds.width / thumbnail.bounds.height, source.width / source.height, accuracy: 0.001,
                    "\(thumbnail.target) \(when)")
            }
        }
        checkProportions("as placed")
        fixture.window.setContentSize(NSSize(width: 520, height: 420))
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        checkProportions("after a resize")

        // The rule itself: the smallest of the image's size, the width and the height bound
        // it, both sides scaled alike, never up; a side of the box not known bounds nothing.
        let fit = { (w: CGFloat, h: CGFloat, boxW: CGFloat, boxH: CGFloat) in
            EditorThumbnails.displaySize(
                forPointSize: CGSize(width: w, height: h), fitting: NSSize(width: boxW, height: boxH))
        }
        XCTAssertEqual(fit(4000, 3000, 600, 300), NSSize(width: 400, height: 300), "height bounds")
        XCTAssertEqual(fit(4000, 1000, 600, 300), NSSize(width: 600, height: 150), "width bounds")
        XCTAssertEqual(fit(100, 50, 600, 300), NSSize(width: 100, height: 50), "never enlarged")
        XCTAssertEqual(fit(1200, 200, 600, 0), NSSize(width: 600, height: 100))
        XCTAssertEqual(fit(1200, 200, 0, 0), NSSize(width: 1200, height: 200))
        XCTAssertEqual(fit(0, 0, 600, 300), .zero)
    }

    // MARK: - Following the text (E-9)

    func testE9_editingTheEmbedSoItNoLongerResolvesRemovesItsThumbnailAndUndoBringsItBack() async throws {
        let fixture = try await showPics()
        // "![[one.png]]" becomes "![[onex.png]]", which names nothing.
        fixture.type("x", at: fixture.location(of: "one.png") + 3)
        XCTAssertEqual(
            fixture.editor.text, Self.picsBody(withFirstEmbed: "![[onex.png]]"))
        await waitUntil("the thumbnail is gone") { fixture.thumbnails.count == 2 }
        XCTAssertEqual(Set(fixture.targets), ["tall.png", "tiny.png"])
        XCTAssertTrue(
            fixture.shown.contains("![[onex.png]]\nafter #tag"), "the embed's line is followed by the file's next line")
        XCTAssertTrue(fixture.editor.hasUnsavedEdits, "the typing is an edit; the thumbnail's going is not")

        // Undo of the typing makes the embed resolve again: the thumbnail comes back, below it.
        fixture.textView.breakUndoCoalescing()
        try XCTUnwrap(fixture.textView.undoManager).undo()
        XCTAssertEqual(fixture.editor.text, Self.picsBody)
        await waitUntil("the thumbnail is back") { fixture.thumbnails.count == 3 }
        XCTAssertTrue(fixture.shown.contains("![[one.png]]\(Self.run)\nafter #tag"))
        XCTAssertEqual(fixture.targets.first, "one.png")
    }

    func testE9_deletingTheEmbedTextLeavesNoThumbnailBehind() async throws {
        let fixture = try await showPics()
        let embed = fixture.location(of: "![[one.png]]")
        fixture.textView.setSelectedRange(NSRange(location: embed, length: 12))
        fixture.textView.delete(nil)
        await waitUntil("the thumbnail is gone") { fixture.thumbnails.count == 2 }
        XCTAssertEqual(fixture.editor.text, Self.picsBody(withFirstEmbed: ""))
        XCTAssertTrue(fixture.shown.contains("# Pics\n\n\nafter #tag"), "an empty line, no attachment line")
    }

    func testE9_typingAnEmbedThatResolvesAddsAThumbnailOnceTheImageIsKnown() async throws {
        let fixture = try await showPics()
        let end = (fixture.shown as NSString).length
        fixture.type("![[one.png]]", at: end)
        XCTAssertEqual(fixture.thumbnails.count, 3, "nothing is reserved before the image is known")
        await waitUntil("a fourth thumbnail") { fixture.thumbnails.count == 4 }
        XCTAssertTrue(fixture.shown.hasSuffix("![[one.png]]\(Self.run)"), "directly below the typed embed")
        XCTAssertEqual(fixture.editor.text, Self.picsBody + "![[one.png]]")
        // Typing the embed of a missing file, then fixing the name, shows one once it resolves.
        fixture.type("\n![[tal.png]]", at: (fixture.shown as NSString).length)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.thumbnails.count, 4, "a target that names nothing gets none")
        fixture.type("l", at: (fixture.shown as NSString).length - 6)
        await waitUntil("a fifth thumbnail") { fixture.thumbnails.count == 5 }
        XCTAssertTrue(fixture.shown.hasSuffix("![[tall.png]]\(Self.run)"))
        XCTAssertEqual(fixture.targets.last, "tall.png")
    }

    func testE9_movingAnEmbedIntoACodeBlockRemovesItsThumbnail() async throws {
        let fixture = try await showPics()
        // A fence opened above the tall/tiny line and closed below it puts both embeds in code.
        let line = fixture.location(of: "![[tall.png]]")
        fixture.type("```\n", at: line)
        let after = fixture.location(of: "![[tiny.png]]") + 13
        // The run below the line begins at `after`; the closing fence goes on the line after it.
        let closing = fixture.editor.attachmentRanges.first { $0.location == after }.map(NSMaxRange) ?? after
        fixture.type("\n```", at: closing)
        await waitUntil("the code block's thumbnails are gone") { fixture.thumbnails.count == 1 }
        XCTAssertEqual(fixture.targets, ["one.png"])
        XCTAssertTrue(fixture.editor.text.contains("```\n![[tall.png]] and ![[tiny.png]]\n```"))
    }

    func testE9_anAttachmentThatIsNotAThumbnailIsLeftAlone() async throws {
        let fixture = try await showPics()
        let plain = NSTextAttachment()
        plain.image = NSImage(size: NSSize(width: 10, height: 10))
        fixture.editor.addAttachment(plain, belowLineContaining: fixture.location(of: "after #tag"))
        XCTAssertEqual(fixture.editor.attachmentRanges.count, 3)
        fixture.type(" more", at: fixture.location(of: "#tag") + 4)
        fixture.editor.thumbnails.reconcileNow()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.editor.attachmentRanges.count, 3, "the reconciliation manages thumbnails only")
        XCTAssertTrue(fixture.shown.contains("after #tag more\(Self.run)\n"))
    }

    // MARK: - Not in the file (E-9, E-4, E-5)

    func testE9_theSavedFileNeverHoldsAThumbnail() async throws {
        let fixture = try await showPics()
        fixture.type(" more", at: fixture.location(of: "#tag") + 4)
        try await saveAfter(fixture) { fixture.clock.advance(by: EditorController.autosaveDelay) }
        let expected = Self.picsBody.replacingOccurrences(of: "after #tag", with: "after #tag more")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Pics.md"), encoding: .utf8), expected)
        XCTAssertEqual(fixture.editor.text, expected)
        XCTAssertEqual(fixture.thumbnails.count, 3, "the thumbnails survive the edit and the save")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
    }

    // MARK: - Clicks (E-9)

    func testE9_aClickOnAThumbnailOpensTheImageWithTheDefaultApplication() async throws {
        let fixture = try await showPics()
        var opened: [URL] = []
        fixture.controller.openFile = { url in
            opened.append(url)
            return true
        }
        var reported: [(LinkTarget, URL?)] = []
        fixture.controller.onOpenFile = { target, url in reported.append((target, url)) }
        fixture.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        let caret = fixture.location(of: "after")
        fixture.textView.setSelectedRange(NSRange(location: caret, length: 0))

        let (index, one) = try XCTUnwrap(fixture.thumbnails.first)
        try click(onCharacterAt: index, in: fixture)
        XCTAssertEqual(opened, [root.appendingPathComponent("i/one.png")])
        XCTAssertEqual(reported.map(\.0), [LinkTarget(text: "one.png", isEmbed: true)])
        XCTAssertEqual(reported.first?.1, one.url)
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: caret, length: 0), "the click is consumed")
        XCTAssertNil(fixture.controller.inlineMessage)

        // A click on the text is the text view's own: nothing opens. (Asked of the handler
        // directly: a mouse-down the text view keeps runs a tracking loop that waits for a
        // mouse-up the test process never delivers.)
        XCTAssertFalse(fixture.controller.clickInEditor(at: fixture.location(of: "after") + 1))
        XCTAssertFalse(fixture.controller.openThumbnail(at: fixture.location(of: "![[one.png]]")))
        XCTAssertEqual(opened.count, 1)

        // A file the system will not open says so under the search field.
        fixture.controller.openFile = { _ in false }
        try click(onCharacterAt: index, in: fixture)
        XCTAssertEqual(fixture.controller.inlineMessage, "\u{201C}one.png\u{201D} could not be opened.")
        XCTAssertEqual(reported.count, 2)
        XCTAssertNil(reported.last?.1)
    }

    // MARK: - Plain hover (ED-12)

    /// ADR-0021: with no modifier held the pointer over a thumbnail is the pointing hand, since
    /// a plain click opens the image, with no underline; over the embed's text and the prose
    /// around it the I-beam is back (the embed is a link, which needs Cmd).
    func testED12_plainHoverHandOverThumbnail() async throws {
        // Tall enough that the thumbnail, at its own 480 by 320 points, and the line after it
        // are both in view: `firstRect` answers nothing for text scrolled out of sight.
        let fixture = try await showPics(size: NSSize(width: 800, height: 1000))
        NSCursor.arrow.set()
        defer { NSCursor.arrow.set() }
        let (index, _) = try XCTUnwrap(fixture.thumbnails.first)
        let embed = fixture.location(of: "![[one.png]]") + 4
        let after = fixture.location(of: "after") + 1

        try moveMouse(to: try centre(ofCharacterAt: index, in: fixture), flags: [], in: fixture)
        XCTAssertTrue(fixture.textView.hoversClickTarget)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "over the thumbnail")
        XCTAssertNil(fixture.textView.hoveredLinkRange, "no link hovers")
        XCTAssertNil(
            fixture.textView.editorLayoutManager.temporaryAttribute(
                .underlineStyle, atCharacterIndex: index, effectiveRange: nil),
            "no underline")
        try moveMouse(to: try centre(ofCharacterAt: index, in: fixture), flags: [], in: fixture)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "a second move over it keeps the hand")

        try moveMouse(to: try centre(ofCharacterAt: after, in: fixture), flags: [], in: fixture)
        XCTAssertFalse(fixture.textView.hoversClickTarget)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "off the thumbnail the I-beam is back")

        try moveMouse(to: try centre(ofCharacterAt: index, in: fixture), flags: [], in: fixture)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
        try moveMouse(to: try centre(ofCharacterAt: embed, in: fixture), flags: [], in: fixture)
        XCTAssertFalse(fixture.textView.hoversClickTarget, "the embed's text is a link, not a plain click target")
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
        XCTAssertFalse(fixture.editor.hasUnsavedEdits, "hovering is not an edit")
    }

    /// The window point at the centre of the character at `index`, laid out first.
    private func centre(ofCharacterAt index: Int, in fixture: Fixture) throws -> NSPoint {
        let textView = fixture.textView
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, "the character has been laid out")
        let windowRect = fixture.window.convertFromScreen(screenRect)
        return NSPoint(x: windowRect.midX, y: windowRect.midY)
    }

    /// The pointer moving to `point` with `flags` held, as the editor's tracking area reports it.
    private func moveMouse(to point: NSPoint, flags: NSEvent.ModifierFlags, in fixture: Fixture) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        fixture.textView.mouseMoved(with: event)
    }

    /// Sends a plain click on the character at `index` of the editor's text: a mouse-down then
    /// a mouse-up at the character's centre, delivered to the editor as `NSWindow.sendEvent`
    /// would deliver them.
    private func click(onCharacterAt index: Int, in fixture: Fixture) throws {
        let textView = fixture.textView
        // The editor's layout manager lays out lazily (ED-8): the character's rect is an
        // estimate until its line has been laid out.
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
        }
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, "the character has been laid out")
        let windowRect = fixture.window.convertFromScreen(screenRect)
        let point = NSPoint(x: windowRect.midX, y: windowRect.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { textView.mouseDown(with: event) } else { textView.mouseUp(with: event) }
        }
    }

    // MARK: - The cache (PF-8, X-2)

    func testPF8_thumbnailsAreDecodedOffTheMainThreadOnceAndSharedWithTheList() async throws {
        let fixture = try await showPics()
        XCTAssertIdentical(fixture.editor.thumbnails.cache, fixture.controller.listController.thumbnails)
        XCTAssertEqual(Set(fixture.decodes.paths), ["one.png", "tall.png", "tiny.png"], "each image decoded once")
        XCTAssertFalse(fixture.decodes.anyOnMain, "never on the main thread")
        let decodes = fixture.decodes.count

        // X-2: the note reread from disk shows its thumbnails again, from the cache.
        fixture.editor.reloadFromDisk()
        await waitUntil("editor reloaded") { fixture.editor.body != nil }
        await waitUntil("thumbnails back after reload") { fixture.thumbnails.count == 3 }
        XCTAssertEqual(fixture.decodes.count, decodes, "served from the cache")

        // Switching away and back likewise.
        try await show(other, in: fixture)
        XCTAssertEqual(fixture.thumbnails.count, 0)
        XCTAssertEqual(fixture.editor.text, Self.otherBody)
        try await show(pics, in: fixture)
        await waitUntil("thumbnails back after switching") { fixture.thumbnails.count == 3 }
        XCTAssertEqual(fixture.decodes.count, decodes)
    }

    // MARK: - V-1 snapshot

    func testV1_rendersTheEditorWithThumbnailsBelowTheirEmbeds() async throws {
        let fixture = try await showPics(size: NSSize(width: 800, height: 640))
        // The list is short, so the editor has most of the height; pull the split up further.
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-thumbnails")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    /// E-9 (ADR-0021): a small, a Retina, a wide and a tall image fitted to the editor, each
    /// at its sharp pixel size before the capture.
    func testV1_rendersTheEditorWithWideTallAndSmallImagesFitted() async throws {
        let fixture = try await showSizes(size: NSSize(width: 800, height: 720))
        for (_, thumbnail) in fixture.thumbnails { await waitUntilSharp(thumbnail, in: fixture) }
        var written = try writeWindowSnapshots(of: fixture.controller, named: "editor-thumbnail-fit")
        // The same after the window is made narrower: refitted and redrawn, sharp again.
        fixture.window.setContentSize(NSSize(width: 520, height: 720))
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        for (_, thumbnail) in fixture.thumbnails { await waitUntilSharp(thumbnail, in: fixture) }
        written += try writeWindowSnapshots(of: fixture.controller, named: "editor-thumbnail-fit-narrow")
        XCTAssertEqual(written.count, 4)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }
}
