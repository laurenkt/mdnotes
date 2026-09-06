import Foundation
import MDNotesCore
import XCTest

/// Incremental updates to a `SearchIndex` snapshot (X-1): added, modified and removed notes
/// produce a new snapshot without a full rescan, keeping list order (S-3).
final class SearchIndexUpdateTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Minutes after `epoch`, so tests can spell out relative modification order.
    private func at(_ minutes: Int) -> Date { epoch.addingTimeInterval(Double(minutes) * 60) }

    private func id(_ path: String) -> NoteID { NoteID(relativePath: path) }

    private func index(_ notes: [(path: String, minutes: Int, body: String)]) -> SearchIndex {
        var builder = SearchIndex.Builder()
        for note in notes {
            builder.add(id: id(note.path), modifiedAt: at(note.minutes), body: note.body)
        }
        return builder.build()
    }

    private func paths<Entries: Collection<SearchIndex.Entry>>(_ results: Entries) -> [String] {
        results.map(\.id.relativePath)
    }

    /// A stand-in for disk: the current date and body of each note, keyed by path.
    private func disk(_ notes: [String: (minutes: Int, body: String)]) -> (NoteID) -> (modifiedAt: Date, body: String)?
    {
        { id in notes[id.relativePath].map { (self.at($0.minutes), $0.body) } }
    }

    private var base: SearchIndex {
        index([
            ("a.md", 1, "alpha"),
            ("b.md", 2, "beta"),
            ("c.md", 3, "gamma"),
        ])
    }

    // MARK: X-1 added

    func testX1_addedNoteAppearsInListOrder() {
        let updated = base.applying(
            changes: LibraryChanges(added: [id("d.md")]),
            contents: disk(["d.md": (5, "delta")]))
        XCTAssertEqual(paths(updated.query("")), ["d.md", "c.md", "b.md", "a.md"])
        XCTAssertEqual(paths(updated.query("delta")), ["d.md"])
        XCTAssertEqual(updated.entry(for: id("d.md"))?.modifiedAt, at(5))
        XCTAssertEqual(updated.entry(for: id("d.md"))?.body, "delta")
    }

    func testX1_addedNoteIsInsertedBetweenExistingNotes() {
        let updated = base.applying(
            changes: LibraryChanges(added: [id("daily/mid.md"), id("old.md")]),
            contents: disk(["daily/mid.md": (2, "between"), "old.md": (0, "oldest")]))
        // Same minute as b.md: ties order by path, so "b.md" precedes "daily/mid.md".
        XCTAssertEqual(paths(updated.query("")), ["c.md", "b.md", "daily/mid.md", "a.md", "old.md"])
        XCTAssertEqual(updated.count, 5)
    }

    func testX1_addedNoteThatVanishedBeforeReadingIsNotIndexed() {
        let updated = base.applying(changes: LibraryChanges(added: [id("ghost.md")]), contents: disk([:]))
        XCTAssertEqual(paths(updated.query("")), ["c.md", "b.md", "a.md"])
        XCTAssertNil(updated.entry(for: id("ghost.md")))
    }

    func testX1_addedIdAlreadyIndexedReplacesRatherThanDuplicates() {
        let updated = base.applying(
            changes: LibraryChanges(added: [id("a.md")]),
            contents: disk(["a.md": (9, "alpha rewritten")]))
        XCTAssertEqual(updated.count, 3)
        XCTAssertEqual(paths(updated.query("")), ["a.md", "c.md", "b.md"])
        XCTAssertEqual(paths(updated.query("rewritten")), ["a.md"])
    }

    // MARK: X-1 modified

    func testX1_modifiedNoteReindexesBodyAndDate() {
        let updated = base.applying(
            changes: LibraryChanges(modified: [id("b.md")]),
            contents: disk(["b.md": (2, "beta plus epsilon")]))
        XCTAssertEqual(paths(updated.query("epsilon")), ["b.md"])
        XCTAssertEqual(paths(updated.query("beta")), ["b.md"])
        XCTAssertEqual(updated.count, 3)
        XCTAssertEqual(paths(updated.query("")), ["c.md", "b.md", "a.md"])
    }

    func testS3_modifiedNoteMovesToItsNewPositionByDate() {
        let updated = base.applying(
            changes: LibraryChanges(modified: [id("a.md")]),
            contents: disk(["a.md": (10, "alpha")]))
        XCTAssertEqual(paths(updated.query("")), ["a.md", "c.md", "b.md"])
        XCTAssertEqual(paths(updated.entries), ["a.md", "c.md", "b.md"])
    }

    func testX1_modifiedNoteThatVanishedIsDropped() {
        let updated = base.applying(changes: LibraryChanges(modified: [id("b.md")]), contents: disk([:]))
        XCTAssertEqual(paths(updated.query("")), ["c.md", "a.md"])
        XCTAssertEqual(paths(updated.query("beta")), [])
    }

    func testX1_modifiedIdNotYetIndexedIsAdded() {
        // The watcher may report a note it never announced as added; disk is the truth.
        let updated = base.applying(
            changes: LibraryChanges(modified: [id("new.md")]),
            contents: disk(["new.md": (4, "surprise")]))
        XCTAssertEqual(paths(updated.query("surprise")), ["new.md"])
        XCTAssertEqual(paths(updated.query("")), ["new.md", "c.md", "b.md", "a.md"])
    }

    // MARK: X-1 removed

    func testX1_removedNoteDisappears() {
        let updated = base.applying(changes: LibraryChanges(removed: [id("b.md")]), contents: disk([:]))
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(paths(updated.query("")), ["c.md", "a.md"])
        XCTAssertEqual(paths(updated.query("beta")), [])
        XCTAssertNil(updated.entry(for: id("b.md")))
    }

    func testX1_removingUnknownIdIsHarmless() {
        let updated = base.applying(changes: LibraryChanges(removed: [id("nope.md")]), contents: disk([:]))
        XCTAssertEqual(paths(updated.query("")), ["c.md", "b.md", "a.md"])
    }

    func testX1_removingEveryNoteLeavesAnEmptySnapshot() {
        let updated = base.applying(
            changes: LibraryChanges(removed: [id("a.md"), id("b.md"), id("c.md")]), contents: disk([:]))
        XCTAssertEqual(updated.count, 0)
        XCTAssertEqual(paths(updated.query("")), [])
        XCTAssertEqual(paths(updated.query("alpha")), [])
    }

    func testX1_removedThenReaddedInOneBatchFollowsDisk() {
        // A delete and recreate coalesced into one batch: the file exists, so it stays.
        let updated = base.applying(
            changes: LibraryChanges(added: [id("a.md")], removed: [id("a.md")]),
            contents: disk(["a.md": (7, "alpha again")]))
        XCTAssertEqual(paths(updated.query("again")), ["a.md"])
        XCTAssertEqual(paths(updated.query("")), ["a.md", "c.md", "b.md"])
    }

    // MARK: X-1 rename, mixed batches, immutability

    func testX1_renameIsRemovalPlusAddition() {
        let updated = base.applying(
            changes: LibraryChanges(added: [id("daily/c renamed.md")], removed: [id("c.md")]),
            contents: disk(["daily/c renamed.md": (3, "gamma")]))
        XCTAssertEqual(paths(updated.query("")), ["daily/c renamed.md", "b.md", "a.md"])
        XCTAssertEqual(paths(updated.query("renamed")), ["daily/c renamed.md"])
        XCTAssertEqual(paths(updated.query("gamma")), ["daily/c renamed.md"])
        XCTAssertNil(updated.entry(for: id("c.md")))
    }

    func testX1_mixedBatchAppliesEveryKind() {
        let updated = base.applying(
            changes: LibraryChanges(added: [id("d.md")], modified: [id("a.md")], removed: [id("b.md")]),
            contents: disk(["d.md": (4, "delta"), "a.md": (6, "alpha changed")]))
        XCTAssertEqual(paths(updated.query("")), ["a.md", "d.md", "c.md"])
        XCTAssertEqual(paths(updated.query("changed")), ["a.md"])
        XCTAssertEqual(paths(updated.query("beta")), [])
    }

    func testX1_emptyChangesReturnTheSameSnapshot() {
        XCTAssertTrue(LibraryChanges().isEmpty)
        XCTAssertFalse(LibraryChanges(removed: [id("a.md")]).isEmpty)
        let updated = base.applying(changes: LibraryChanges()) { _ in
            XCTFail("nothing should be read")
            return nil
        }
        XCTAssertEqual(updated.entries, base.entries)
    }

    func testX1_originalSnapshotIsUntouched() {
        let original = base
        let updated = original.applying(
            changes: LibraryChanges(added: [id("d.md")], modified: [id("a.md")], removed: [id("b.md")]),
            contents: disk(["d.md": (4, "delta"), "a.md": (6, "alpha changed")]))
        XCTAssertEqual(paths(original.query("")), ["c.md", "b.md", "a.md"])
        XCTAssertEqual(paths(original.query("beta")), ["b.md"])
        XCTAssertEqual(paths(original.query("delta")), [])
        XCTAssertEqual(original.entry(for: id("a.md"))?.body, "alpha")
        XCTAssertEqual(updated.entry(for: id("a.md"))?.body, "alpha changed")
    }

    func testX1_updatesChainAcrossSnapshots() {
        let first = base.applying(changes: LibraryChanges(added: [id("d.md")]), contents: disk(["d.md": (4, "delta")]))
        let second = first.applying(changes: LibraryChanges(removed: [id("a.md")]), contents: disk([:]))
        let third = second.applying(
            changes: LibraryChanges(modified: [id("d.md")]), contents: disk(["d.md": (0, "delta old")]))
        XCTAssertEqual(paths(third.query("")), ["c.md", "b.md", "d.md"])
        XCTAssertEqual(paths(third.query("old")), ["d.md"])
        XCTAssertEqual(paths(third.query("alpha")), [])
    }

    func testS2_queryOverUpdatedSnapshotMatchesTitleAndBody() {
        // The repacked arena must still serve title-first, case-insensitive, multi-word queries.
        let updated = base.applying(
            changes: LibraryChanges(added: [id("Swift Notes.md")], modified: [id("c.md")]),
            contents: disk(["Swift Notes.md": (4, "nothing relevant"), "c.md": (8, "mentions SWIFT once")]))
        XCTAssertEqual(paths(updated.query("swift")), ["Swift Notes.md", "c.md"])
        XCTAssertEqual(paths(updated.query("swift once")), ["c.md"])
        XCTAssertEqual(paths(updated.query("gamma")), [])
    }

    // MARK: disk-backed updates through NoteStore

    private var root: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `text` at `relativePath` with the given modification date, creating folders.
    private func write(_ text: String, to relativePath: String, minutes: Int) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: at(minutes)], ofItemAtPath: url.path)
    }

    private func buildFromDisk(store: NoteStore) throws -> SearchIndex {
        SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: store)
    }

    func testX1_changesAreReadFromDisk() throws {
        try write("alpha", to: "a.md", minutes: 1)
        try write("beta", to: "b.md", minutes: 2)
        let store = NoteStore(root: root)
        let initial = try buildFromDisk(store: store)
        XCTAssertEqual(paths(initial.query("")), ["b.md", "a.md"])

        try write("gamma", to: "daily/c.md", minutes: 3)
        try write("beta changed", to: "b.md", minutes: 4)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.md"))
        let updated = initial.applying(
            changes: LibraryChanges(added: [id("daily/c.md")], modified: [id("b.md")], removed: [id("a.md")]),
            store: store)

        XCTAssertEqual(paths(updated.query("")), ["b.md", "daily/c.md"])
        XCTAssertEqual(paths(updated.query("changed")), ["b.md"])
        XCTAssertEqual(paths(updated.query("gamma")), ["daily/c.md"])
        XCTAssertEqual(paths(updated.query("alpha")), [])
        XCTAssertEqual(updated.entry(for: id("b.md"))?.modifiedAt, at(4))
        XCTAssertEqual(updated.entry(for: id("daily/c.md"))?.modifiedAt, at(3))
        // The incremental result equals a full rebuild of the same disk state.
        XCTAssertEqual(updated.entries, try buildFromDisk(store: store).entries)
    }

    func testX1_reportedNoteMissingOnDiskIsDropped() throws {
        try write("alpha", to: "a.md", minutes: 1)
        let store = NoteStore(root: root)
        let initial = try buildFromDisk(store: store)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.md"))
        let updated = initial.applying(
            changes: LibraryChanges(added: [id("never.md")], modified: [id("a.md")]), store: store)
        XCTAssertEqual(updated.count, 0)
    }

    func testL7_addedUnavailableNoteIsIndexedByTitleOnly() throws {
        try write("secret body", to: "evicted.md", minutes: 1)
        let store = NoteStore(root: root, isAvailable: { _ in false })
        let updated = SearchIndex.empty.applying(changes: LibraryChanges(added: [id("evicted.md")]), store: store)
        XCTAssertEqual(paths(updated.query("evicted")), ["evicted.md"])
        XCTAssertEqual(paths(updated.query("secret")), [])
        XCTAssertEqual(updated.entry(for: id("evicted.md"))?.modifiedAt, at(1))
        XCTAssertEqual(updated.entry(for: id("evicted.md"))?.body, "")
    }

    func testL8_modifiedNoteWithInvalidUTF8IsIndexedByTitleOnly() throws {
        try write("fine", to: "latin.md", minutes: 1)
        let store = NoteStore(root: root)
        let initial = try buildFromDisk(store: store)
        XCTAssertEqual(paths(initial.query("fine")), ["latin.md"])
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: root.appendingPathComponent("latin.md"))
        let updated = initial.applying(changes: LibraryChanges(modified: [id("latin.md")]), store: store)
        XCTAssertEqual(paths(updated.query("latin")), ["latin.md"])
        XCTAssertEqual(paths(updated.query("fine")), [])
        XCTAssertEqual(updated.entry(for: id("latin.md"))?.body, "")
    }

    func testModificationDateMatchesTheScanner() throws {
        try write("x", to: "daily/n.md", minutes: 5)
        let store = NoteStore(root: root)
        let scanned = try XCTUnwrap(LibraryScanner.scan(root: root).first)
        XCTAssertEqual(try store.modificationDate(of: id("daily/n.md")), scanned.modifiedAt)
        XCTAssertEqual(try store.modificationDate(of: id("daily/n.md")), at(5))
        XCTAssertThrowsError(try store.modificationDate(of: id("missing.md")))
    }
}
