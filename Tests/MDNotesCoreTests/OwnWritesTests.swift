import Foundation
import MDNotesCore
import XCTest

/// The ledger of this process's own writes, which the watcher will consult to ignore their
/// echoes (E-6).
final class OwnWritesTests: XCTestCase {
    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_001)

    func testE6_aRecordedWriteMatchesOnlyItsIdAndDate() {
        let writes = OwnWrites()
        XCTAssertEqual(writes.count, 0)
        XCTAssertFalse(writes.contains(alpha, modifiedAt: t1))
        XCTAssertNil(writes.lastWrite(of: alpha))

        writes.record(alpha, modifiedAt: t1)
        XCTAssertTrue(writes.contains(alpha, modifiedAt: t1))
        XCTAssertFalse(writes.contains(alpha, modifiedAt: t2), "a different date is someone else's write")
        XCTAssertFalse(writes.contains(beta, modifiedAt: t1), "a different note is someone else's write")
        XCTAssertEqual(writes.lastWrite(of: alpha), t1)
        XCTAssertEqual(writes.count, 1)
    }

    func testE6_aLaterWriteReplacesTheEarlierRecord() {
        let writes = OwnWrites()
        writes.record(alpha, modifiedAt: t1)
        writes.record(alpha, modifiedAt: t2)
        XCTAssertFalse(writes.contains(alpha, modifiedAt: t1), "an event carrying the old date is no longer ours")
        XCTAssertTrue(writes.contains(alpha, modifiedAt: t2))
        XCTAssertEqual(writes.count, 1, "one record per note, so the ledger is bounded by the notes written")
    }

    func testE6_forgettingDropsTheRecord() {
        let writes = OwnWrites()
        writes.record(alpha, modifiedAt: t1)
        writes.record(beta, modifiedAt: t2)
        writes.forget(alpha)
        XCTAssertNil(writes.lastWrite(of: alpha))
        XCTAssertEqual(writes.lastWrite(of: beta), t2)
        writes.forget(alpha)
        XCTAssertEqual(writes.count, 1, "forgetting twice is harmless")
    }

    func testE6_isSafeFromManyThreads() {
        let writes = OwnWrites()
        let ids = (0..<64).map { NoteID(relativePath: "n\($0).md") }
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            for round in 0..<100 {
                writes.record(ids[i], modifiedAt: Date(timeIntervalSince1970: Double(round)))
                _ = writes.contains(ids[i], modifiedAt: Date(timeIntervalSince1970: Double(round)))
            }
        }
        XCTAssertEqual(writes.count, 64)
        for id in ids {
            XCTAssertTrue(writes.contains(id, modifiedAt: Date(timeIntervalSince1970: 99)))
        }
    }
}
