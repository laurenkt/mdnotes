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

    // MARK: suppression of the watcher's echoes

    func testE6_suppressingDropsOnlyTheEchoesOfRecordedWrites() {
        let writes = OwnWrites()
        let gamma = NoteID(relativePath: "Gamma.md")
        let fresh = NoteID(relativePath: "Fresh.md")
        writes.record(alpha, modifiedAt: t1)
        writes.record(beta, modifiedAt: t1)
        writes.record(fresh, modifiedAt: t2)
        let onDisk: [NoteID: Date] = [alpha: t1, beta: t2, fresh: t2, gamma: t1]
        var dated: [NoteID] = []
        let changes = LibraryChanges(added: [fresh], modified: [alpha, beta, gamma], removed: [alpha])

        let external = writes.suppressing(changes) { id in
            dated.append(id)
            guard let date = onDisk[id] else { throw CocoaError(.fileNoSuchFile) }
            return date
        }

        XCTAssertEqual(external.added, [], "our create, still carrying our date, is dropped")
        XCTAssertEqual(external.modified, [beta, gamma], "beta was rewritten since our write; gamma was never ours")
        XCTAssertEqual(external.removed, [alpha], "a removal is never our write and always stays")
        XCTAssertEqual(
            Set(dated), [alpha, beta, fresh],
            "only added and modified ids with a record are checked against disk; removals and strangers are not")
        XCTAssertEqual(writes.count, 3, "matching keeps the record: the same write may echo more than once")
        XCTAssertTrue(writes.contains(alpha, modifiedAt: t1))
    }

    func testE6_suppressingLeavesChangesAloneWhenNothingCanMatch() {
        let writes = OwnWrites()
        let changes = LibraryChanges(added: [alpha], modified: [beta])
        var dated = 0
        XCTAssertEqual(
            writes.suppressing(changes) { _ in
                dated += 1
                return t1
            }, changes)
        XCTAssertEqual(dated, 0, "an empty ledger never touches the disk")

        writes.record(alpha, modifiedAt: t1)
        XCTAssertEqual(writes.suppressing(LibraryChanges()) { _ in t1 }, LibraryChanges())
        // A file that is gone cannot be our write's echo; the change stays for the index to judge.
        XCTAssertEqual(writes.suppressing(changes) { _ in throw CocoaError(.fileNoSuchFile) }, changes)
    }

    func testE6_suppressingWithAStoreReadsTheDateOffTheFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-ownwrites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("daily", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let writes = OwnWrites()

        let ours = try AtomicWriter().write("ours", to: store.url(for: alpha))
        writes.record(alpha, modifiedAt: ours)
        try AtomicWriter().write("theirs", to: store.url(for: beta))
        let echo = LibraryChanges(modified: [alpha, beta])
        XCTAssertEqual(writes.suppressing(echo, store: store), LibraryChanges(modified: [beta]))

        // Someone else rewrites alpha with a different date: the event is theirs.
        try FileManager.default.setAttributes(
            [.modificationDate: ours.addingTimeInterval(1)], ofItemAtPath: store.url(for: alpha).path)
        XCTAssertEqual(writes.suppressing(echo, store: store), echo)
    }

    // MARK: our own removals (D-1)

    func testD1_aRecordedRemovalSuppressesTheWatchersEchoWhileTheFileIsGone() {
        let writes = OwnWrites()
        writes.record(alpha, modifiedAt: t1)
        writes.recordRemoval(alpha)
        XCTAssertTrue(writes.removed(alpha))
        XCTAssertNil(writes.lastWrite(of: alpha), "the removal replaced the write record")
        XCTAssertFalse(writes.contains(alpha, modifiedAt: t1))
        XCTAssertEqual(writes.count, 1)

        let echo = LibraryChanges(removed: [alpha, beta])
        let external = writes.suppressing(echo) { _ in throw CocoaError(.fileNoSuchFile) }
        XCTAssertEqual(external, LibraryChanges(removed: [beta]), "our removal is dropped; beta's is someone else's")
        XCTAssertTrue(writes.removed(alpha), "matching keeps the record: the same removal may echo more than once")

        // The file is back on disk: whoever put it there, its removal was not the one we made.
        XCTAssertEqual(writes.suppressing(echo) { _ in t2 }, echo)
    }

    func testD1_aNoteRecreatedBySomeoneElseIsExternalAndClearsTheRemovalRecord() {
        let writes = OwnWrites()
        writes.recordRemoval(alpha)
        let recreated = LibraryChanges(added: [alpha])
        XCTAssertEqual(writes.suppressing(recreated) { _ in t1 }, recreated, "not our write, whatever its date")
        XCTAssertFalse(writes.removed(alpha))
        XCTAssertEqual(writes.count, 0)
        // Its next removal is theirs too.
        XCTAssertEqual(
            writes.suppressing(LibraryChanges(removed: [alpha])) { _ in throw CocoaError(.fileNoSuchFile) },
            LibraryChanges(removed: [alpha]))
    }

    func testD1_ourOwnRecreateReplacesTheRemovalRecord() {
        let writes = OwnWrites()
        writes.recordRemoval(alpha)
        writes.record(alpha, modifiedAt: t2)
        XCTAssertFalse(writes.removed(alpha))
        XCTAssertEqual(writes.lastWrite(of: alpha), t2)
        XCTAssertEqual(writes.suppressing(LibraryChanges(added: [alpha])) { _ in t2 }, LibraryChanges())
        writes.forget(alpha)
        XCTAssertEqual(writes.count, 0)
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
