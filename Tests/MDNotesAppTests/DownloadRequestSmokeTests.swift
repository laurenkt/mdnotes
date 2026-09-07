import Foundation
import MDNotesApp
import MDNotesCore
import Synchronization
import XCTest

/// Headless smoke tests for proactive download (L-9, ADR-0009): `LibraryController` asks for
/// every dataless note after its scan and after every watcher batch, without any note being
/// opened. Eviction is simulated through the store's availability probe, since a real
/// placeholder cannot be fabricated outside an iCloud container, and the request itself is
/// captured instead of going to iCloud.
@MainActor
final class DownloadRequestSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "alpha body"),
        ("daily/Beta.md", "beta body"),
        ("Gamma.md", "gamma body"),
    ]

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")
    private let delta = NoteID(relativePath: "Delta.md")

    /// What the test controls and observes: which files are evicted, and every request made.
    private final class Cloud: Sendable {
        let dataless = Mutex<Set<String>>([])
        let requests = Mutex<[(id: NoteID, onMainThread: Bool)]>([])

        func evict(_ ids: NoteID...) {
            dataless.withLock { $0.formUnion(ids.map(\.relativePath)) }
        }

        func restore(_ ids: NoteID...) {
            dataless.withLock { $0.subtract(ids.map(\.relativePath)) }
        }

        var requested: [NoteID] { requests.withLock { $0.map(\.id) } }
    }

    private let cloud = Cloud()

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-download-\(UUID().uuidString)", isDirectory: true)
        for note in Self.notes {
            try write(note.path, body: note.body)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func write(_ relativePath: String, body: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A controller whose store answers availability from `cloud` and whose download requests
    /// land in `cloud` instead of iCloud. The probe never reads the file: a note listed as
    /// dataless is indexed by title only (L-7), as an evicted placeholder would be.
    private func makeController(watchesFileSystem: Bool) -> LibraryController {
        let cloud = cloud
        let root = root
        return LibraryController(
            root: root, watchesFileSystem: watchesFileSystem,
            availability: { url in
                let relativePath = String(url.path.dropFirst(root.path.count + 1))
                return !cloud.dataless.withLock { $0.contains(relativePath) }
            },
            requestDownload: { id in
                cloud.requests.withLock { $0.append((id, Thread.isMainThread)) }
            })
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: L-9 after the initial scan

    func testL9_datalessNotesAreRequestedAfterTheInitialScanWithoutOpeningANote() async {
        cloud.evict(alpha, gamma)
        let library = makeController(watchesFileSystem: false)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        await waitUntil("both dataless notes requested") { Set(self.cloud.requested) == [self.alpha, self.gamma] }

        // No editor, no window, nothing selected: the requests came from the scan alone.
        XCTAssertEqual(Set(cloud.requested), [alpha, gamma])
        XCTAssertEqual(cloud.requested.count, 2, "one request per dataless note, none for the readable one")
        XCTAssertEqual(library.downloadRequester.outstandingCount, 2)
        XCTAssertFalse(
            cloud.requests.withLock { $0.contains { $0.onMainThread } }, "requests are made off the main thread (PF-6)"
        )
        // The evicted notes are listed by title only (L-7); the readable one has its body.
        XCTAssertEqual(Set(library.snapshot.entries.map(\.id)), [alpha, beta, gamma])
        XCTAssertEqual(library.snapshot.query("beta body").map(\.id), [beta])
        XCTAssertEqual(library.snapshot.query("alpha body").map(\.id), [])
    }

    func testL9_nothingIsRequestedWhenEveryNoteIsReadable() async {
        let library = makeController(watchesFileSystem: false)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(cloud.requested, [])
        XCTAssertEqual(library.downloadRequester.outstandingCount, 0)
    }

    // MARK: L-9 after a full rescan

    func testL9_restartRescansAndRequestsANoteEvictedMeanwhile() async {
        let library = makeController(watchesFileSystem: false)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(cloud.requested, [])

        cloud.evict(beta)
        library.start()
        await waitUntil("library ready again") { library.phase == .ready }
        await waitUntil("beta requested by the rescan") { self.cloud.requested == [self.beta] }
        XCTAssertEqual(cloud.requested, [beta])
    }

    // MARK: L-9 on every watcher batch

    func testL9_watcherBatchRequestsNotesEvictedAndAddedSinceTheScan() async throws {
        let library = makeController(watchesFileSystem: true)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertTrue(library.isWatching)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(cloud.requested, [], "everything was readable at the scan")

        // Alpha is evicted, and a new note arrives already evicted. The new file is what the
        // watcher reports; the pass that follows the batch probes every note, so both are
        // asked for, and neither was opened.
        cloud.evict(alpha, delta)
        try write(delta.relativePath, body: "delta body")
        await waitUntil("alpha and delta requested after the watcher batch") {
            Set(self.cloud.requested) == [self.alpha, self.delta]
        }
        XCTAssertEqual(cloud.requested.count, 2)
        XCTAssertEqual(library.downloadRequester.outstandingCount, 2)
        XCTAssertFalse(cloud.requests.withLock { $0.contains { $0.onMainThread } })

        // Downloaded again: the next batch sees alpha readable and drops its record, so a
        // later re-eviction is asked for at once (L-9) rather than waiting out the 60 s.
        cloud.restore(alpha)
        try write("Epsilon.md", body: "epsilon body")
        await waitUntil("alpha's record is dropped") { library.downloadRequester.outstandingCount == 1 }
        cloud.evict(alpha)
        try write("Zeta.md", body: "zeta body")
        await waitUntil("alpha requested again after re-eviction") {
            self.cloud.requested.filter { $0 == self.alpha }.count == 2
        }
        XCTAssertEqual(library.downloadRequester.outstandingCount, 2)
    }
}
