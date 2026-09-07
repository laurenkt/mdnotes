import Foundation
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// PF-5: resident memory after one full index build of the 20k-note synthetic library
/// (ADR-0007). A class of its own so that `scripts/check.sh` runs it in a fresh process: the
/// number is the absolute resident size, and an index built after other builds in the same
/// process counts their heap residue, which `releaseFreedMemory` cannot hand back in full and
/// which grew with every iteration `IndexPerfTests` added (I-1). Runs only in
/// `scripts/check.sh full` (release); `MDNOTES_SKIP_PERF=1` skips it.
final class IndexMemoryPerfTests: XCTestCase {
    /// The 20k-note library, generated on first use.
    private static let library: Result<URL, any Error> = Result {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-memperf-\(UUID().uuidString)", isDirectory: true)
        try SyntheticLibrary.generate(at: root, options: .init(noteCount: PerfGate.referenceNoteCount))
        return root
    }

    override class func tearDown() {
        if !PerfGate.isSkipped, let root = try? library.get() {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    private func libraryRoot() throws -> URL {
        try XCTSkipIf(PerfGate.isSkipped, "MDNOTES_SKIP_PERF=1")
        return try Self.library.get()
    }

    // MARK: PF-5

    func testPF5_memoryAfterFullIndexUnder200MB() throws {
        let root = try libraryRoot()
        PerfGate.releaseFreedMemory()
        let before = try XCTUnwrap(PerfGate.residentMemoryMB())
        let index = SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: NoteStore(root: root))
        PerfGate.releaseFreedMemory()
        let after = try XCTUnwrap(PerfGate.residentMemoryMB())
        withExtendedLifetime(index) {
            XCTAssertEqual(index.count, PerfGate.referenceNoteCount)
            print(
                "PERF PF-5 resident after full index: \(Int(after)) MB (was \(Int(before)) MB before; budget \(Int(PerfGate.Budget.memoryAfterIndex20kMB)) MB)"
            )
            XCTAssertLessThan(after, PerfGate.Budget.memoryAfterIndex20kMB, "PF-5: resident memory over budget")
        }
    }
}
