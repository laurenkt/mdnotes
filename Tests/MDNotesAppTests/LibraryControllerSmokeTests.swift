import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// Headless smoke tests for `LibraryController`: it populates the list progressively from a
/// synthetic library (PF-7) and publishes every snapshot on the main thread (PF-6).
@MainActor
final class LibraryControllerSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// One published snapshot, as seen from the main thread.
    private struct Publish {
        let count: Int
        let phase: LibraryController.Phase
        let onMainThread: Bool
    }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-controller-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    /// Writes `body` to `relativePath` under the root, creating folders as needed.
    private func write(_ relativePath: String, body: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Starts `controller`, records every publish, and returns once `phase` is `.ready`
    /// or `.failed`. Fails the test if that takes longer than `timeout`.
    private func run(
        _ controller: LibraryController, timeout: TimeInterval = 30,
        observe: (@MainActor (SearchIndex) -> Void)? = nil
    ) async -> [Publish] {
        var publishes: [Publish] = []
        let finished = expectation(description: "population finished")
        var fulfilled = false
        controller.onSnapshotChange = { snapshot in
            publishes.append(Publish(count: snapshot.count, phase: controller.phase, onMainThread: Thread.isMainThread))
            observe?(snapshot)
            XCTAssertEqual(snapshot.count, controller.snapshot.count, "snapshot is replaced before the callback")
            switch controller.phase {
            case .ready, .failed:
                if !fulfilled {
                    fulfilled = true
                    finished.fulfill()
                }
            case .idle, .scanning, .indexing:
                break
            }
        }
        controller.start()
        await fulfillment(of: [finished], timeout: timeout)
        controller.onSnapshotChange = nil
        return publishes
    }

    // MARK: PF-7 progressive population, list count reaches N

    func testPF7_listCountReachesNWithSyntheticLibrary() async throws {
        let n = 1000
        let generated = try SyntheticLibrary.generate(at: root, options: .init(noteCount: n, largeNoteCount: 1))
        let controller = LibraryController(root: root, batchSize: 128)
        let publishes = await run(controller)

        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.snapshot.count, n)
        XCTAssertEqual(Set(controller.snapshot.entries.map(\.id.relativePath)), Set(generated))

        // Progressive: the very first snapshot already lists every note, before any body is read.
        let first = try XCTUnwrap(publishes.first)
        XCTAssertEqual(first.count, n)
        XCTAssertEqual(first.phase, .indexing(bodiesRead: 0, of: n))
        XCTAssertGreaterThan(publishes.count, 2, "bodies arrive in several batches")
        for publish in publishes {
            XCTAssertEqual(publish.count, n, "the list never shrinks while bodies fill in")
        }
        // Bodies are read in batches of the configured size, and the phase counts up to N.
        let batches = publishes.dropFirst().map(\.phase)
        XCTAssertEqual(batches.last, .ready)
        XCTAssertEqual(batches.first, .indexing(bodiesRead: 128, of: n))
        XCTAssertEqual(batches.count, (n + 127) / 128)
    }

    func testPF7_bodiesBecomeSearchableProgressivelyMostRecentFirst() async throws {
        // Ten notes, each body carrying a word that no title contains. The newest note's body
        // must be searchable in the first batch, the oldest only in the last.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<10 {
            try write("note \(i).md", body: "needle marker\(i)")
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(Double(i) * 60)],
                ofItemAtPath: root.appendingPathComponent("note \(i).md").path)
        }
        let controller = LibraryController(root: root, batchSize: 4)
        var needleHits: [Int] = []
        var newestHitAt: Int?
        var oldestHitAt: Int?
        let publishes = await run(controller) { snapshot in
            let hits = snapshot.query("needle").count
            needleHits.append(hits)
            if newestHitAt == nil, snapshot.query("marker9").count == 1 { newestHitAt = needleHits.count }
            if oldestHitAt == nil, snapshot.query("marker0").count == 1 { oldestHitAt = needleHits.count }
        }

        XCTAssertEqual(publishes.map(\.count), [10, 10, 10, 10])
        XCTAssertEqual(needleHits, [0, 4, 8, 10], "titles first, then bodies in batches")
        XCTAssertEqual(newestHitAt, 2, "most recently modified bodies are read first (S-3)")
        XCTAssertEqual(oldestHitAt, 4)
        XCTAssertEqual(
            controller.snapshot.query("").map(\.id.title),
            (0..<10).reversed().map { "note \($0)" })
    }

    // MARK: PF-6 main-thread publishing

    func testPF6_everySnapshotIsPublishedOnTheMainThread() async throws {
        try SyntheticLibrary.generate(at: root, options: .init(noteCount: 50, largeNoteCount: 0))
        let controller = LibraryController(root: root, batchSize: 10)
        let publishes = await run(controller)
        XCTAssertEqual(publishes.count, 6)
        XCTAssertTrue(publishes.allSatisfy(\.onMainThread))
        XCTAssertEqual(controller.snapshot.count, 50)
    }

    func testPF6_startReturnsBeforeTheScanHasPublished() throws {
        try SyntheticLibrary.generate(at: root, options: .init(noteCount: 50, largeNoteCount: 0))
        let controller = LibraryController(root: root)
        controller.start()
        // Nothing reaches the main thread until it spins the run loop.
        XCTAssertEqual(controller.phase, .scanning)
        XCTAssertEqual(controller.snapshot.count, 0)
        controller.stop()
    }

    // MARK: Empty and missing roots

    func testEmptyRootIsReadyWithNoNotes() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let controller = LibraryController(root: root)
        let publishes = await run(controller)
        XCTAssertEqual(publishes.map(\.count), [0])
        XCTAssertEqual(controller.phase, .ready)
    }

    func testMissingRootFails() async {
        let controller = LibraryController(root: root)
        let publishes = await run(controller)
        XCTAssertEqual(publishes.count, 1)
        XCTAssertEqual(controller.snapshot.count, 0)
        guard case .failed = controller.phase else { return XCTFail("expected .failed, got \(controller.phase)") }
    }

    // MARK: stop() and restart

    func testStopDropsSnapshotsInFlight() async throws {
        try SyntheticLibrary.generate(at: root, options: .init(noteCount: 200, largeNoteCount: 0))
        let controller = LibraryController(root: root, batchSize: 20)
        var published = 0
        controller.onSnapshotChange = { _ in published += 1 }
        controller.start()
        controller.stop()
        XCTAssertEqual(controller.phase, .idle)
        // Let anything the background queue already produced reach the main thread.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(published, 0)
        XCTAssertEqual(controller.snapshot.count, 0)
        XCTAssertEqual(controller.phase, .idle)

        // A restart populates from scratch.
        let publishes = await run(controller)
        XCTAssertEqual(controller.snapshot.count, 200)
        XCTAssertEqual(publishes.first?.count, 200)
    }

    // MARK: X-1 changes applied through the controller

    func testX1_appliedChangesPublishANewSnapshot() async throws {
        try SyntheticLibrary.generate(at: root, options: .init(noteCount: 30, largeNoteCount: 0))
        let controller = LibraryController(root: root)
        _ = await run(controller)
        XCTAssertEqual(controller.snapshot.count, 30)

        try write("daily/fresh.md", body: "a brand new xylophone")
        let added = expectation(description: "added")
        controller.onSnapshotChange = { _ in added.fulfill() }
        controller.apply(LibraryChanges(added: [NoteID(relativePath: "daily/fresh.md")]))
        await fulfillment(of: [added], timeout: 10)
        XCTAssertEqual(controller.snapshot.count, 31)
        XCTAssertEqual(controller.snapshot.query("xylophone").map(\.id.relativePath), ["daily/fresh.md"])
        XCTAssertEqual(controller.phase, .ready)

        try FileManager.default.removeItem(at: root.appendingPathComponent("daily/fresh.md"))
        let removed = expectation(description: "removed")
        controller.onSnapshotChange = { _ in removed.fulfill() }
        controller.apply(LibraryChanges(removed: [NoteID(relativePath: "daily/fresh.md")]))
        await fulfillment(of: [removed], timeout: 10)
        XCTAssertEqual(controller.snapshot.count, 30)
        XCTAssertEqual(controller.snapshot.query("xylophone").count, 0)
    }

    func testX1_changeDuringPopulationIsNotOverwrittenByALaterBatch() async throws {
        // 40 notes in 4 batches. Before the first batch runs, one of the oldest notes (so it
        // is in the last batch) is rewritten and the change applied. The batch must not put
        // the scanned, stale version back.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<40 {
            try write("n\(i).md", body: "original \(i)")
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(Double(i) * 60)],
                ofItemAtPath: root.appendingPathComponent("n\(i).md").path)
        }
        let controller = LibraryController(root: root, batchSize: 10)
        let target = NoteID(relativePath: "n0.md")
        try write("n0.md", body: "rewritten quokka")
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(3600)],
            ofItemAtPath: root.appendingPathComponent("n0.md").path)

        let finished = expectation(description: "ready")
        controller.onSnapshotChange = { _ in
            if controller.phase == .ready { finished.fulfill() }
        }
        controller.start()
        controller.apply(LibraryChanges(modified: [target]))
        await fulfillment(of: [finished], timeout: 30)

        XCTAssertEqual(controller.snapshot.count, 40)
        XCTAssertEqual(controller.snapshot.query("quokka").map(\.id), [target])
        XCTAssertEqual(controller.snapshot.query("").first?.id, target, "the fresh mtime puts it first (S-3)")
        XCTAssertEqual(controller.snapshot.entry(for: target)?.modifiedAt, base.addingTimeInterval(3600))
    }
}
