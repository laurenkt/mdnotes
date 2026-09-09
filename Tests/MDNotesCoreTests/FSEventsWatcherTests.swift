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
                acc.images.formUnion(next.images)
            }
        }

        /// How many batches so far named the image at root-relative `path`.
        func reports(ofImage path: String) -> Int {
            all.filter { $0.images.contains(path) }.count
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

    /// Writes `body` at `relativePath`, creating folders as needed.
    private func write(_ relativePath: String, _ body: String = "body") throws {
        try FileManager.default.createDirectory(
            at: url(relativePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url(relativePath))
    }

    /// Starts a watcher on the root with the recorder as handler, after letting the disk settle.
    ///
    /// FSEvents replays a change made just before the stream starts as its first event. For a
    /// fixture note that would be a spurious modification. For the root itself, created in
    /// `setUp` moments earlier and replayed in nearly every run without this pause (56 of 60
    /// measured; none with a 50 ms pause), it makes the watcher scan the root, and on a loaded
    /// machine that scan can run after the test has written its first note: the scan reports
    /// the note as added, and the note's own event, delivered next, finds it known and reports
    /// it as modified (I-4). Every test starts from a fresh root, so every start pauses.
    private func startWatching(knownNotes: Set<NoteID>? = nil, latency: TimeInterval = 0.05) throws {
        Thread.sleep(forTimeInterval: 0.2)
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
        XCTAssertEqual(union.modified, [], "\(recorder.all)")
        XCTAssertEqual(union.removed, [], "\(recorder.all)")
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
    ///
    /// Which release turns out to be the last is a matter of thread timing, so one round only
    /// sometimes exercises the path; forty rounds at zero latency reached it in most runs before
    /// the fix (I-2), and the whole loop takes about half a second.
    func testX1_ownerMayDropTheWatcherWhileItsHandlerRuns() throws {
        /// Held only by the handler, so it goes when the watcher does.
        final class Token: Sendable {
            let onDeinit: @Sendable () -> Void
            init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }
        let owner = Mutex<FSEventsWatcher?>(nil)
        func startOwnedWatcher(handled: XCTestExpectation, deallocated: XCTestExpectation) throws {
            let token = Token { deallocated.fulfill() }
            let watcher = FSEventsWatcher(root: root, knownNotes: [], latency: 0) { _ in
                withExtendedLifetime(token) {}
                // The owner lets go while this callback is on the watcher's queue.
                owner.withLock { $0 = nil }
                handled.fulfill()
            }
            try watcher.start()
            owner.withLock { $0 = watcher }
        }
        for round in 0..<40 {
            let handled = expectation(description: "handler ran, round \(round)")
            handled.assertForOverFulfill = false
            let deallocated = expectation(description: "watcher deallocated, round \(round)")
            try startOwnedWatcher(handled: handled, deallocated: deallocated)
            try write("fresh-\(round).md")
            wait(for: [handled, deallocated], timeout: timeout)
            XCTAssertNil(owner.withLock { $0 }, "round \(round)")
        }
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

    func testX1_caseOnlyRenameIsRemovalPlusAddition() throws {
        try write("Before.md")
        try startWatching()
        // On a case-insensitive volume the old path still reaches the file; the old id is gone
        // all the same (L-4, R-2).
        XCTAssertEqual(rename(url("Before.md").path, url("before.md").path), 0)
        waitFor("rename Before.md -> before.md") {
            $0.removed.contains(self.id("Before.md")) && $0.added.contains(self.id("before.md"))
        }
        XCTAssertEqual(recorder.union.modified, [])
        XCTAssertFalse(try XCTUnwrap(watcher).knownNotes.contains(id("Before.md")))
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

    // MARK: X-1, X-2: a note the folder scan is ahead of is reported once

    /// A folder event's scan judges the disk as it is when the callback runs, which can be ahead
    /// of the event stream: a note written after the folder event, but before the callback
    /// runs, is on disk for the scan, and its own event is still to come. The scan reports it
    /// added; the event must then not report it modified, or the note is read twice and an open
    /// note reloaded once more than needed (X-2, I-5).
    ///
    /// The window is forced open by holding the watcher's queue in the callback for a warm-up
    /// note while the folder is created and, one latency later, the note under it is written.
    /// FSEvents delivers the two as separate batches once the queue is free.
    func testX2_noteWrittenBehindAFolderEventIsReportedOnce() throws {
        let latency: TimeInterval = 0.05
        let recorder = recorder
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let warm = id("warm.md")
        Thread.sleep(forTimeInterval: 0.2)  // settle, as `startWatching` does
        let watcher = FSEventsWatcher(root: root, knownNotes: [], latency: latency) { changes in
            recorder.record(changes)
            if changes.added.contains(warm) {
                held.signal()
                release.wait()
            }
        }
        try watcher.start()
        self.watcher = watcher

        try write("warm.md")
        XCTAssertEqual(held.wait(timeout: .now() + timeout), .success, "the warm-up batch never arrived")
        try FileManager.default.createDirectory(at: url("sub"), withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: latency * 6)
        try write("sub/late.md")
        release.signal()

        waitFor("sub/late.md reported") {
            $0.added.contains(self.id("sub/late.md")) || $0.modified.contains(self.id("sub/late.md"))
        }
        // Give the note's own event time to arrive in a batch of its own.
        recorder.wait(timeout: 1) { _ in false }
        XCTAssertEqual(recorder.union.added, [warm, id("sub/late.md")], "\(recorder.all)")
        XCTAssertEqual(recorder.union.modified, [], "the scan already reported it: \(recorder.all)")
        XCTAssertEqual(recorder.union.removed, [], "\(recorder.all)")
    }

    /// The same window, but the note is edited again after the scan and before its events
    /// arrive: that edit is news and must be reported.
    func testX2_noteEditedAfterTheScanIsStillReportedModified() throws {
        let latency: TimeInterval = 0.05
        let recorder = recorder
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let warm = id("warm.md")
        Thread.sleep(forTimeInterval: 0.2)
        let watcher = FSEventsWatcher(root: root, knownNotes: [], latency: latency) { changes in
            recorder.record(changes)
            if changes.added.contains(warm) {
                held.signal()
                release.wait()
            }
        }
        try watcher.start()
        self.watcher = watcher

        try write("warm.md")
        XCTAssertEqual(held.wait(timeout: .now() + timeout), .success, "the warm-up batch never arrived")
        try FileManager.default.createDirectory(at: url("sub"), withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: latency * 6)
        try write("sub/late.md", "one")
        release.signal()
        waitFor("sub/late.md added") { $0.added.contains(self.id("sub/late.md")) }
        // Written after the scan reported it, with a modification date the scan did not see.
        Thread.sleep(forTimeInterval: latency * 6)
        try write("sub/late.md", "two")
        waitFor("sub/late.md modified") { $0.modified.contains(self.id("sub/late.md")) }
    }

    // MARK: X-1 with L-2, L-3, L-6: only notes are reported as notes

    func testX1_nonNotesAndSkippedPathsAreNotReportedAsNotes() throws {
        try startWatching()
        try write("readme.txt")
        try write("note.md.bak")
        try write(".hidden.md")
        try write(".obsidian/workspace.md")
        try write("Trash/old.md")
        try write("templates/daily.md")
        try write("i/picture.png")
        try write("i/.hidden.png")
        try write(".cache/thumb.png")
        try write("deep/.secret/x.md")
        try write("sentinel.md")
        waitFor("sentinel") { $0.added.contains(self.id("sentinel.md")) }
        // Give any stray event for the other files time to arrive.
        recorder.wait(timeout: 0.5) { _ in false }
        let union = recorder.union
        XCTAssertEqual(union.added, [id("sentinel.md")], "\(recorder.all)")
        XCTAssertEqual(union.modified, [], "\(recorder.all)")
        XCTAssertEqual(union.removed, [], "\(recorder.all)")
        // S-11: the one image that is not hidden is reported by path, and as nothing else.
        XCTAssertEqual(union.images, ["i/picture.png"], "\(recorder.all)")
        XCTAssertEqual(try XCTUnwrap(watcher).knownNotes, [id("sentinel.md")])
    }

    // MARK: X-1 with S-11, E-9: image files are reported by path

    func testX1_imageFilesAreReportedByPathWhenTheyArriveChangeAndGo() throws {
        let latency = 0.05
        try startWatching(latency: latency)
        try write("i/late.png", "one")
        waitFor("i/late.png arrived") { $0.images.contains("i/late.png") }
        XCTAssertEqual(recorder.reports(ofImage: "i/late.png"), 1, "\(recorder.all)")
        XCTAssertTrue(recorder.all.allSatisfy { $0.added.isEmpty && $0.modified.isEmpty && $0.removed.isEmpty })

        // Changed: reported again, though the watcher has seen it.
        Thread.sleep(forTimeInterval: latency * 6)
        try write("i/late.png", "two")
        XCTAssertTrue(
            recorder.wait(timeout: timeout) { _ in recorder.reports(ofImage: "i/late.png") >= 2 },
            "the change was not reported: \(recorder.all)")

        // Gone: reported once more, by the path that no longer exists.
        Thread.sleep(forTimeInterval: latency * 6)
        try FileManager.default.removeItem(at: url("i/late.png"))
        XCTAssertTrue(
            recorder.wait(timeout: timeout) { _ in recorder.reports(ofImage: "i/late.png") >= 3 },
            "the removal was not reported: \(recorder.all)")

        // An image anywhere under the root, by any image extension, is one; a note is not.
        try write("assets/photo.jpg")
        try write("sentinel.md")
        waitFor("assets/photo.jpg and the sentinel") {
            $0.images.contains("assets/photo.jpg") && $0.added.contains(self.id("sentinel.md"))
        }
        XCTAssertEqual(recorder.union.images, ["i/late.png", "assets/photo.jpg"])
        XCTAssertEqual(try XCTUnwrap(watcher).knownNotes, [id("sentinel.md")], "an image is never a known note")
        XCTAssertTrue(recorder.all.allSatisfy { !$0.isEmpty }, "an image-only batch is not empty")
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
