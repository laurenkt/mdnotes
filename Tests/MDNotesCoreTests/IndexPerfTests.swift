import Foundation
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// Core-level performance gates over the 20k-note synthetic library (PF-2, PF-4, PF-5, ADR-0007).
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
        let ms = try PerfGate.medianMilliseconds(iterations: 3) {
            count = try Self.buildIndex(root: root).count
        }
        XCTAssertEqual(count, PerfGate.referenceNoteCount)
        print("PF-4 full build of \(count) notes: \(Int(ms)) ms (budget \(Int(PerfGate.Budget.fullIndex20k)) ms)")
        XCTAssertLessThan(ms, PerfGate.Budget.fullIndex20k, "PF-4: full index build over budget")
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
            let ms = PerfGate.medianMilliseconds(iterations: 20) {
                results = index.query(text).count
            }
            print("PF-2 core query \"\(text)\": \(results) hits in \(String(format: "%.2f", ms)) ms")
            XCTAssertLessThan(ms, PerfGate.Budget.coreQuery20k, "PF-2: query \"\(text)\" over budget")
        }
        XCTAssertEqual(index.query("").count, PerfGate.referenceNoteCount)
    }

    // MARK: PF-5

    func testPF5_memoryAfterFullIndexUnder200MB() throws {
        let root = try libraryRoot()
        PerfGate.releaseFreedMemory()
        let before = try XCTUnwrap(PerfGate.residentMemoryMB())
        let index = try Self.buildIndex(root: root)
        PerfGate.releaseFreedMemory()
        let after = try XCTUnwrap(PerfGate.residentMemoryMB())
        withExtendedLifetime(index) {
            XCTAssertEqual(index.count, PerfGate.referenceNoteCount)
            print(
                "PF-5 resident after full index: \(Int(after)) MB (was \(Int(before)) MB before; budget \(Int(PerfGate.Budget.memoryAfterIndex20kMB)) MB)"
            )
            XCTAssertLessThan(after, PerfGate.Budget.memoryAfterIndex20kMB, "PF-5: resident memory over budget")
        }
    }
}
