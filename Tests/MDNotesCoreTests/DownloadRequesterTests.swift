import Foundation
import MDNotesCore
import Synchronization
import XCTest

/// Covers L-9 (ADR-0009): a download request for every dataless note, at most once per note
/// per 60 s, repeated when a note is evicted again.
final class DownloadRequesterTests: XCTestCase {
    /// The mutable side of the harness, a class so closures can capture it by reference.
    private final class State: Sendable {
        let dataless = Mutex<Set<String>>([])
        let now = Mutex<Date>(Date(timeIntervalSinceReferenceDate: 1_000_000))
        let requested = Mutex<[NoteID]>([])
    }

    /// A library whose eviction state and clock the test controls. No file needs to exist:
    /// availability is answered by the injected probe, never by the disk.
    private final class Harness: Sendable {
        let state = State()
        let requester: DownloadRequester

        init() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mdnotes-download-\(UUID().uuidString)", isDirectory: true)
            let state = self.state
            let store = NoteStore(root: root) { url in
                !state.dataless.withLock { $0.contains(url.lastPathComponent) }
            }
            requester = DownloadRequester(
                store: store,
                clock: { state.now.withLock { $0 } },
                request: { id in state.requested.withLock { $0.append(id) } })
        }

        var requested: [NoteID] { state.requested.withLock { $0 } }

        func evict(_ names: String...) {
            state.dataless.withLock { $0.formUnion(names) }
        }

        func restore(_ names: String...) {
            state.dataless.withLock { $0.subtract(names) }
        }

        func advance(by seconds: TimeInterval) {
            state.now.withLock { $0 = $0.addingTimeInterval(seconds) }
        }

        /// Runs one pass and returns the ids requested during it.
        func pass(_ notes: [ScannedNote]) -> [NoteID] {
            state.requested.withLock { $0.removeAll() }
            let returned = requester.requestDownloads(for: notes)
            let observed = requested
            XCTAssertEqual(returned, observed, "the returned ids must be exactly those requested")
            return observed
        }
    }

    private func notes(_ names: String...) -> [ScannedNote] {
        names.map { ScannedNote(id: NoteID(relativePath: $0), modifiedAt: .distantPast) }
    }

    private func ids(_ names: String...) -> [NoteID] {
        names.map { NoteID(relativePath: $0) }
    }

    // MARK: L-9

    func testL9_firstPassRequestsEveryDatalessNote() {
        let harness = Harness()
        harness.evict("a.md", "c.md")
        let requested = harness.pass(notes("a.md", "b.md", "c.md", "d.md"))
        XCTAssertEqual(Set(requested), Set(ids("a.md", "c.md")))
        XCTAssertEqual(harness.requester.outstandingCount, 2)
    }

    func testL9_readableNotesAreNeverRequested() {
        let harness = Harness()
        XCTAssertEqual(harness.pass(notes("a.md", "b.md")), [])
        XCTAssertEqual(harness.requester.outstandingCount, 0)
    }

    func testL9_secondPassWithinSixtySecondsRequestsNothing() {
        let harness = Harness()
        harness.evict("a.md", "b.md")
        let list = notes("a.md", "b.md")
        XCTAssertEqual(Set(harness.pass(list)), Set(ids("a.md", "b.md")))
        XCTAssertEqual(harness.pass(list), [])
        harness.advance(by: 59)
        XCTAssertEqual(harness.pass(list), [], "still inside the 60 s window")
        XCTAssertEqual(harness.requester.outstandingCount, 2, "the notes are still dataless and tracked")
    }

    func testL9_requestRepeatsOnceSixtySecondsHavePassed() {
        let harness = Harness()
        harness.evict("a.md")
        let list = notes("a.md")
        XCTAssertEqual(harness.pass(list), ids("a.md"))
        harness.advance(by: DownloadRequester.minimumInterval)
        XCTAssertEqual(harness.pass(list), ids("a.md"), "a note still dataless after 60 s is asked for again")
        XCTAssertEqual(harness.pass(list), [], "and the window starts over")
    }

    func testL9_newlyEvictedNoteIsRequestedWhileOthersWait() {
        let harness = Harness()
        harness.evict("a.md")
        let list = notes("a.md", "b.md")
        XCTAssertEqual(harness.pass(list), ids("a.md"))
        harness.evict("b.md")
        harness.advance(by: 5)
        XCTAssertEqual(harness.pass(list), ids("b.md"), "only the note that just became dataless")
    }

    func testL9_reEvictedNoteIsRequestedAgainWithinTheWindow() {
        let harness = Harness()
        harness.evict("a.md")
        let list = notes("a.md")
        XCTAssertEqual(harness.pass(list), ids("a.md"))

        // Downloaded: the pass sees it readable and drops its record.
        harness.restore("a.md")
        harness.advance(by: 5)
        XCTAssertEqual(harness.pass(list), [])
        XCTAssertEqual(harness.requester.outstandingCount, 0)

        // Evicted again 10 s after the first request: the rate limit is per eviction, so the
        // request is repeated at once (L-9).
        harness.evict("a.md")
        harness.advance(by: 5)
        XCTAssertEqual(harness.pass(list), ids("a.md"))
        XCTAssertEqual(harness.pass(list), [], "and is rate-limited again from here")
    }

    func testL9_noteMissingFromTheListDropsItsRecord() {
        let harness = Harness()
        harness.evict("a.md", "b.md")
        XCTAssertEqual(Set(harness.pass(notes("a.md", "b.md"))), Set(ids("a.md", "b.md")))
        XCTAssertEqual(harness.pass(notes("a.md")), [])
        XCTAssertEqual(harness.requester.outstandingCount, 1, "b.md left the library; its record goes too")
        // Back in the list (recreated or restored from the Trash) while still dataless: asked
        // for again, since nothing is known about it any more.
        XCTAssertEqual(harness.pass(notes("a.md", "b.md")), ids("b.md"))
    }

    func testL9_enqueueRunsThePassOffTheCallingThread() {
        let harness = Harness()
        harness.evict("a.md")
        let done = expectation(description: "pass completed")
        let onMain = Mutex<Bool?>(nil)
        harness.requester.enqueue(notes("a.md")) { requested in
            onMain.withLock { $0 = Thread.isMainThread }
            XCTAssertEqual(requested, [NoteID(relativePath: "a.md")])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(onMain.withLock { $0 }, false, "the probe must not run on the main thread (PF-6)")
        XCTAssertEqual(harness.requested, ids("a.md"))
    }

    func testL9_defaultRequestAsksTheStoreAndIsHarmlessForOrdinaryFiles() throws {
        // With no injected request, the requester calls `NoteStore.requestDownload`, which is
        // a no-op outside an iCloud container. The probe is forced to "dataless" so the call
        // is actually made; nothing may throw or crash.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("plain.md"))
        let store = NoteStore(root: root, isAvailable: { _ in false })
        let requester = DownloadRequester(store: store)
        XCTAssertEqual(requester.requestDownloads(for: notes("plain.md", "missing.md")), ids("plain.md", "missing.md"))
    }
}
