import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for rich paste in the editor (ED-13, ED-14). Every paste goes through
/// `EditorTextView.paste(_:)` or `pasteAsPlainText(_:)` reading a private pasteboard, so the
/// user's clipboard is never touched, one test per pasteboard type: HTML converts to
/// markdown; RTF converts when there is no HTML; a plain string is pasted as it is; Paste
/// and Match Style pastes the string whatever else is there; image data still goes to `i/`
/// (I-1). What lands is one undoable edit at the caret.
@MainActor
final class PasteSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Two spaces between the words: the caret goes between them, so what is pasted there has
    /// a space either side.
    private static let alphaBody = "before  after\n"
    private static let caret = 7

    private static let html = """
        <html><head><meta charset="utf-8"></head><body>
        <h1>Title</h1>
        <p>Some <b>bold</b> text and <a href="https://example.com/z">a link</a>.</p>
        <ul><li>one</li><li>two</li></ul>
        </body></html>
        """
    private static let htmlMarkdown =
        "# Title\n\nSome **bold** text and [a link](https://example.com/z).\n\n- one\n- two"
    private static let rtf =
        "{\\rtf1\\ansi{\\fonttbl\\f0\\fswiss Helvetica;}\\f0\\fs24 Plain and \\b bold\\b0  text.\\\n}"
    private static let rtfMarkdown = "Plain and **bold** text."
    private static let plain = "Title\nSome bold text and a link.\n- one\n- two"

    private let alpha = NoteID(relativePath: "Alpha.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(Self.alphaBody.utf8).write(to: root.appendingPathComponent("Alpha.md"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
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
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(controller.listController.select(alpha))
        await waitUntil("editor shows Alpha") {
            controller.editorController.noteID == self.alpha && controller.editorController.body != nil
        }
        XCTAssertEqual(controller.editorController.text, Self.alphaBody)
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

    /// A private pasteboard carrying the given forms, as an app that copies rich text puts them
    /// all on at once.
    private func pasteboard(
        html: String? = nil, rtf: String? = nil, string: String? = nil, png: Data? = nil
    ) -> NSPasteboard {
        let pasteboard = makePasteboard()
        if let html { XCTAssertTrue(pasteboard.setString(html, forType: .html)) }
        if let rtf { XCTAssertTrue(pasteboard.setData(Data(rtf.utf8), forType: .rtf)) }
        if let string { XCTAssertTrue(pasteboard.setString(string, forType: .string)) }
        if let png { XCTAssertTrue(pasteboard.setData(png, forType: .png)) }
        return pasteboard
    }

    /// A small opaque PNG.
    private static func generatedPNG(width: Int = 6, height: Int = 4) throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<height {
            for x in 0..<width {
                let shade = CGFloat((x * 40 + y * 60) % 256) / 255
                rep.setColor(NSColor(deviceRed: shade, green: 1 - shade, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Every file under `i/`, by name.
    private func storedImages() throws -> [String] {
        let folder = root.appendingPathComponent("i", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    /// The Edit menu item with `action`, as the menu bar builds it.
    private func editItem(_ action: Selector) throws -> NSMenuItem {
        let edit = try XCTUnwrap(MainMenu.make().mainMenu.items.first { $0.title == MainMenu.editMenuTitle }?.submenu)
        let item = try XCTUnwrap(edit.items.first { $0.action == action }, "an item for \(action)")
        XCTAssertNil(item.target, "sent down the responder chain")
        return item
    }

    /// Asserts `inserted` landed at the caret as one edit: the text around it untouched, the
    /// caret after it, the note dirty, and one undo taking it back out. Leaves the editor as
    /// it was before the paste, caret included, so a test can paste again.
    private func assertPasted(
        _ inserted: String, in fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
    )
        throws
    {
        XCTAssertEqual(fixture.editor.text, "before \(inserted) after\n", "at the caret", file: file, line: line)
        let caretAfter = Self.caret + (inserted as NSString).length
        XCTAssertEqual(
            fixture.textView.selectedRange(), NSRange(location: caretAfter, length: 0), "caret after the paste",
            file: file, line: line)
        XCTAssertIdentical(
            fixture.window.firstResponder, fixture.textView, "focus stays in the editor", file: file, line: line)
        XCTAssertTrue(fixture.editor.hasUnsavedEdits, "an edit like any other (E-4)", file: file, line: line)
        XCTAssertNil(fixture.controller.inlineMessage, file: file, line: line)
        let manager = try XCTUnwrap(fixture.textView.undoManager, file: file, line: line)
        XCTAssertTrue(manager.canUndo, "the paste is undoable (E-7)", file: file, line: line)
        manager.undo()
        XCTAssertEqual(
            fixture.editor.text, Self.alphaBody, "one undo takes the whole paste out", file: file, line: line)
        fixture.textView.setSelectedRange(NSRange(location: Self.caret, length: 0))
    }

    // MARK: ED-13 HTML on the pasteboard is converted to markdown

    func testED13_htmlIsPastedAsMarkdown() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        XCTAssertEqual(
            HTMLToMarkdown.markdown(fromHTML: Self.html), Self.htmlMarkdown, "the fixture converts as expected")
        fixture.textView.pasteboard = pasteboard(html: Self.html, string: Self.plain)

        fixture.textView.paste(nil)
        let expected = "before \(Self.htmlMarkdown) after\n"
        try assertPasted(Self.htmlMarkdown, in: fixture)
        try XCTUnwrap(fixture.textView.undoManager).redo()
        XCTAssertEqual(fixture.editor.text, expected, "redo puts the whole paste back (E-7)")

        // The paste is autosaved like typing (E-4).
        fixture.clock.advance(by: EditorController.autosaveDelay)
        await waitUntil("Alpha written") { (try? self.fileText(self.alpha)) == expected }
    }

    func testED13_htmlWinsOverRTFWhenBothAreThere() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        fixture.textView.pasteboard = pasteboard(html: Self.html, rtf: Self.rtf, string: Self.plain)
        fixture.textView.paste(nil)
        try assertPasted(Self.htmlMarkdown, in: fixture)
    }

    func testED13_htmlHoldingNoTextFallsThroughToTheNextForm() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        fixture.textView.pasteboard = pasteboard(html: "<div><span></span></div>", rtf: Self.rtf, string: Self.plain)
        fixture.textView.paste(nil)
        try assertPasted(Self.rtfMarkdown, in: fixture)

        fixture.textView.pasteboard = pasteboard(html: "<p></p>", string: "just text")
        fixture.textView.paste(nil)
        try assertPasted("just text", in: fixture)
    }

    // MARK: ED-13 RTF is converted when there is no HTML

    func testED13_rtfIsPastedAsMarkdownWhenThereIsNoHTML() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        XCTAssertEqual(RTFToMarkdown.markdown(fromRTF: Data(Self.rtf.utf8)), Self.rtfMarkdown)
        fixture.textView.pasteboard = pasteboard(rtf: Self.rtf, string: "Plain and bold text.")
        fixture.textView.paste(nil)
        try assertPasted(Self.rtfMarkdown, in: fixture)
    }

    // MARK: ED-13 plain text is pasted as it is

    func testED13_plainTextIsPastedAsItIsWhenThereIsNoRichForm() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        fixture.textView.pasteboard = pasteboard(string: Self.plain)
        fixture.textView.paste(nil)
        try assertPasted(Self.plain, in: fixture)

        // Markdown in the string stays exactly what it is: nothing is escaped or reformatted.
        fixture.textView.pasteboard = pasteboard(string: "**already** `markdown` [[Other]]")
        fixture.textView.paste(nil)
        try assertPasted("**already** `markdown` [[Other]]", in: fixture)
    }

    func testED13_pasteReplacesTheSelection() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 6))  // "before"
        fixture.textView.pasteboard = pasteboard(html: "<p><i>after</i></p>")
        fixture.textView.paste(nil)
        XCTAssertEqual(fixture.editor.text, "*after*  after\n")
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 7, length: 0))
    }

    // MARK: ED-14 Paste and Match Style pastes the plain-text form

    func testED14_pasteAndMatchStylePastesThePlainFormWhateverElseIsThere() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        fixture.textView.pasteboard = pasteboard(html: Self.html, rtf: Self.rtf, string: Self.plain)
        fixture.textView.pasteAsPlainText(nil)
        try assertPasted(Self.plain, in: fixture)

        // Without a string of its own the pasteboard derives one from the RTF itself (as it
        // promotes PNG to TIFF); whatever it offers, no markdown is made of the rich forms.
        fixture.textView.pasteboard = pasteboard(html: Self.html, rtf: Self.rtf)
        fixture.textView.pasteAsPlainText(nil)
        let text = fixture.editor.text
        XCTAssertFalse(text.contains("**") || text.contains("# Title"), "no rich form was converted: \(text)")
        XCTAssertTrue(text.hasPrefix("before ") && text.hasSuffix(" after\n"), "the rest is untouched: \(text)")
    }

    func testED14_pasteAndMatchStyleIsCmdShiftVInTheEditMenuAndReachesTheEditor() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let item = try editItem(#selector(NSTextView.pasteAsPlainText(_:)))
        XCTAssertEqual(item.title, MainMenu.pasteAndMatchStyleItemTitle)
        XCTAssertEqual(item.keyEquivalent, "v")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])

        fixture.textView.pasteboard = pasteboard(html: Self.html, rtf: Self.rtf, string: Self.plain)
        XCTAssertTrue(fixture.textView.validateUserInterfaceItem(item), "enabled with a string to paste")
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: fixture.textView, from: item), "the editor answers to it")
        try assertPasted(Self.plain, in: fixture)
    }

    // MARK: ED-14 image data is still handled per I-1

    func testED14_imageDataOnThePasteboardStillGoesToIUnderEitherPaste() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let png = try Self.generatedPNG()
        // What a browser puts on the clipboard for a copied image: the data, and HTML naming it.
        let html = "<img src=\"https://example.com/pic.png\" alt=\"pic\">"
        XCTAssertEqual(try storedImages(), [])

        for pasteAction in [#selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:))] {
            fixture.textView.pasteboard = pasteboard(html: html, string: "pic", png: png)
            let settled = expectation(description: "image insert settled for \(pasteAction)")
            var reported: Result<String, any Error>?
            fixture.controller.onInsertImage = { outcome in
                reported = outcome
                settled.fulfill()
            }
            XCTAssertTrue(fixture.textView.validateUserInterfaceItem(try editItem(pasteAction)))
            XCTAssertTrue(NSApp.sendAction(pasteAction, to: fixture.textView, from: nil))
            await fulfillment(of: [settled], timeout: 10)
            let name = try XCTUnwrap(reported).get()
            XCTAssertTrue(name.hasSuffix(".png"), name)
            XCTAssertTrue(fixture.editor.text.contains("![[\(name)]]"), "the embed, not the HTML's markdown")
            XCTAssertFalse(fixture.editor.text.contains("pic"), "and not the string either")
        }
        XCTAssertEqual(try storedImages().count, 2, "one file per paste")
    }

    // MARK: ED-13 the Paste item is enabled for a rich pasteboard

    func testED13_pasteItemIsEnabledForHTMLOrRTFAlone() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        let paste = try editItem(#selector(NSText.paste(_:)))
        fixture.textView.pasteboard = pasteboard(html: Self.html)
        XCTAssertTrue(fixture.textView.validateUserInterfaceItem(paste), "HTML alone")
        fixture.textView.pasteboard = pasteboard(rtf: Self.rtf)
        XCTAssertTrue(fixture.textView.validateUserInterfaceItem(paste), "RTF alone")
        fixture.textView.pasteboard = pasteboard(string: Self.plain)
        XCTAssertTrue(fixture.textView.validateUserInterfaceItem(paste), "a string alone")

        let matchStyle = try editItem(#selector(NSTextView.pasteAsPlainText(_:)))
        fixture.textView.pasteboard = pasteboard(string: Self.plain)
        XCTAssertTrue(fixture.textView.validateUserInterfaceItem(matchStyle), "a string to paste plain")
    }

    func testED13_nothingIsPastedWhileNoNoteIsShown() async throws {
        let fixture = try await makeFixtureShowingAlpha()
        fixture.editor.clear()
        XCTAssertNil(fixture.editor.noteID)
        XCTAssertFalse(fixture.textView.isEditable)
        let paste = try editItem(#selector(NSText.paste(_:)))
        fixture.textView.pasteboard = pasteboard(html: Self.html, rtf: Self.rtf, string: Self.plain)
        XCTAssertFalse(fixture.textView.validateUserInterfaceItem(paste), "Paste is disabled without a note")

        fixture.textView.paste(nil)
        fixture.textView.pasteAsPlainText(nil)
        XCTAssertEqual(fixture.textView.string, "")
        XCTAssertEqual(try fileText(alpha), Self.alphaBody)
    }
}
