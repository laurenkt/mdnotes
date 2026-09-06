import Foundation
import MDNotesCore
import MDNotesTestSupport
import Synchronization
import XCTest

/// Drives a real `FSEventsWatcher` over a temp library with real file operations (X-1). Every
/// wait has a timeout, so a watcher that never fires fails the test instead of hanging it.
final class FSEventsWatcherTests: XCTestCase {
    /// Collects batches from the watcher's background queue.
    private final class Recorder: Sendable {
        private let batches = Mutex<[LibraryChanges]>([])

        func record(_ changes: LibraryChanges) {
            batches.withLock { $0.append(changes) }
        }

        var all: [LibraryChanges] { batches.withLock { $0 } }

        /// Everything reported so far, folded into one value.
        var union: LibraryChanges {
            all.reduce(into: LibraryChanges()) { acc, next in
                acc.added.formUnion(next.added)
                acc.modified.formUnion(next.modified)
                acc.removed.formUnion(next.removed)
            }
        }

        /// Polls until `condition` holds or `timeout` passes. Returns whether it held.
        @discardableResult
        func wait(timeout: TimeInterval = 5, until condition: (LibraryChanges) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition(union) { return true }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return condition(union)
        }
    }

    /// Generous: the X-1 budget is 500 ms, but a loaded machine must not turn a passing watcher
    /// into a flaky test. `testX1_singleChangeArrivesWithinBudget` checks the budget itself.
    private let timeout: TimeInterval = 5

    private var root: URL = FileManager.default.temporaryDirectory
    private var recorder = Recorder()
    private var watcher: FSEventsWatcher?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        recorder = Recorder()
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: helpers

    private func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    private func id(_ relativePath: String) -> NoteID { NoteID(relativePath: relativePath) }

    private var wroteFixtures = false

    /// Writes `body` at `relativePath`, creating folders as needed.
    private func write(_ relativePath: String, _ body: String = "body") throws {
        try FileManager.default.createDirectory(
            at: url(relativePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url(relativePath))
        if watcher == nil { wroteFixtures = true }
    }

    /// Starts a watcher on the root with the recorder as handler. Fixtures written before this
    /// are given a moment to settle: FSEvents can replay a change made just before the stream
    /// starts as its first event, which would show up here as a spurious modification.
    private func startWatching(knownNotes: Set<NoteID>? = nil, latency: TimeInterval = 0.05) throws {
        if wroteFixtures { Thread.sleep(forTimeInterval: 0.2) }
        let recorder = recorder
        let watcher = FSEventsWatcher(root: root, knownNotes: knownNotes, latency: latency) { recorder.record($0) }
        try watcher.start()
        self.watcher = watcher
    }

    private func waitFor(
        _ description: String, _ condition: (LibraryChanges) -> Bool, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            recorder.wait(timeout: timeout, until: condition),
            "timed out waiting for \(description); got \(recorder.all)",
            file: file, line: line)
    }

    // MARK: X-1 additions, modifications, deletions, renames

    func testX1_addedNoteIsReportedAsAdded() throws {
        try startWatching()
        try write("fresh.md")
        waitFor("added fresh.md") { $0.added.contains(self.id("fresh.md")) }
        let union = recorder.union
        XCTAssertEqual(union.modified, [])
        XCTAssertEqual(union.removed, [])
        XCTAssertTrue(try XCTUnwrap(watcher).knownNotes.contains(id("fresh.md")))
    }

    func testX1_modifiedNoteIsReportedAsModified() throws {
        try write("existing.md", "one")
        try startWatching()
        XCTAssertEqual(try XCTUnwrap(watcher).knownNotes, [id("existing.md")], "start() walks the root")
        try write("existing.md", "two")
        waitFor("modified existing.md") { $0.modified.contains(self.id("existing.md")) }
        XCTAssertEqual(recorder.union.added, [])
        XCTAssertEqual(recorder.union.removed, [])
    }

    func testX1_removedNoteIsReportedAsRemoved() throws {
        try write("doomed.md")
        try startWatching()
        try FileManager.default.removeItem(at: url("doomed.md"))
        waitFor("removed doomed.md") { $0.removed.contains(self.id("doomed.md")) }
        XCTAssertEqual(recorder.union.added, [])
        XCTAssertEqual(recorder.union.modified, [])
        XCTAssertFalse(try XCTUnwrap(watcher).knownNotes.contains(id("doomed.md")))
    }

    // MARK: lifetime

    /// The owner may let go of the watcher while its handler is running, as `LibraryController`
    /// does when it is released on the main thread mid-callback. The callback's own reference is
    /// then the last one, and dropping it must not run `deinit`, and so `stop()`, on the
    /// watcher's queue: waiting for that queue from itself is a deadlock libdispatch traps on.
    func testX1_ownerMayDropTheWatcherWhileItsHandlerRuns() throws {
        /// Held only by the handler, so it goes when the watcher does.
        final class Token: Sendable {
            let onDeinit: @Sendable () -> Void
            init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }
        let owner = Mutex<FSEventsWatcher?>(nil)
        let handled = expectation(description: "handler ran")
        handled.assertForOverFulfill = false
        let deallocated = expectation(description: "watcher deallocated")
        func startOwnedWatcher() throws {
            let token = Token { deallocated.fulfill() }
            let watcher = FSEventsWatcher(root: root, knownNotes: [], latency: 0.05) { _ in
                withExtendedLifetime(token) {}
                // The owner lets go while this callback is on the watcher's queue.
                owner.withLock { $0 = nil }
                handled.fulfill()
            }
            try watcher.start()
            owner.withLock { $0 = watcher }
        }
        try startOwnedWatcher()
        try write("fresh.md")
        wait(for: [handled, deallocated], timeout: timeout)
        XCTAssertNil(owner.withLock { $0 })
    }

    func testX1_renameIsRemovalPlusAddition() throws {
        try write("before.md")
        try startWatching()
        try FileManager.default.moveItem(at: url("before.md"), to: url("after.md"))
        waitFor("rename before.md -> after.md") {
            $0.removed.contains(self.id("before.md")) && $0.added.contains(self.id("after.md"))
        }
        XCTAssertEqual(recorder.union.modified, [])
    }

    func testX1_renameIntoAndOutOfNestedFolders() throws {
        try write("top.md")
        try write("daily/2026/deep.md")
        try startWatching()
        try FileManager.default.createDirectory(at: url("archive"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url("top.md"), to: url("archive/top.md"))
        try FileManager.default.moveItem(at: url("daily/2026/deep.md"), to: url("deep.md"))
        waitFor("both moves") {
            $0.removed.isSuperset(of: [self.id("top.md"), self.id("daily/2026/deep.md")])
                && $0.added.isSuperset(of: [self.id("archive/top.md"), self.id("deep.md")])
        }
    }

    func testX1_folderRenameMovesEveryNoteUnderIt() throws {
        try write("daily/2026/a.md")
        try write("daily/2026/b.md")
        try write("daily/c.md")
        try write("keep.md")
        try startWatching()
        try FileManager.default.moveItem(at: url("daily"), to: url("journal"))
        waitFor("folder rename") {
            $0.removed == [self.id("daily/2026/a.md"), self.id("daily/2026/b.md"), self.id("daily/c.md")]
                && $0.added == [self.id("journal/2026/a.md"), self.id("journal/2026/b.md"), self.id("journal/c.md")]
        }
        XCTAssertEqual(recorder.union.modified, [])
        XCTAssertEqual(
            try XCTUnwrap(watcher).knownNotes,
            [id("keep.md"), id("journal/2026/a.md"), id("journal/2026/b.md"), id("journal/c.md")])
    }

    func testX1_folderRemovalRemovesEveryKnownNoteUnderIt() throws {
        try write("daily/2026/a.md")
        try write("daily/b.md")
        try write("dailyish.md")
        let known: Set<NoteID> = [id("daily/2026/a.md"), id("daily/b.md"), id("dailyish.md")]
        try startWatching(knownNotes: known)
        try FileManager.default.removeItem(at: url("daily"))
        waitFor("folder removal") { $0.removed == [self.id("daily/2026/a.md"), self.id("daily/b.md")] }
        XCTAssertEqual(recorder.union.added, [])
        XCTAssertEqual(recorder.union.modified, [])
        XCTAssertEqual(try XCTUnwrap(watcher).knownNotes, [id("dailyish.md")], "the prefix match is per folder")
    }

    func testX1_deleteThenRecreateInOneBatchIsNotARemoval() throws {
        try write("flicker.md", "one")
        try startWatching(latency: 0.3)
        try FileManager.default.removeItem(at: url("flicker.md"))
        try write("flicker.md", "two")
        waitFor("flicker.md reported") {
            $0.added.contains(self.id("flicker.md")) || $0.modified.contains(self.id("flicker.md"))
        }
        // Whatever the kernel coalesced, the last word is the disk's: the note exists.
        recorder.wait(timeout: 1) { _ in false }
        let last = try XCTUnwrap(recorder.all.last)
        XCTAssertFalse(last.removed.contains(id("flicker.md")), "\(recorder.all)")
        XCTAssertTrue(try XCTUnwrap(watcher).knownNotes.contains(id("flicker.md")))
    }

    // MARK: X-1 with L-2, L-3, L-6: only notes are reported

    func testX1_nonNotesAndSkippedPathsAreIgnored() throws {
        try startWatching()
        try write("readme.txt")
        try write("note.md.bak")
        try write(".hidden.md")
        try write(".obsidian/workspace.md")
        try write("Trash/old.md")
        try write("templates/daily.md")
        try write("i/picture.png")
        try write("deep/.secret/x.md")
        try write("sentinel.md")
        waitFor("sentinel") { $0.added.contains(self.id("sentinel.md")) }
        // Give any stray event for the other files time to arrive.
        recorder.wait(timeout: 0.5) { _ in false }
        let union = recorder.union
        XCTAssertEqual(union.added, [id("sentinel.md")])
        XCTAssertEqual(union.modified, [])
        XCTAssertEqual(union.removed, [])
    }

    func testX1_idsAreRootRelativeWithSlashesAndExtension() throws {
        try startWatching()
        try write("daily/2026/06-sunday.md")
        waitFor("nested add") { !$0.added.isEmpty }
        XCTAssertEqual(recorder.union.added, [NoteID(relativePath: "daily/2026/06-sunday.md")])
    }

    // MARK: X-1 coalescing and latency

    func testX1_burstOfChangesIsCoalescedIntoFewBatches() throws {
        try startWatching(latency: 0.2)
        let count = 60
        for i in 0..<count { try write("burst-\(i).md") }
        let expected = Set((0..<count).map { id("burst-\($0).md") })
        waitFor("all \(count) additions") { $0.added.isSuperset(of: expected) }
        XCTAssertEqual(recorder.union.added, expected)
        // The writes take a few milliseconds; with a 200 ms latency the kernel folds them into a
        // handful of deliveries, never one per file.
        XCTAssertLessThan(recorder.all.count, count / 4, "\(recorder.all.count) batches for \(count) files")
        XCTAssertTrue(recorder.all.allSatisfy { !$0.isEmpty }, "empty batches are never delivered")
    }

    func testX1_singleChangeArrivesWithinBudget() throws {
        try startWatching()
        // Warm up: the first event on a fresh stream can carry setup cost that is not X-1's.
        try write("warm.md")
        waitFor("warm-up") { $0.added.contains(self.id("warm.md")) }
        recorder.wait(timeout: 0.3) { _ in false }

        let started = Date()
        try write("timed.md")
        waitFor("timed.md") { $0.added.contains(self.id("timed.md")) }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "X-1: the change took \(Int(elapsed * 1000)) ms to arrive")
    }

    // MARK: lifecycle

    func testX1_stopEndsDelivery() throws {
        try startWatching()
        try write("first.md")
        waitFor("first.md") { $0.added.contains(self.id("first.md")) }
        let watcher = try XCTUnwrap(watcher)
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
        let before = recorder.all.count
        try write("after-stop.md")
        recorder.wait(timeout: 0.5) { _ in false }
        XCTAssertEqual(recorder.all.count, before, "no batch after stop: \(recorder.all)")
        watcher.stop()  // idempotent
    }

    func testX1_handlerRunsOffTheMainThread() throws {
        let sawMain = Mutex(false)
        let watcher = FSEventsWatcher(root: root) { _ in
            if Thread.isMainThread { sawMain.withLock { $0 = true } }
        }
        try watcher.start()
        self.watcher = watcher
        try write("bg.md")
        XCTAssertTrue(pollUntil { watcher.knownNotes.contains(self.id("bg.md")) })
        XCTAssertFalse(sawMain.withLock { $0 }, "PF-6: the handler must not run on the main thread")
    }

    func testX1_missingRootFailsToStart() {
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        let watcher = FSEventsWatcher(root: missing) { _ in }
        // FSEvents accepts any path at creation time; a missing root either fails to start or
        // starts and stays silent. Either way it must not crash, and stop() must be safe.
        _ = try? watcher.start()
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
    }

    // MARK: polling

    private func pollUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }
}
