import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the editor's attachment plumbing (E-9, ADR-0012): display-only
/// thumbnail attachments live in the text storage but not in the file, so every reader of the
/// view's text goes through `EditorText`. The attachments are added through the controller's
/// primitives, as the inline thumbnails will add them; the edits go through the real text view
/// and the save through the real library, so a round trip with attachments on show is checked
/// against the bytes on disk.
@MainActor
final class EditorAttachmentSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Two embeds, a tag line between them, and the second embed ending the file without a
    /// line break, so an attachment run below it sits at the very end of the text.
    private static let picsBody = "# Pics\n\n![[i/one.png]]\nafter #tag\n\n![[i/two.png]]"
    /// A file that itself holds the object replacement character an attachment is attached to.
    private static let literalBody = "before \u{FFFC} after #own\n"

    private static let notes: [(path: String, body: String)] = [
        ("Literal.md", literalBody),
        ("Pics.md", picsBody),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let pics = NoteID(relativePath: "Pics.md")
    private let literal = NoteID(relativePath: "Literal.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-attachments-\(UUID().uuidString)", isDirectory: true)
        for (i, note) in Self.notes.enumerated() {
            let url = root.appendingPathComponent(note.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(note.body.utf8).write(to: url)
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
        var textView: EditorTextView { controller.mainView.textView }
        var storage: NSTextStorage { textView.textStorage ?? NSTextStorage() }
        var table: NSTableView { controller.mainView.tableView }

        /// The storage's text, attachment characters included.
        var shown: String { storage.string }

        func style(at location: Int) -> EditorStyler.TokenStyle? {
            let value = storage.attributes(at: location, effectiveRange: nil)[EditorStyler.tokenAttribute] as? String
            return value.flatMap(EditorStyler.TokenStyle.init)
        }

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
    private func show(_ id: NoteID, in fixture: Fixture) async throws {
        let row = try XCTUnwrap(fixture.controller.listController.results.firstIndex { $0.id == id })
        fixture.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntil("editor shows \(id.relativePath)") {
            fixture.editor.noteID == id && fixture.editor.body != nil
        }
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

    /// A thumbnail-sized attachment with an image to draw.
    private func makeAttachment() -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 120, height: 80))
        return attachment
    }

    /// Adds an attachment below the line containing the first occurrence of `needle`.
    private func attach(below needle: String, in fixture: Fixture) {
        fixture.editor.addAttachment(makeAttachment(), belowLineContaining: fixture.location(of: needle))
    }

    /// The Pics note shown with an attachment below each of its embeds.
    private func showPicsWithAttachments() async throws -> Fixture {
        let fixture = try await makeFixture()
        try await show(pics, in: fixture)
        attach(below: "![[i/one.png]]", in: fixture)
        attach(below: "![[i/two.png]]", in: fixture)
        XCTAssertEqual(fixture.editor.attachmentRanges.count, 2)
        return fixture
    }

    private static let run = "\n\u{FFFC}"

    // MARK: - The accessor (E-9)

    func testE9_textLeavesOutAttachmentCharactersTheStorageShows() async throws {
        let fixture = try await showPicsWithAttachments()
        XCTAssertEqual(fixture.editor.text, Self.picsBody)
        XCTAssertEqual(
            fixture.shown, "# Pics\n\n![[i/one.png]]\(Self.run)\nafter #tag\n\n![[i/two.png]]\(Self.run)",
            "each run is a line of its own directly below its embed")
        XCTAssertEqual(
            fixture.editor.attachmentRanges,
            [NSRange(location: 22, length: 2), NSRange(location: 51, length: 2)])
        // The marker sits on both characters of a run, and on nothing else.
        for run in fixture.editor.attachmentRanges {
            for index in run.location..<NSMaxRange(run) {
                XCTAssertNotNil(
                    fixture.storage.attribute(EditorText.displayOnlyAttribute, at: index, effectiveRange: nil))
            }
            XCTAssertNil(
                fixture.storage.attribute(EditorText.displayOnlyAttribute, at: run.location - 1, effectiveRange: nil))
        }
    }

    func testE9_aFilesOwnObjectReplacementCharacterIsNotStripped() async throws {
        let fixture = try await makeFixture()
        try await show(literal, in: fixture)
        XCTAssertEqual(fixture.editor.text, Self.literalBody)
        XCTAssertTrue(fixture.editor.attachmentRanges.isEmpty, "a U+FFFC without the marker is the file's")
        attach(below: "before", in: fixture)
        XCTAssertEqual(fixture.editor.text, Self.literalBody)
        XCTAssertEqual(fixture.editor.attachmentRanges, [NSRange(location: 19, length: 2)])
        // The file's own tag after its U+FFFC still parses.
        XCTAssertEqual(fixture.editor.tag(at: fixture.location(of: "#own") + 2), "#own")
    }

    // MARK: - Round trip (E-9, E-4, E-5)

    func testE9_roundTripWithAttachmentsPresentLeavesTheFileByteIdentical() async throws {
        let fixture = try await showPicsWithAttachments()
        let url = root.appendingPathComponent("Pics.md")
        let before = try Data(contentsOf: url)
        XCTAssertEqual(before, Data(Self.picsBody.utf8))

        // An edit made and taken back with the attachments on show, then written.
        let end = (fixture.shown as NSString).length
        fixture.type("x", at: end)
        fixture.textView.deleteBackward(nil)
        XCTAssertTrue(fixture.editor.hasUnsavedEdits)
        XCTAssertEqual(fixture.editor.attachmentRanges.count, 2, "the attachments are still on show")
        try await saveAfter(fixture) { fixture.clock.advance(by: EditorController.autosaveDelay) }

        XCTAssertEqual(try Data(contentsOf: url), before, "the file is byte-identical")
        XCTAssertEqual(fixture.editor.text, Self.picsBody)
        XCTAssertEqual(fixture.editor.body, .text(Self.picsBody))
    }

    func testE9_roundTripOfAFileHoldingItsOwnObjectReplacementCharacter() async throws {
        let fixture = try await makeFixture()
        try await show(literal, in: fixture)
        attach(below: "before", in: fixture)
        let url = root.appendingPathComponent("Literal.md")
        let before = try Data(contentsOf: url)
        fixture.type("x", at: 0)
        fixture.textView.deleteBackward(nil)
        try await saveAfter(fixture) { fixture.clock.advance(by: EditorController.autosaveDelay) }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testE9_saveWithAttachmentsWritesOnlyTheFilesText() async throws {
        let fixture = try await showPicsWithAttachments()
        // Typed at the end of the tag line, which sits between the two attachment lines.
        fixture.type(" more", at: fixture.location(of: "#tag") + 4)
        try await saveAfter(fixture) { fixture.clock.advance(by: EditorController.autosaveDelay) }
        let expected = "# Pics\n\n![[i/one.png]]\nafter #tag more\n\n![[i/two.png]]"
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Pics.md"), encoding: .utf8), expected)
        XCTAssertEqual(fixture.editor.text, expected)
        XCTAssertEqual(fixture.editor.attachmentRanges.count, 2, "the attachments survive the edit and the save")
    }

    // MARK: - Copy (E-9)

    func testE9_copyOfASelectionCoveringAttachmentsWritesTheFilesText() async throws {
        let fixture = try await showPicsWithAttachments()
        let pasteboard = makePasteboard()
        fixture.textView.setSelectedRange(NSRange(location: 0, length: (fixture.shown as NSString).length))
        XCTAssertTrue(fixture.textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), Self.picsBody)

        // A selection from inside the first embed's line across its attachment into the tag line.
        let start = fixture.location(of: "one.png")
        let end = fixture.location(of: "#tag") + 4
        fixture.textView.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertTrue(fixture.textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "one.png]]\nafter #tag")
    }

    func testE9_copyWithoutAttachmentsIsTheTextViewsOwn() async throws {
        let fixture = try await makeFixture()
        try await show(pics, in: fixture)
        let pasteboard = makePasteboard()
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 6))
        // `copy:` declares the view's own writable types (the plain string type, for a plain
        // text view) before calling `writeSelection`, which writes only those.
        let types = fixture.textView.writablePasteboardTypes
        pasteboard.declareTypes(types, owner: nil)
        XCTAssertTrue(fixture.textView.writeSelection(to: pasteboard, types: types))
        XCTAssertEqual(pasteboard.string(forType: .string), "# Pics")
    }

    // MARK: - Styler ranges (E-2, E-3, E-9)

    func testE9_stylingLandsOnTheShiftedStorageRangesAndNotOnTheRuns() async throws {
        let fixture = try await showPicsWithAttachments()
        XCTAssertEqual(fixture.style(at: 0), .heading)
        XCTAssertEqual(fixture.style(at: fixture.location(of: "![[i/one.png]]")), .wikilink)
        let tag = fixture.location(of: "#tag")
        XCTAssertEqual(tag, 31, "the tag sits two characters further into the storage than into the file")
        XCTAssertEqual(fixture.style(at: tag), .tag)
        XCTAssertEqual(fixture.style(at: tag + 3), .tag)
        XCTAssertNil(fixture.style(at: tag + 4), "the tag's styling ends where the tag does")
        XCTAssertEqual(fixture.style(at: fixture.location(of: "![[i/two.png]]")), .wikilink)
        for run in fixture.editor.attachmentRanges {
            XCTAssertNil(fixture.style(at: run.location), "an attachment line is styled as nothing")
            XCTAssertNil(fixture.style(at: run.location + 1))
        }
    }

    func testE9_restyleAfterAnEditBelowAnAttachmentUsesTheFilesParagraphs() async throws {
        let fixture = try await showPicsWithAttachments()
        // Typing a second tag after the first, on the line under the first attachment.
        let end = fixture.location(of: "#tag") + 4
        fixture.type(" #new", at: end)
        let new = fixture.location(of: "#new")
        XCTAssertEqual(fixture.style(at: new), .tag)
        XCTAssertEqual(fixture.style(at: new + 3), .tag)
        XCTAssertEqual(fixture.style(at: fixture.location(of: "#tag")), .tag, "the first tag keeps its style")
        // Making the tag line a heading re-styles that paragraph only, over the run below the
        // first embed, which is in the same paragraph.
        fixture.type("# ", at: fixture.location(of: "after"))
        let heading = fixture.location(of: "# after")
        XCTAssertEqual(fixture.style(at: heading), .heading)
        XCTAssertEqual(fixture.style(at: fixture.location(of: "#tag")), .tag, "a heading line's tags keep their colour")
        XCTAssertEqual(fixture.style(at: fixture.location(of: "![[i/two.png]]")), .wikilink)
        XCTAssertEqual(fixture.editor.attachmentRanges.count, 2, "the runs survive the re-style")
        XCTAssertEqual(fixture.editor.text, "# Pics\n\n![[i/one.png]]\n# after #tag #new\n\n![[i/two.png]]")
    }

    // MARK: - Link and tag parsing (K-3, T-4, E-9)

    func testE9_linkAndTagLookupsTakeStorageIndicesPastAttachments() async throws {
        let fixture = try await showPicsWithAttachments()
        let two = fixture.location(of: "![[i/two.png]]")
        XCTAssertEqual(fixture.editor.linkTarget(at: two + 5), LinkTarget(text: "i/two.png", isEmbed: true))
        XCTAssertEqual(fixture.editor.linkTarget(at: two + 14), LinkTarget(text: "i/two.png", isEmbed: true))
        let one = fixture.location(of: "![[i/one.png]]")
        XCTAssertEqual(fixture.editor.linkTarget(at: one + 3), LinkTarget(text: "i/one.png", isEmbed: true))
        // A caret on the thumbnail line is touching the embed above it.
        let firstRun = try XCTUnwrap(fixture.editor.attachmentRanges.first)
        XCTAssertEqual(
            fixture.editor.linkTarget(at: firstRun.location + 1), LinkTarget(text: "i/one.png", isEmbed: true))
        XCTAssertNil(fixture.editor.linkTarget(at: fixture.location(of: "after")))

        let tag = fixture.location(of: "#tag")
        XCTAssertEqual(fixture.editor.tag(at: tag), "#tag")
        XCTAssertEqual(fixture.editor.tag(at: tag + 3), "#tag")
        XCTAssertEqual(fixture.editor.tagRange(at: tag + 1), NSRange(location: tag, length: 4))
        XCTAssertNil(fixture.editor.tag(at: tag + 4))
        XCTAssertNil(fixture.editor.tag(at: firstRun.location + 1), "an attachment character is in no tag")
    }

    // MARK: - Not an edit, not undoable (E-4, E-7, E-9)

    func testE9_addingAndRemovingAttachmentsIsNeitherAnEditNorUndoable() async throws {
        let fixture = try await makeFixture()
        try await show(pics, in: fixture)
        let manager = try XCTUnwrap(fixture.textView.undoManager)
        var saves = 0
        fixture.editor.onSave = { _, _ in saves += 1 }

        // The caret on the tag line follows its character when a run is added above it.
        let tag = fixture.location(of: "#tag")
        fixture.textView.setSelectedRange(NSRange(location: tag, length: 0))
        attach(below: "![[i/one.png]]", in: fixture)
        XCTAssertEqual(fixture.textView.selectedRange().location, tag + 2)
        XCTAssertEqual(fixture.location(of: "#tag"), tag + 2)

        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertFalse(manager.canUndo)
        fixture.clock.advance(by: EditorController.autosaveDelay * 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(saves, 0, "no write is scheduled for an attachment")

        fixture.editor.removeAttachments()
        XCTAssertEqual(fixture.textView.selectedRange().location, tag)
        XCTAssertTrue(fixture.editor.attachmentRanges.isEmpty)
        XCTAssertEqual(fixture.shown, Self.picsBody)
        XCTAssertFalse(fixture.editor.hasUnsavedEdits)
        XCTAssertFalse(manager.canUndo)
        fixture.editor.onSave = nil
    }

    func testE9_removingAttachmentsByRange() async throws {
        let fixture = try await showPicsWithAttachments()
        let runs = fixture.editor.attachmentRanges
        // An empty range outside every run removes nothing.
        fixture.editor.removeAttachments(in: NSRange(location: 0, length: 0))
        XCTAssertEqual(fixture.editor.attachmentRanges, runs)
        // The second embed's line, terminator included, overlaps the run below it.
        let two = fixture.location(of: "![[i/two.png]]")
        fixture.editor.removeAttachments(in: NSRange(location: two, length: 15))
        XCTAssertEqual(fixture.editor.attachmentRanges, [runs[0]])
        // A caret inside the remaining run removes it.
        fixture.editor.removeAttachments(in: NSRange(location: runs[0].location + 1, length: 0))
        XCTAssertTrue(fixture.editor.attachmentRanges.isEmpty)
        XCTAssertEqual(fixture.shown, Self.picsBody)
        XCTAssertEqual(fixture.editor.text, Self.picsBody)
    }

    func testE9_aSecondAttachmentBelowTheSameLineStacksUnderTheFirst() async throws {
        let fixture = try await makeFixture()
        try await show(pics, in: fixture)
        attach(below: "![[i/one.png]]", in: fixture)
        attach(below: "![[i/one.png]]", in: fixture)
        XCTAssertEqual(
            fixture.editor.attachmentRanges, [NSRange(location: 22, length: 4)], "adjacent runs are one range")
        XCTAssertEqual(fixture.editor.text, Self.picsBody)
        // An index on the attachment lines names the embed's line.
        attach(below: "\u{FFFC}", in: fixture)
        XCTAssertEqual(fixture.editor.attachmentRanges, [NSRange(location: 22, length: 6)])
        XCTAssertEqual(fixture.editor.text, Self.picsBody)
    }

    // MARK: - Mapping (E-9)

    func testE9_indexMappingAtRunBoundaries() async throws {
        let fixture = try await showPicsWithAttachments()
        let text = EditorText(storage: fixture.storage)
        // Storage: "# Pics\n\n![[i/one.png]]" is 0..<22, run 22..<24, "\n" 24, "after #tag" 25..<35.
        // File:    "# Pics\n\n![[i/one.png]]" is 0..<22, "\n" 22, "after #tag" 23..<33.
        XCTAssertEqual(text.fileIndex(forStorageIndex: 21), 21)
        XCTAssertEqual(text.fileIndex(forStorageIndex: 22), 22, "the run's start is the run's file position")
        XCTAssertEqual(text.fileIndex(forStorageIndex: 23), 22, "so is its inside")
        XCTAssertEqual(text.fileIndex(forStorageIndex: 24), 22, "the file's line break follows the run")
        XCTAssertEqual(text.fileIndex(forStorageIndex: 25), 23)
        XCTAssertEqual(text.storageIndex(forFileIndex: 22), 22, "a file index at a run maps before the run")
        XCTAssertEqual(text.storageIndex(forFileIndex: 23), 25)
        XCTAssertEqual(
            text.storageRange(forFileRange: NSRange(location: 8, length: 14)), NSRange(location: 8, length: 14))
        XCTAssertEqual(
            text.storageRange(forFileRange: NSRange(location: 8, length: 15)), NSRange(location: 8, length: 17))
        XCTAssertEqual(
            text.fileRange(forStorageRange: NSRange(location: 22, length: 2)), NSRange(location: 22, length: 0))
        XCTAssertEqual(
            text.fileRange(forStorageRange: NSRange(location: 20, length: 6)), NSRange(location: 20, length: 4))
        // Past the second run at the end of the text.
        XCTAssertEqual(text.fileIndex(forStorageIndex: 53), 49)
        XCTAssertEqual(text.storageIndex(forFileIndex: 49), 51)
        XCTAssertEqual(text.units.count, (Self.picsBody as NSString).length)
        XCTAssertEqual(text.string(inStorageRange: NSRange(location: 0, length: 53)), Self.picsBody)
    }

    func testE9_withoutRunsEveryMappingIsTheIdentity() {
        let storage = NSTextStorage(string: "plain \u{FFFC} text")
        let text = EditorText(storage: storage)
        XCTAssertFalse(text.hasDisplayOnlyRuns)
        XCTAssertEqual(text.string, "plain \u{FFFC} text")
        for index in 0...storage.length {
            XCTAssertEqual(text.fileIndex(forStorageIndex: index), index)
            XCTAssertEqual(text.storageIndex(forFileIndex: index), index)
        }
    }

    // MARK: - Pasteboard

    @MainActor
    private final class PasteboardBox {
        let pasteboard: NSPasteboard
        init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    }

    /// A private pasteboard, released at teardown, so the user's clipboard is left alone.
    private func makePasteboard() -> NSPasteboard {
        let box = PasteboardBox(NSPasteboard(name: NSPasteboard.Name("MDNotes.tests.\(UUID().uuidString)")))
        addTeardownBlock { await MainActor.run { box.pasteboard.releaseGlobally() } }
        return box.pasteboard
    }
}
