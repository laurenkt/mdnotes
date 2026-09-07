import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import UniformTypeIdentifiers
import XCTest

/// Headless smoke tests for images in the editor. I-1: a paste or a drop carrying an image
/// writes it under `i/` and embeds it at the caret; the paste goes through
/// `EditorTextView.paste(_:)` reading a private pasteboard, so the user's clipboard is never
/// touched, and the drop through the view's `NSDraggingDestination` methods with a stand-in
/// dragging session. I-2: Cmd-click or Cmd-Enter on an embed opens the file it names, with the
/// opener replaced so nothing is launched. Every image is a PNG generated here.
@MainActor
final class ImageInsertSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Two spaces between the words: the caret goes between them, so an embed inserted there
    /// has a space either side. The three embeds are I-2's cases: a file under `i/`, a file by
    /// path, and a name no file has.
    private static let alphaBody = "before  after ![[pic.png]] ![[assets/other.png]] ![[missing.png]]\n"
    private static let caret = 7

    private let alpha = NoteID(relativePath: "Alpha.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.alphaBody.utf8).write(to: root.appendingPathComponent("Alpha.md"))
        try write(Self.generatedPNG(seed: 1), at: "i/pic.png")
        try write(Self.generatedPNG(seed: 2), at: "assets/other.png")
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
        var textView: EditorTextView { controller.mainView.textView }
    }

    /// A laid-out window with a ready library attached, Alpha shown in the editor and the
    /// editor focused with its caret between the two spaces.
    private func makeFixtureShowingAlpha() async throws -> Fixture {
        let clock = ManualAutosaveClock()
        let controller = makeMainWindowController(autosaveClock: clock)
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [alpha], "images are not notes (L-6)")
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.listController.select(alpha))
        await waitUntil("editor shows Alpha") {
            controller.editorController.noteID == self.alpha && controller.editorController.body != nil
        }
        XCTAssertEqual(controller.mainView.textView.string, Self.alphaBody)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        controller.mainView.textView.setSelectedRange(NSRange(location: Self.caret, length: 0))
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

    /// A small opaque PNG whose pixels depend on `seed`, so two generated images differ.
    private static func generatedPNG(seed: Int, width: Int = 6, height: Int = 4) throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<height {
            for x in 0..<width {
                let shade = CGFloat((x * 40 + y * 60 + seed * 30) % 256) / 255
                rep.setColor(
                    NSColor(deviceRed: shade, green: 1 - shade, blue: CGFloat(seed % 2), alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// The same image as TIFF, which is what most apps put on the clipboard.
    private static func generatedTIFF(seed: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try generatedPNG(seed: seed)))
        return try XCTUnwrap(rep.tiffRepresentation)
    }

    private func write(_ data: Data, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Main-actor box so a pasteboard can ride inside a `@Sendable` teardown block.
    @MainActor
    private final class PasteboardBox {
        let pasteboard: NSPasteboard
        init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    }

    /// A private pasteboard, released at teardown, so the general one is never touched.
    private func makePasteboard() -> NSPasteboard {
        let box = PasteboardBox(NSPasteboard(name: NSPasteboard.Name("MDNotes.tests.\(UUID().uuidString)")))
        box.pasteboard.clearContents()
        addTeardownBlock { await MainActor.run { box.pasteboard.releaseGlobally() } }
        return box.pasteboard
    }

    private func pasteboard(holding data: Data, as type: NSPasteboard.PasteboardType) -> NSPasteboard {
        let pasteboard = makePasteboard()
        pasteboard.setData(data, forType: type)
        return pasteboard
    }

    private func pasteboard(holdingFile url: URL) -> NSPasteboard {
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
        return pasteboard
    }

    /// Every file under `i/`, by name.
    private func storedImages() throws -> [String] {
        let folder = root.appendingPathComponent("i", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func storedImage(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent("i/\(name)"))
    }

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    /// Arms `onInsertImage` to report the next settled paste or drop.
    private func expectInsert(_ fixture: Fixture) -> (XCTestExpectation, () -> Result<String, any Error>?) {
        let settled = expectation(description: "image insert settled")
        var reported: Result<String, any Error>?
        fixture.controller.onInsertImage = { outcome in
            reported = outcome
            settled.fulfill()
        }
        return (settled, { reported })
    }

    /// Pastes an image from a private pasteboard through `paste(_:)` and waits for it to settle,
    /// returning the name of the file written.
    private func paste(_ pasteboard: NSPasteboard, into fixture: Fixture) async throws -> String {
        let (settled, reported) = expectInsert(fixture)
        fixture.textView.pasteboard = pasteboard
        fixture.textView.paste(nil)
        await fulfillment(of: [settled], timeout: 10)
        return try XCTUnwrap(reported()).get()
    }

    /// The name I-1 gives an image stored now, without its extension. Two calls a second apart
    /// bracket the name a paste in between produced.
    private func timestampNow() -> String { ImageStore.timestamp(for: Date()) }

    private func assertIsFreshName(_ name: String, extension ext: String, between before: String, and after: String) {
        XCTAssertTrue(name.hasSuffix(".\(ext)"), name)
        let stem = String(name.dropLast(ext.count + 1))
        XCTAssertNotNil(stem.wholeMatch(of: /\d{8}-\d{6}(-\d+)?/), "yyyyMMdd-HHmmss: \(name)")
        XCTAssertTrue(before <= stem && String(stem.prefix(15)) <= after, "\(before) <= \(stem) <= \(after)")
    }

    /// The point, in window coordinates, over the left edge of the character at `index`, once
    /// the text has been laid out.
    private func windowPoint(atCharacter index: Int, in fixture: Fixture) -> NSPoint {
        let textView = fixture.textView
        if let layoutManager = textView.textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, "the character has been laid out")
        let windowRect = fixture.window.convertFromScreen(screenRect)
        return NSPoint(x: windowRect.minX + 1, y: windowRect.midY)
    }

    /// Sends a Cmd-click on the character at `index` as `LinkOpeningSmokeTests` does: a
    /// mouse-down then a mouse-up at the character's centre, delivered to the editor.
    private func commandClick(onCharacterAt index: Int, in fixture: Fixture) throws {
        let textView = fixture.textView
        if let layoutManager = textView.textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, "the character has been laid out")
        let windowRect = fixture.window.convertFromScreen(screenRect)
        let point = NSPoint(x: windowRect.midX, y: windowRect.midY)
        XCTAssertIdentical(fixture.window.contentView?.hitTest(point), textView, "the point is over the editor")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { textView.mouseDown(with: event) } else { textView.mouseUp(with: event) }
        }
    }

    /// An index strictly inside the first `needle` in Alpha's body: past its opening brackets.
    private func inside(_ needle: String) -> Int {
        let range = (Self.alphaBody as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\(needle) is in the fixture")
        return range.location + 3
    }

    /// Arms `onOpenFile` and replaces the opener with a recorder.
    private func expectOpen(_ fixture: Fixture) -> (XCTestExpectation, () -> (LinkTarget, URL?)?, () -> [URL]) {
        let settled = expectation(description: "file open settled")
        var reported: (LinkTarget, URL?)?
        var opened: [URL] = []
        fixture.controller.openFile = { url in
            opened.append(url)
            return true
        }
        fixture.controller.onOpenFile = { target, url in
            reported = (target, url)
            settled.fulfill()
        }
        return (settled, { reported }, { opened })
    }

    /// A drag over the editor carrying `pasteboard`, at `location` in window coordinates.
    @MainActor
    private final class ImageDrag: NSObject, @MainActor NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingLocation: NSPoint
        let draggingDestinationWindow: NSWindow?

        init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
            draggingPasteboard = pasteboard
            draggingLocation = location
            draggingDestinationWindow = window
        }

        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
    }

    // MARK: I-1 pasting image data writes a PNG under i/ and embeds it at the caret

    func testI1_pastingPNGDataWritesItUnderIAndInsertsTheEmbedAtTheCaret() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let png = try Self.generatedPNG(seed: 3)
        XCTAssertEqual(try storedImages(), ["pic.png"])
        let before = timestampNow()

        let name = try await paste(pasteboard(holding: png, as: .png), into: fixture)
        let after = timestampNow()
        assertIsFreshName(name, extension: "png", between: before, and: after)
        XCTAssertEqual(try storedImages(), [name, "pic.png"].sorted(), "the file, and no temp file beside it")
        XCTAssertEqual(try storedImage(name), png, "PNG data is stored byte for byte")

        let expected = "before ![[\(name)]] after ![[pic.png]] ![[assets/other.png]] ![[missing.png]]\n"
        XCTAssertEqual(fixture.textView.string, expected, "the embed is at the caret")
        let caretAfter = Self.caret + ("![[\(name)]]" as NSString).length
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: caretAfter, length: 0), "caret after the ]]")
        XCTAssertIdentical(fixture.window.firstResponder, fixture.textView, "focus stays in the editor")
        XCTAssertFalse(fixture.editor.linkCompletion.isShowing, "the [[ inserted is not a typed trigger (K-4)")
        XCTAssertNil(fixture.controller.inlineMessage)

        // The embed is an edit like any other: autosaved (E-4) and indexed as a link (K-5).
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(try fileText(alpha), Self.alphaBody, "not written yet")
        fixture.clock.advance(by: EditorController.autosaveDelay)
        await waitUntil("Alpha written") { (try? self.fileText(self.alpha)) == expected }
        await waitUntil("embed indexed") {
            fixture.library.snapshot.links.outgoing(of: self.alpha).contains(LinkTarget(text: name, isEmbed: true))
        }
        XCTAssertEqual(fixture.library.snapshot.entries.map(\.id), [alpha], "the image is not a note (L-6)")
    }

    func testI1_pastingTIFFDataStoresItAsPNG() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let tiff = try Self.generatedTIFF(seed: 4)

        let name = try await paste(pasteboard(holding: tiff, as: .tiff), into: fixture)
        XCTAssertTrue(name.hasSuffix(".png"), name)
        let stored = try storedImage(name)
        XCTAssertNotEqual(stored, tiff, "converted, not copied")
        XCTAssertEqual(stored.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "a PNG signature")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: stored))
        XCTAssertEqual(rep.pixelsWide, 6, "the same image")
        XCTAssertEqual(rep.pixelsHigh, 4)
        XCTAssertTrue(fixture.textView.string.hasPrefix("before ![[\(name)]] after"))
    }

    func testI1_pastingJPEGDataKeepsItAsJPEG() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Self.generatedPNG(seed: 5)))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        let type = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

        let name = try await paste(pasteboard(holding: jpeg, as: type), into: fixture)
        XCTAssertTrue(name.hasSuffix(".jpg"), name)
        XCTAssertEqual(try storedImage(name), jpeg, "lossy data is not re-encoded")
    }

    func testI1_pastingAnImageFileCopiesItUnderItsOwnExtension() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let png = try Self.generatedPNG(seed: 6)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("mdnotes-\(UUID().uuidString).PNG")
        try png.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let name = try await paste(pasteboard(holdingFile: outside), into: fixture)
        XCTAssertTrue(name.hasSuffix(".png"), "the extension, lowercased: \(name)")
        XCTAssertEqual(try storedImage(name), png)
        XCTAssertEqual(try Data(contentsOf: outside), png, "the original is untouched")
        XCTAssertTrue(fixture.textView.string.hasPrefix("before ![[\(name)]] after"))
    }

    func testI1_twoPastesGetTwoNamesAndTwoFiles() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let first = try await paste(pasteboard(holding: try Self.generatedPNG(seed: 7), as: .png), into: fixture)
        let second = try await paste(pasteboard(holding: try Self.generatedPNG(seed: 8), as: .png), into: fixture)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try storedImages(), [first, second, "pic.png"].sorted())
        XCTAssertNotEqual(try storedImage(first), try storedImage(second))
        XCTAssertTrue(
            fixture.textView.string.hasPrefix("before ![[\(first)]]![[\(second)]] after"), fixture.textView.string)
    }

    func testI1_aPasteWithoutAnImageIsTheTextViewsOwn() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        var inserts = 0
        fixture.controller.onInsertImage = { _ in inserts += 1 }
        let text = makePasteboard()
        text.setString("plain text", forType: .string)
        XCTAssertNil(ImagePasteboard.image(on: text))
        XCTAssertFalse(ImagePasteboard.hasImage(on: text))
        let textFile = FileManager.default.temporaryDirectory.appendingPathComponent("mdnotes-\(UUID().uuidString).txt")
        try Data("not an image".utf8).write(to: textFile)
        defer { try? FileManager.default.removeItem(at: textFile) }
        XCTAssertNil(ImagePasteboard.image(on: pasteboard(holdingFile: textFile)), "a file that is not an image")
        XCTAssertNil(ImagePasteboard.image(on: makePasteboard()), "an empty pasteboard")

        // Through the view: a text-only pasteboard never reaches the handler.
        let drag = ImageDrag(
            pasteboard: text, location: windowPoint(atCharacter: Self.caret, in: fixture), window: fixture.window)
        XCTAssertFalse(fixture.textView.prepareForDragOperation(drag) && inserts > 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(inserts, 0)
        XCTAssertEqual(try storedImages(), ["pic.png"])
    }

    func testI1_withNoNoteShownAnImageIsNotTaken() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        var inserts = 0
        fixture.controller.onInsertImage = { _ in inserts += 1 }
        fixture.editor.clear()
        XCTAssertNil(fixture.editor.noteID)
        XCTAssertFalse(fixture.textView.isEditable)

        XCTAssertFalse(fixture.controller.insertImage(.data(try Self.generatedPNG(seed: 9), fileExtension: "png")))
        fixture.textView.pasteboard = pasteboard(holding: try Self.generatedPNG(seed: 9), as: .png)
        fixture.textView.paste(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(inserts, 0)
        XCTAssertEqual(try storedImages(), ["pic.png"], "nothing was written")
        XCTAssertEqual(fixture.textView.string, "")
    }

    func testI1_aWriteThatFailsShowsTheReasonAndInsertsNothing() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        // A file where the folder must go: i/ cannot be created.
        try FileManager.default.removeItem(at: root.appendingPathComponent("i"))
        try Data("in the way".utf8).write(to: root.appendingPathComponent("i"))
        let (settled, reported) = expectInsert(fixture)

        fixture.textView.pasteboard = pasteboard(holding: try Self.generatedPNG(seed: 10), as: .png)
        fixture.textView.paste(nil)
        await fulfillment(of: [settled], timeout: 10)
        guard case .failure = try XCTUnwrap(reported()) else { return XCTFail("the write failed") }
        XCTAssertNotNil(fixture.controller.inlineMessage)
        XCTAssertFalse(fixture.controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(fixture.textView.string, Self.alphaBody, "nothing was inserted")
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("i"), encoding: .utf8), "in the way")
    }

    func testI1_anImageThatArrivesAfterTheNoteChangedIsKeptButNotInserted() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let (settled, reported) = expectInsert(fixture)
        XCTAssertTrue(fixture.controller.insertImage(.data(try Self.generatedPNG(seed: 11), fileExtension: "png")))
        fixture.editor.clear()
        await fulfillment(of: [settled], timeout: 10)
        let name = try XCTUnwrap(reported()).get()
        XCTAssertEqual(try storedImages(), [name, "pic.png"].sorted(), "the file is there")
        XCTAssertEqual(fixture.textView.string, "", "but nothing was inserted into an editor showing no note")
        XCTAssertEqual(try fileText(alpha), Self.alphaBody)
    }

    // MARK: I-1 dropping an image inserts the embed at the drop point

    func testI1_droppingImageDataInsertsTheEmbedAtTheDropPoint() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let png = try Self.generatedPNG(seed: 12)
        let drag = ImageDrag(
            pasteboard: pasteboard(holding: png, as: .png), location: windowPoint(atCharacter: Self.caret, in: fixture),
            window: fixture.window)
        XCTAssertTrue(fixture.textView.registeredDraggedTypes.contains(.png), "the editor accepts image drags")
        XCTAssertTrue(fixture.textView.registeredDraggedTypes.contains(.fileURL), "and file drags")
        XCTAssertEqual(fixture.textView.draggingEntered(drag), .copy)
        XCTAssertEqual(fixture.textView.draggingUpdated(drag), .copy)
        XCTAssertTrue(fixture.textView.prepareForDragOperation(drag))
        let (settled, reported) = expectInsert(fixture)

        XCTAssertTrue(fixture.textView.performDragOperation(drag))
        await fulfillment(of: [settled], timeout: 10)
        let name = try XCTUnwrap(reported()).get()
        XCTAssertEqual(try storedImage(name), png)
        XCTAssertTrue(
            fixture.textView.string.hasPrefix("before ![[\(name)]] after"), "at the drop point, not the old caret")
    }

    func testI1_droppingAnImageFileCopiesIt() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let png = try Self.generatedPNG(seed: 13)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("mdnotes-\(UUID().uuidString).png")
        try png.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let drag = ImageDrag(
            pasteboard: pasteboard(holdingFile: outside), location: windowPoint(atCharacter: Self.caret, in: fixture),
            window: fixture.window)
        XCTAssertEqual(fixture.textView.draggingEntered(drag), .copy)
        let (settled, reported) = expectInsert(fixture)

        XCTAssertTrue(fixture.textView.performDragOperation(drag))
        await fulfillment(of: [settled], timeout: 10)
        let name = try XCTUnwrap(reported()).get()
        XCTAssertEqual(try storedImage(name), png)
        XCTAssertEqual(try Data(contentsOf: outside), png)
        XCTAssertTrue(fixture.textView.string.hasPrefix("before ![[\(name)]] after"))
    }

    func testI1_aDropIsRefusedWhileNoNoteIsShown() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        fixture.editor.clear()
        let drag = ImageDrag(
            pasteboard: pasteboard(holding: try Self.generatedPNG(seed: 14), as: .png),
            location: NSPoint(x: 100, y: 100),
            window: fixture.window)
        XCTAssertEqual(fixture.textView.draggingEntered(drag), [])
        XCTAssertEqual(fixture.textView.draggingUpdated(drag), [])
        XCTAssertEqual(try storedImages(), ["pic.png"])
    }

    // MARK: I-2 Cmd-click on an image link opens the file with the default application

    func testI2_commandClickOnAnEmbedOpensTheFileUnderI() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let (settled, reported, opened) = expectOpen(fixture)
        var noteOpens = 0
        fixture.controller.onOpenLink = { _, _ in noteOpens += 1 }

        try commandClick(onCharacterAt: inside("![[pic.png]]") + 1, in: fixture)
        await fulfillment(of: [settled], timeout: 10)
        let expected = root.appendingPathComponent("i/pic.png", isDirectory: false)
        XCTAssertEqual(reported()?.0, LinkTarget(text: "pic.png", isEmbed: true))
        XCTAssertEqual(reported()?.1?.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertEqual(opened().map(\.standardizedFileURL), [expected.standardizedFileURL])
        XCTAssertEqual(noteOpens, 0, "an embed is not a note (K-1)")
        XCTAssertEqual(fixture.editor.noteID, alpha, "the editor stays on Alpha")
        XCTAssertEqual(fixture.controller.listController.selectedID, alpha)
        XCTAssertEqual(fixture.library.snapshot.entries.map(\.id), [alpha], "no note was created")
        XCTAssertNil(fixture.controller.inlineMessage)
    }

    func testI2_commandEnterWithTheCaretInAnEmbedByPathOpensTheFileRelativeToTheRoot() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let (settled, reported, opened) = expectOpen(fixture)
        fixture.textView.setSelectedRange(NSRange(location: inside("![[assets/other.png]]") + 1, length: 0))

        XCTAssertTrue(fixture.controller.openLinkAtCaret())
        await fulfillment(of: [settled], timeout: 10)
        let expected = root.appendingPathComponent("assets/other.png", isDirectory: false).standardizedFileURL
        XCTAssertEqual(reported()?.0, LinkTarget(text: "assets/other.png", isEmbed: true))
        XCTAssertEqual(reported()?.1?.standardizedFileURL, expected)
        XCTAssertEqual(opened().map(\.standardizedFileURL), [expected])
    }

    func testI2_anEmbedWhoseFileIsMissingOpensNothingAndSaysSo() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let (settled, reported, opened) = expectOpen(fixture)
        fixture.textView.setSelectedRange(NSRange(location: inside("![[missing.png]]") + 1, length: 0))

        XCTAssertTrue(fixture.controller.openLinkAtCaret(), "the key is consumed")
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertEqual(reported()?.0, LinkTarget(text: "missing.png", isEmbed: true))
        XCTAssertNil(reported()?.1)
        XCTAssertEqual(opened(), [])
        let message = try XCTUnwrap(fixture.controller.inlineMessage)
        XCTAssertTrue(message.contains("missing.png"), message)
        XCTAssertFalse(fixture.controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(fixture.library.snapshot.entries.map(\.id), [alpha], "no missing.png.md was created")
        XCTAssertEqual(try storedImages(), ["pic.png"])
    }

    func testI2_aFileTheSystemWillNotOpenSaysSo() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let settled = expectation(description: "file open settled")
        var reported: (LinkTarget, URL?)?
        fixture.controller.openFile = { _ in false }
        fixture.controller.onOpenFile = { target, url in
            reported = (target, url)
            settled.fulfill()
        }
        fixture.textView.setSelectedRange(NSRange(location: inside("![[pic.png]]") + 1, length: 0))

        XCTAssertTrue(fixture.controller.openLinkAtCaret())
        await fulfillment(of: [settled], timeout: 10)
        XCTAssertNil(reported?.1)
        XCTAssertTrue(try XCTUnwrap(fixture.controller.inlineMessage).contains("pic.png"))
    }

    func testI2_aFreshlyPastedImageOpensFromItsEmbed() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let name = try await paste(pasteboard(holding: try Self.generatedPNG(seed: 15), as: .png), into: fixture)
        let (settled, reported, opened) = expectOpen(fixture)
        fixture.textView.setSelectedRange(NSRange(location: Self.caret + 4, length: 0))
        XCTAssertEqual(fixture.editor.linkTargetAtCaret(), LinkTarget(text: name, isEmbed: true))

        XCTAssertTrue(fixture.controller.openLinkAtCaret())
        await fulfillment(of: [settled], timeout: 10)
        let expected = root.appendingPathComponent("i/\(name)", isDirectory: false).standardizedFileURL
        XCTAssertEqual(reported()?.1?.standardizedFileURL, expected)
        XCTAssertEqual(opened().map(\.standardizedFileURL), [expected])
    }
}
