import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// PF-3 around the real editor path: a keystroke in the text view showing a 1 MB synthetic
/// note, the storage edit with the paragraph-scoped re-style inside it (E-3), the layout it
/// invalidates, and the window redrawing, all on the main thread. Runs only in
/// `scripts/check.sh full` (release); `MDNOTES_SKIP_PERF=1` skips it (ADR-0007).
@MainActor
final class EditorPerfTests: XCTestCase {
    /// A library whose first notes are the 1 MB ones, generated on first use and shared by
    /// every test in the class. The note count does not bear on a keystroke in the editor, so
    /// it stays small; the large notes are the synthetic library's own.
    nonisolated private static let library: Result<(root: URL, paths: [String]), any Error> = Result {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-editorperf-\(UUID().uuidString)", isDirectory: true)
        let paths = try SyntheticLibrary.generate(at: root, options: .init(noteCount: 200, largeNoteCount: 5))
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
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.textView))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return (controller, window)
    }

    /// Everything between the key press and the editor being redrawn: the text view inserts
    /// the character, the storage processes the edit and the styler re-styles the paragraphs
    /// around it in the same pass, the layout manager invalidates them; then the window lays
    /// out and draws what the user sees.
    private func keystroke(_ text: String, in textView: NSTextView, window: NSWindow) {
        textView.insertText(text, replacementRange: textView.selectedRange())
        window.layoutIfNeeded()
        window.displayIfNeeded()
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
        let middleLine = text.lineRange(for: NSRange(location: length / 2, length: 0))
        let deepLine = text.lineRange(for: NSRange(location: length * 3 / 4, length: 0))
        let headingEnd = text.lineRange(for: NSRange(location: 0, length: 0))
        let cases: [(name: String, location: Int, typed: String)] = [
            ("end", length, "\n\n#swift [[kupka 3]] more"),
            ("middle", middleLine.location, "# heading `code` "),
            ("deep", deepLine.location, "words #tag "),
            ("heading", max(headingEnd.length - 1, 0), " [[link]]"),
        ]
        let iterations = 5

        // Warm up once: fonts, first layout, the styler's first pass are not what a keystroke costs.
        for c in cases {
            textView.setSelectedRange(NSRange(location: c.location, length: 0))
            for character in c.typed { keystroke(String(character), in: textView, window: window) }
            try undo(textView, count: c.typed.count, expecting: length)
        }

        var worstMedian = 0.0
        for c in cases {
            var samples = Array(repeating: [Double](), count: c.typed.count)
            for _ in 0..<iterations {
                textView.setSelectedRange(NSRange(location: c.location, length: 0))
                var carets: [Int] = []
                for (i, character) in c.typed.enumerated() {
                    let start = DispatchTime.now().uptimeNanoseconds
                    keystroke(String(character), in: textView, window: window)
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
            let medians = samples.map { $0.sorted()[$0.count / 2] }
            let maxSample = samples.flatMap { $0 }.max() ?? 0
            print(
                "PF-3 \(c.name): per-keystroke medians "
                    + medians.map { String(format: "%.2f", $0) }.joined(separator: " ")
                    + " ms (worst sample \(String(format: "%.2f", maxSample)) ms, budget \(Int(PerfGate.Budget.editorKeystrokeToRedraw)) ms)"
            )
            for (i, median) in medians.enumerated() {
                let typed = String(c.typed.prefix(i + 1))
                XCTAssertLessThan(
                    median, PerfGate.Budget.editorKeystrokeToRedraw,
                    "PF-3: keystroke \(i + 1) of \"\(typed)\" at \(c.name) to redraw over budget")
            }
            worstMedian = max(worstMedian, medians.max() ?? 0)
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
