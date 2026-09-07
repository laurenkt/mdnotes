import Foundation
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// Core-level timing gates over the 20k-note synthetic library (PF-2, PF-4, ADR-0007). PF-5 is
/// `IndexMemoryPerfTests`, in a process of its own.
///
/// Runs only in `scripts/check.sh full` (release); `MDNOTES_SKIP_PERF=1` skips it. The library
/// is generated once per process and shared by every test in the class.
final class IndexPerfTests: XCTestCase {
    /// The 20k-note library, generated on first use.
    private static let library: Result<URL, any Error> = Result {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-perf-\(UUID().uuidString)", isDirectory: true)
        try SyntheticLibrary.generate(at: root, options: .init(noteCount: PerfGate.referenceNoteCount))
        return root
    }

    override class func tearDown() {
        if !PerfGate.isSkipped, let root = try? library.get() {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    /// A full index build as the app will do it on launch (PF-7): walk the root, read every
    /// body, build one snapshot.
    private static func buildIndex(root: URL) throws -> SearchIndex {
        SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: NoteStore(root: root))
    }

    private func libraryRoot() throws -> URL {
        try XCTSkipIf(PerfGate.isSkipped, "MDNOTES_SKIP_PERF=1")
        return try Self.library.get()
    }

    // MARK: PF-4

    func testPF4_fullBuildOf20kUnder2s() throws {
        let root = try libraryRoot()
        var count = 0
        // One unmeasured build first: the first walk of a fresh library pays the page cache
        // and the allocator's growth, which a launch after the first does not (I-1).
        let samples = try PerfGate.measure(warmUp: 1, iterations: 5) {
            count = try Self.buildIndex(root: root).count
        }
        XCTAssertEqual(count, PerfGate.referenceNoteCount)
        PerfGate.report("PF-4", "full build of \(count) notes", samples, budget: PerfGate.Budget.fullIndex20k)
        XCTAssertLessThan(samples.median, PerfGate.Budget.fullIndex20k, "PF-4: full index build over budget")
    }

    // MARK: PF-2 (core share)

    func testPF2_queryOver20kUnder4ms() throws {
        let root = try libraryRoot()
        let index = try Self.buildIndex(root: root)
        XCTAssertEqual(index.count, PerfGate.referenceNoteCount)

        // Representative keystrokes: a word in most titles and bodies, a two-word narrowing
        // query, a title-only hit on a nested note, a prefix typed mid-word, and a miss that
        // forces every body to be scanned to the end.
        let queries = ["kubernetes", "kupka latency", "deptford 19", "gugg", "#swift markdown", "zqxjk"]
        for text in queries {
            var results = 0
            let samples = PerfGate.measure(warmUp: 5, iterations: 50) {
                results = index.query(text).count
            }
            PerfGate.report(
                "PF-2", "core query \"\(text)\" (\(results) hits)", samples, budget: PerfGate.Budget.coreQuery20k)
            XCTAssertLessThan(samples.median, PerfGate.Budget.coreQuery20k, "PF-2: query \"\(text)\" over budget")
        }
        XCTAssertEqual(index.query("").count, PerfGate.referenceNoteCount)
    }
}
