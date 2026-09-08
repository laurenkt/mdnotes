import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// PF-2 around the real controller path: a keystroke in the search field's field editor, the
/// query over a 20k-note snapshot, the table reload and the layout of its visible rows, all on
/// the main thread. Runs only in `scripts/check.sh full` (release); `MDNOTES_SKIP_PERF=1`
/// skips it (ADR-0007). PF-8: 10 % of the notes embed a generated PNG, so the visible rows'
/// thumbnail lookups and requests (S-11) are inside the measured path.
@MainActor
final class ListPerfTests: XCTestCase {
    /// Share of notes embedding an image (PF-8).
    nonisolated private static let imageFraction = 0.1

    /// The 20k-note library, generated on first use and shared by every test in the class.
    nonisolated private static let library: Result<URL, any Error> = Result {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-listperf-\(UUID().uuidString)", isDirectory: true)
        try SyntheticLibrary.generate(
            at: root, options: .init(noteCount: PerfGate.referenceNoteCount, imageFraction: imageFraction))
        return root
    }

    override class func tearDown() {
        if !PerfGate.isSkipped, let root = try? library.get() {
            try? FileManager.default.removeItem(at: root)
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

    private func libraryRoot() throws -> URL {
        try XCTSkipIf(PerfGate.isSkipped, "MDNOTES_SKIP_PERF=1")
        return try Self.library.get()
    }

    /// A laid-out window at the default size with the whole 20k library indexed and shown,
    /// and the search field being edited by the window's field editor.
    private func makeReadyController(root: URL) async throws -> (MainWindowController, NSTextView) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 900, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        let deadline = Date().addingTimeInterval(60)
        while library.phase != .ready {
            if Date() > deadline { throw XCTSkip("library did not become ready in 60 s") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.listController.results.count, PerfGate.referenceNoteCount)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        return (controller, editor)
    }

    /// Everything between the key press and the list being redrawn with the new results:
    /// the field editor inserts the character, which fires `controlTextDidChange`, the query,
    /// and `reloadData()`; then the table lays out and populates its visible rows.
    private func keystroke(_ character: Character, in editor: NSTextView, table: NSTableView) {
        editor.insertText(String(character), replacementRange: editor.selectedRange())
        table.layoutSubtreeIfNeeded()
        // A window that is not on screen defers making row views to draw time; do it now so
        // the measured path includes configuring every row the user would see.
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
    }

    /// Empties the field and reloads, so the next phrase starts from the full list.
    private func clearQuery(_ controller: MainWindowController) {
        controller.mainView.searchField.stringValue = ""
        controller.searchQueryDidChange()
        XCTAssertEqual(controller.query, "")
    }

    // MARK: PF-2

    func testPF2_keystrokeToReloadUnder16msWith20kNotes() async throws {
        let root = try libraryRoot()
        let (controller, editor) = try await makeReadyController(root: root)
        let table = controller.mainView.tableView
        let library = try XCTUnwrap(controller.library)

        // PF-8: thumbnails are on. About a tenth of the notes resolve to an image file, and
        // the rows look their thumbnails up under the library's root.
        let withImages = library.snapshot.query("").filter { $0.firstImagePath != nil }.count
        let expectedImages = Double(PerfGate.referenceNoteCount) * Self.imageFraction
        XCTAssertEqual(Double(withImages), expectedImages, accuracy: expectedImages * 0.25, "10 % embed an image")
        XCTAssertEqual(controller.listController.imageRoot, root)

        // Representative phrases typed a character at a time: a word in most titles and
        // bodies, a narrowing two-word query, a nested title, a mid-word prefix, a tag plus a
        // word, and a miss that scans every body to the end. Same set as the core gate.
        let phrases = ["kubernetes", "kupka latency", "deptford 19", "gugg", "#swift markdown", "zqxjk"]
        let warmUp = 2
        let iterations = 11

        // Warm up: first-time costs (fonts, row view classes, the field editor, the table's
        // row view pool growing to the first page) are not what a keystroke costs. Two
        // passes, so the second pass's reuse of the pool is warm too (I-1).
        for _ in 0..<warmUp {
            for phrase in phrases {
                clearQuery(controller)
                for character in phrase { keystroke(character, in: editor, table: table) }
            }
        }

        var worstMedian = 0.0
        for phrase in phrases {
            var samples = Array(repeating: [Double](), count: phrase.count)
            for _ in 0..<iterations {
                clearQuery(controller)
                for (i, character) in phrase.enumerated() {
                    let start = DispatchTime.now().uptimeNanoseconds
                    keystroke(character, in: editor, table: table)
                    let end = DispatchTime.now().uptimeNanoseconds
                    samples[i].append(Double(end - start) / 1_000_000)
                }
                XCTAssertEqual(controller.query, phrase)
            }
            // The list really did reload with this query's results.
            let expected = library.snapshot.query(phrase)
            XCTAssertEqual(controller.listController.results.count, expected.count)
            XCTAssertEqual(table.numberOfRows, expected.count)
            if let first = expected.first {
                let row = table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NoteRowView
                XCTAssertEqual(row?.titleLabel.stringValue, first.id.title, "row 0 shows the first result")
            }

            let keystrokes = samples.map { PerfGate.Samples($0) }
            let medians = keystrokes.map(\.median)
            print(
                "PF-2 \"\(phrase)\": \(expected.count) hits; per-keystroke medians "
                    + medians.map { String(format: "%.2f", $0) }.joined(separator: " ")
                    + " ms (budget \(Int(PerfGate.Budget.keystrokeToListUpdate)) ms)"
            )
            // The gate line: the slowest keystroke of the phrase, its median over the iterations.
            let worst = try XCTUnwrap(keystrokes.indices.max { medians[$0] < medians[$1] })
            PerfGate.report(
                "PF-2", "keystroke \"\(String(phrase.prefix(worst + 1)))\" to reload (\(expected.count) hits)",
                keystrokes[worst], budget: PerfGate.Budget.keystrokeToListUpdate)
            for (i, median) in medians.enumerated() {
                let typed = String(phrase.prefix(i + 1))
                XCTAssertLessThan(
                    median, PerfGate.Budget.keystrokeToListUpdate,
                    "PF-2: keystroke \"\(typed)\" to reload over budget")
            }
            worstMedian = max(worstMedian, medians[worst])
        }
        print("PF-2 worst per-keystroke median: \(String(format: "%.2f", worstMedian)) ms")

        // The rows shown along the way asked for their thumbnails, and the cache made them
        // off the main thread while the keystrokes were being measured.
        XCTAssertGreaterThan(controller.listController.thumbnails.count, 0, "thumbnails were generated")
        XCTAssertLessThanOrEqual(controller.listController.thumbnails.bytes, ThumbnailCache.defaultMaximumBytes)
    }
}
