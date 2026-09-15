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

    /// Pixel sizes of the generated images: `one` is 3:2 and fills the 240 by 160 box exactly
    /// at 2x (and is shrunk to it at 1x); `tall` is 1:4 and is capped by the height at either
    /// scale; `tiny` is smaller than the box at either scale and is never enlarged.
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

    func testE9_thumbnailsAreAtMost240By160AndKeepTheImagesProportions() async throws {
        let fixture = try await showPics()
        let bounds = Dictionary(
            uniqueKeysWithValues: fixture.thumbnails.map { ($0.attachment.target, $0.attachment.bounds.size) })
        let one = try XCTUnwrap(bounds["one.png"])
        XCTAssertEqual(one.width, 240, accuracy: 0.01, "3:2 fills the box's width at 1x and 2x alike")
        XCTAssertEqual(one.height, 160, accuracy: 0.01)
        let tall = try XCTUnwrap(bounds["tall.png"])
        XCTAssertEqual(tall.height, 160, accuracy: 0.01, "1:4 is capped by the height")
        XCTAssertEqual(tall.width, 40, accuracy: 0.01)
        let tiny = try XCTUnwrap(bounds["tiny.png"])
        XCTAssertLessThanOrEqual(tiny.width, 40, "a small image is never enlarged")
        XCTAssertLessThanOrEqual(tiny.height, 30)
        XCTAssertEqual(tiny.width / tiny.height, 4.0 / 3.0, accuracy: 0.01)
        for size in bounds.values {
            XCTAssertLessThanOrEqual(size.width, EditorThumbnails.maximumSize.width)
            XCTAssertLessThanOrEqual(size.height, EditorThumbnails.maximumSize.height)
        }
        // The rule itself, scale by scale.
        let fit = { (w: CGFloat, h: CGFloat, scale: CGFloat) in
            EditorThumbnails.displaySize(forPixelSize: CGSize(width: w, height: h), scale: scale)
        }
        XCTAssertEqual(fit(480, 320, 2), NSSize(width: 240, height: 160))
        XCTAssertEqual(fit(480, 320, 1), NSSize(width: 240, height: 160))
        XCTAssertEqual(fit(100, 400, 2), NSSize(width: 40, height: 160))
        XCTAssertEqual(fit(40, 30, 2), NSSize(width: 20, height: 15), "natural size at 2x")
        XCTAssertEqual(fit(40, 30, 1), NSSize(width: 40, height: 30), "natural size at 1x")
        let photo = fit(4000, 3000, 2)
        XCTAssertEqual(photo.height, 160, accuracy: 0.001)
        XCTAssertEqual(photo.width, 640.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(fit(0, 0, 2), .zero)
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
}
