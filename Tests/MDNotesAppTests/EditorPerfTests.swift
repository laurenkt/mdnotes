import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// PF-3 around the real editor path: a keystroke in the text view showing a 1 MB synthetic
/// note, the storage edit with the paragraph-scoped re-style inside it (E-3), the thumbnail
/// reconciliation of the paragraphs around it (E-9), the layout it invalidates, and the window
/// redrawing, all on the main thread. The note embeds 50 images whose thumbnails are on show
/// (PF-8: the gate runs with thumbnails enabled). Runs only in `scripts/check.sh full`
/// (release); `MDNOTES_SKIP_PERF=1` skips it (ADR-0007).
@MainActor
final class EditorPerfTests: XCTestCase {
    /// How many images the 1 MB note embeds, each on a paragraph of its own (M8.5).
    nonisolated private static let embedCount = 50

    /// A library whose first notes are the 1 MB ones, generated on first use and shared by
    /// every test in the class. The note count does not bear on a keystroke in the editor, so
    /// it stays small; the large notes are the synthetic library's own, each embedding
    /// `embedCount` generated PNGs.
    nonisolated private static let library: Result<(root: URL, paths: [String]), any Error> = Result {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-editorperf-\(UUID().uuidString)", isDirectory: true)
        let paths = try SyntheticLibrary.generate(
            at: root, options: .init(noteCount: 200, largeNoteCount: 5, largeNoteEmbeds: embedCount))
        return (root, paths)
    }

    override class func tearDown() {
        if !PerfGate.isSkipped, let library = try? library.get() {
            try? FileManager.default.removeItem(at: library.root)
        }
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    private func libraryOnDisk() throws -> (root: URL, paths: [String]) {
        try XCTSkipIf(PerfGate.isSkipped, "MDNOTES_SKIP_PERF=1")
        return try Self.library.get()
    }

    /// A window on screen with the library attached and its first 1 MB note shown in the
    /// editor, which has focus.
    private func makeReadyController(root: URL, showing id: NoteID) async throws -> (MainWindowController, NSWindow) {
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 700))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        let deadline = Date().addingTimeInterval(60)
        while library.phase != .ready {
            if Date() > deadline { throw XCTSkip("library did not become ready in 60 s") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let row = try XCTUnwrap(controller.listController.results.firstIndex { $0.id == id })
        controller.mainView.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        while controller.editorController.body == nil {
            if Date() > deadline { throw XCTSkip("editor did not load the note in 60 s") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.editorController.noteID, id)
        // E-9: every embed's thumbnail is on show before a keystroke is measured.
        while controller.editorController.attachmentRanges.count < Self.embedCount {
            if Date() > deadline { throw XCTSkip("thumbnails did not all appear in 60 s") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.editorController.attachmentRanges.count, Self.embedCount)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return (controller, window)
    }

    /// Everything between the key press and the editor being redrawn: the text view inserts
    /// the character, the storage processes the edit and the styler re-styles the paragraphs
    /// around it in the same pass, the thumbnails reconcile the paragraphs around it (E-9,
    /// which the app does on the next run loop turn and the gate does here so that it counts),
    /// the layout manager invalidates them; then the window lays out and draws what the user
    /// sees.
    private func keystroke(_ text: String, in controller: MainWindowController, window: NSWindow) {
        let textView = controller.mainView.textView
        textView.insertText(text, replacementRange: textView.selectedRange())
        controller.editorController.thumbnails.reconcileNow()
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    /// The start of the line at `location` in the shown text, or of the next line when that
    /// one is a thumbnail's (E-9): typing is measured in the file's text, where a user types.
    private func lineStart(near location: Int, in text: NSString) -> Int {
        var line = text.lineRange(for: NSRange(location: location, length: 0))
        while text.range(of: "\u{FFFC}", options: [], range: line).location != NSNotFound,
            NSMaxRange(line) < text.length
        {
            line = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        }
        return line.location
    }

    // MARK: PF-3

    func testPF3_keystrokeToRedrawUnder8msOnA1MBNote() async throws {
        let library = try libraryOnDisk()
        // Reported for the record: what the process held before the test and what it holds
        // after everything has been handed back (see the end of the test).
        PerfGate.releaseFreedMemory()
        let residentBefore = PerfGate.residentMemoryMB() ?? 0
        let id = NoteID(relativePath: library.paths[0])
        let (controller, window) = try await makeReadyController(root: library.root, showing: id)
        let textView = controller.mainView.textView
        let storage = try XCTUnwrap(textView.textStorage)
        let length = storage.length
        XCTAssertGreaterThan(length, 900_000, "the note is the 1 MB one")
        XCTAssertGreaterThan(
            countStyled(in: storage), 1_000, "the loaded note is styled (E-2) before typing starts")

        // Where the caret is put, then what is typed there a character at a time: the end of
        // the note, its middle, the start of a line deep inside it, and the heading on line one.
        // What is typed makes a tag, a wikilink, a heading and plain words, so each keystroke
        // changes what the paragraph's tokens are.
        let text = storage.string as NSString
        let headingEnd = text.lineRange(for: NSRange(location: 0, length: 0))
        let cases: [(name: String, location: Int, typed: String)] = [
            ("end", length, "\n\n#swift [[kupka 3]] more"),
            ("middle", lineStart(near: length / 2, in: text), "# heading `code` "),
            ("deep", lineStart(near: length * 3 / 4, in: text), "words #tag "),
            ("heading", max(headingEnd.length - 1, 0), " [[link]]"),
        ]
        let warmUp = 2
        let iterations = 11

        // Warm up: fonts, first layout, the styler's first pass, the undo stack's growth are
        // not what a keystroke costs. Two passes, since the first undo of each case is a
        // first too (I-1).
        for _ in 0..<warmUp {
            for c in cases {
                textView.setSelectedRange(NSRange(location: c.location, length: 0))
                for character in c.typed { keystroke(String(character), in: controller, window: window) }
                try undo(textView, count: c.typed.count, expecting: length)
            }
        }

        var worstMedian = 0.0
        for c in cases {
            var samples = Array(repeating: [Double](), count: c.typed.count)
            for _ in 0..<iterations {
                textView.setSelectedRange(NSRange(location: c.location, length: 0))
                var carets: [Int] = []
                for (i, character) in c.typed.enumerated() {
                    let start = DispatchTime.now().uptimeNanoseconds
                    keystroke(String(character), in: controller, window: window)
                    let end = DispatchTime.now().uptimeNanoseconds
                    samples[i].append(Double(end - start) / 1_000_000)
                    carets.append(textView.selectedRange().location)
                }
                XCTAssertEqual(storage.length, length + (c.typed as NSString).length)
                // The insertion point followed the typing, one character at a time: the
                // re-style did not move it to the end of the paragraph it re-styled.
                XCTAssertEqual(
                    carets, (1...c.typed.count).map { c.location + $0 }, "\(c.name): caret after each keystroke")
                // The re-style really happened: the typed tokens carry their styles.
                let typedRange = NSRange(location: c.location, length: (c.typed as NSString).length)
                XCTAssertTrue(
                    hasStyle(in: storage, range: typedRange),
                    "\(c.name): the typed text was styled: \(storage.attributedSubstring(from: typedRange).string)")
                try undo(textView, count: c.typed.count, expecting: length)
            }
            let keystrokes = samples.map { PerfGate.Samples($0) }
            let medians = keystrokes.map(\.median)
            print(
                "PF-3 \(c.name): per-keystroke medians "
                    + medians.map { String(format: "%.2f", $0) }.joined(separator: " ")
                    + " ms (budget \(Int(PerfGate.Budget.editorKeystrokeToRedraw)) ms)"
            )
            // The gate line: the slowest keystroke of the case, its median over the iterations.
            let worst = try XCTUnwrap(keystrokes.indices.max { medians[$0] < medians[$1] })
            PerfGate.report(
                "PF-3", "\(c.name), keystroke \(worst + 1) of \(c.typed.count) to redraw", keystrokes[worst],
                budget: PerfGate.Budget.editorKeystrokeToRedraw)
            for (i, median) in medians.enumerated() {
                let typed = String(c.typed.prefix(i + 1))
                XCTAssertLessThan(
                    median, PerfGate.Budget.editorKeystrokeToRedraw,
                    "PF-3: keystroke \(i + 1) of \"\(typed)\" at \(c.name) to redraw over budget")
            }
            worstMedian = max(worstMedian, medians[worst])
        }
        print("PF-3 worst per-keystroke median: \(String(format: "%.2f", worstMedian)) ms")
        XCTAssertEqual(textView.string, storage.string)

        // Hand everything back: the library, the note's storage and layout, and the window.
        // TextKit and AppKit keep much of what showing and laying out a 1 MB note cost, which
        // is why `scripts/check.sh` runs each perf class in a process of its own.
        controller.library?.stop()
        controller.detachLibrary()
        window.close()
        _ = window.setFrameAutosaveName("")
        PerfGate.releaseFreedMemory()
        let residentAfter = PerfGate.residentMemoryMB() ?? 0
        print(
            "PF-3 resident memory: \(Int(residentBefore)) MB before the test, \(Int(residentAfter)) MB after it "
                + "(the note is \(length / 1_000_000) MB of text)")
    }

    /// Undoes `count` single-character insertions and checks the text is back to `length`
    /// characters, so every iteration starts from the same note.
    private func undo(_ textView: NSTextView, count: Int, expecting length: Int) throws {
        textView.breakUndoCoalescing()
        let manager = try XCTUnwrap(textView.undoManager)
        var guardCount = 0
        while (textView.textStorage?.length ?? 0) > length, guardCount < count + 1, manager.canUndo {
            manager.undo()
            guardCount += 1
        }
        XCTAssertEqual(textView.textStorage?.length, length, "undo brought the note back")
    }

    private func countStyled(in storage: NSTextStorage) -> Int {
        var count = 0
        storage.enumerateAttribute(EditorStyler.tokenAttribute, in: NSRange(location: 0, length: storage.length)) {
            value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    private func hasStyle(in storage: NSTextStorage, range: NSRange) -> Bool {
        var found = false
        storage.enumerateAttribute(EditorStyler.tokenAttribute, in: range) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
