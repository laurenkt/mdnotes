import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import Synchronization
import XCTest

/// Headless smoke tests for the eviction bar (L-10, ADR-0009): a thin bar under the search
/// field while notes are dataless, with the count, the free space and a Storage Settings
/// button while the boot volume is nearly full, shown only once the scan is complete and gone
/// within 2 s of the last note being downloaded. Eviction and free space are simulated through
/// the library's injected probes, since neither can be fabricated in a temp directory.
///
/// Also renders the window with the bar showing to `build/snapshots/` (V-1).
@MainActor
final class EvictionBarSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "alpha body"),
        ("daily/Beta.md", "beta body"),
        ("Gamma.md", "gamma body"),
    ]

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")

    /// What the test controls: which files are evicted, and how full the boot volume is.
    private final class Cloud: Sendable {
        let dataless = Mutex<Set<String>>([])
        let freeBytes = Mutex<Int64?>(nil)

        func evict(_ ids: NoteID...) {
            dataless.withLock { $0.formUnion(ids.map(\.relativePath)) }
        }

        func restore(_ ids: NoteID...) {
            dataless.withLock { $0.subtract(ids.map(\.relativePath)) }
        }

        func setFreeBytes(_ bytes: Int64?) {
            freeBytes.withLock { $0 = bytes }
        }
    }

    private let cloud = Cloud()

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-eviction-\(UUID().uuidString)", isDirectory: true)
        for note in Self.notes {
            try write(note.path, body: note.body)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    private func write(_ relativePath: String, body: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let library: LibraryController
        var view: MainView { controller.mainView }
        var bar: EvictionBar { controller.mainView.evictionBar }
    }

    /// A laid-out window with a library attached whose availability, download requests and
    /// free space are answered by `cloud`. Not started: tests evict before the scan.
    private func makeFixture(watchesFileSystem: Bool = false, batchSize: Int = 2048) -> Fixture {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let cloud = cloud
        let root = root
        let library = LibraryController(
            root: root, batchSize: batchSize, watchesFileSystem: watchesFileSystem,
            availability: { url in
                let relativePath = String(url.path.dropFirst(root.path.count + 1))
                return !cloud.dataless.withLock { $0.contains(relativePath) }
            },
            requestDownload: { _ in },
            freeSpace: { cloud.freeBytes.withLock { $0 } })
        controller.attach(library)
        return Fixture(controller: controller, library: library)
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

    private func layout(_ fixture: Fixture) {
        fixture.view.layoutSubtreeIfNeeded()
    }

    // MARK: - L-10: shown and hidden

    func testL10_barIsNotShownDuringTheFirstScanAndShowsOnceItHasCompleted() async {
        cloud.evict(alpha, gamma)
        // One body per batch, so the scan publishes several times before it is ready.
        let fixture = makeFixture(batchSize: 1)
        XCTAssertTrue(fixture.bar.isHidden, "nothing is known before the scan")

        var shownBeforeReady = 0
        var publishes = 0
        let forward = fixture.library.onSnapshotChange
        fixture.library.onSnapshotChange = { snapshot in
            forward?(snapshot)
            publishes += 1
            if fixture.library.phase != .ready, !fixture.bar.isHidden { shownBeforeReady += 1 }
        }
        fixture.library.start()
        await waitUntil("bar shown") { !fixture.bar.isHidden }

        XCTAssertGreaterThan(publishes, 2, "the scan published progressively")
        XCTAssertEqual(shownBeforeReady, 0, "the bar is not shown during the first scan")
        XCTAssertEqual(fixture.library.phase, .ready)
        XCTAssertEqual(fixture.library.evictionStatus.datalessCount, 2)
        XCTAssertEqual(fixture.bar.datalessCount, 2)
        XCTAssertEqual(fixture.bar.label.stringValue, "2 notes not downloaded from iCloud. Search is incomplete.")
        XCTAssertTrue(fixture.bar.storageSettingsButton.isHidden, "free space unknown: no button")

        // Directly under the search field, full width, one thin line; the split below it.
        layout(fixture)
        let search = fixture.view.searchField.frame
        let bar = fixture.bar.frame
        XCTAssertEqual(bar.maxY, search.minY, accuracy: 0.5)
        XCTAssertEqual(bar.minX, 0, accuracy: 0.5)
        XCTAssertEqual(bar.width, search.width, accuracy: 0.5)
        XCTAssertEqual(bar.height, EvictionBar.height, accuracy: 0.5)
        XCTAssertEqual(fixture.view.splitView.frame.maxY, bar.minY, accuracy: 0.5)
        XCTAssertTrue(fixture.view.messageLabel.isHidden)
    }

    func testL10_barIsHiddenWhenEveryNoteIsReadable() async {
        let fixture = makeFixture()
        fixture.library.start()
        await waitUntil("library ready") { fixture.library.phase == .ready }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.bar.isHidden)
        XCTAssertNil(fixture.bar.datalessCount)
        XCTAssertEqual(fixture.library.evictionStatus, .none)
        layout(fixture)
        XCTAssertEqual(fixture.view.splitView.frame.maxY, fixture.view.searchField.frame.minY, accuracy: 0.5)
    }

    func testL10_barHidesWithinTwoSecondsOfTheLastNoteBecomingReadable() async {
        cloud.evict(alpha, beta)
        let fixture = makeFixture()
        fixture.library.start()
        await waitUntil("bar shown for two notes") { fixture.bar.datalessCount == 2 }
        XCTAssertEqual(fixture.library.snapshot.query("alpha body").map(\.id), [], "dataless: title only (L-7)")

        // One downloaded: the count drops to one, singular, within the poll interval.
        cloud.restore(alpha)
        var started = Date()
        await waitUntil("bar shows one note") { fixture.bar.datalessCount == 1 }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(fixture.bar.isHidden)
        XCTAssertEqual(fixture.bar.label.stringValue, "1 note not downloaded from iCloud. Search is incomplete.")
        // The downloaded note's body joins the index (L-7, L-9).
        await waitUntil("alpha's body indexed") {
            fixture.library.snapshot.query("alpha body").map(\.id) == [self.alpha]
        }

        // The last one downloaded: the bar is gone within 2 s.
        cloud.restore(beta)
        started = Date()
        await waitUntil("bar hidden") { fixture.bar.isHidden }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertNil(fixture.bar.datalessCount)
        XCTAssertEqual(fixture.library.evictionStatus, .none)
        await waitUntil("beta's body indexed") { fixture.library.snapshot.query("beta body").map(\.id) == [self.beta] }

        // Nothing dataless: the poll has stopped, so the status stays put.
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(fixture.bar.isHidden)
        XCTAssertEqual(fixture.library.evictionStatus, .none)
    }

    func testL10_countFollowsANoteEvictedAfterTheScanThroughTheWatcher() async throws {
        cloud.evict(alpha)
        let fixture = makeFixture(watchesFileSystem: true)
        fixture.library.start()
        await waitUntil("bar shown for one note") { fixture.bar.datalessCount == 1 }
        XCTAssertTrue(fixture.library.isWatching)

        // A re-eviction is found by the pass that follows the next watcher batch (L-9).
        cloud.evict(gamma)
        try write("Delta.md", body: "delta body")
        await waitUntil("bar shows two notes") { fixture.bar.datalessCount == 2 }
        XCTAssertEqual(fixture.bar.label.stringValue, "2 notes not downloaded from iCloud. Search is incomplete.")
    }

    func testL10_barHidesWhenTheLibraryIsDetachedOrRestarted() async {
        cloud.evict(alpha)
        let fixture = makeFixture()
        fixture.library.start()
        await waitUntil("bar shown") { !fixture.bar.isHidden }

        // A restart scans again: nothing is known to be dataless until the new pass says so.
        fixture.library.start()
        XCTAssertTrue(fixture.bar.isHidden, "hidden during the rescan")
        XCTAssertEqual(fixture.library.evictionStatus, .none)
        await waitUntil("bar shown again after the rescan") { !fixture.bar.isHidden }
        XCTAssertEqual(fixture.bar.datalessCount, 1)

        fixture.controller.detachLibrary()
        XCTAssertTrue(fixture.bar.isHidden)
        XCTAssertNil(fixture.bar.datalessCount)
    }

    // MARK: - L-10: text

    func testL10_textForOneAndForSeveralNotes() {
        XCTAssertEqual(
            EvictionBar.text(datalessCount: 1, freeBytes: nil),
            "1 note not downloaded from iCloud. Search is incomplete.")
        XCTAssertEqual(
            EvictionBar.text(datalessCount: 2, freeBytes: nil),
            "2 notes not downloaded from iCloud. Search is incomplete.")
        XCTAssertEqual(
            EvictionBar.text(datalessCount: 1500, freeBytes: nil),
            "1500 notes not downloaded from iCloud. Search is incomplete.")
        XCTAssertEqual(
            EvictionBar.text(datalessCount: 3, freeBytes: 985_000_000),
            "3 notes not downloaded from iCloud. Search is incomplete. \u{00B7} 985 MB free")
        XCTAssertEqual(
            EvictionBar.text(datalessCount: 1, freeBytes: 1_500_000_000),
            "1 note not downloaded from iCloud. Search is incomplete. \u{00B7} 1.5 GB free")
        // At and above 2 GB nothing is appended; unknown free space appends nothing either.
        XCTAssertEqual(
            EvictionBar.text(datalessCount: 3, freeBytes: 2_000_000_000),
            "3 notes not downloaded from iCloud. Search is incomplete.")
        XCTAssertEqual(
            EvictionBar.text(datalessCount: 3, freeBytes: 50_000_000_000),
            "3 notes not downloaded from iCloud. Search is incomplete.")
        XCTAssertFalse(EvictionBar.text(datalessCount: 3, freeBytes: nil).contains("free"))
        XCTAssertEqual(EvictionBar.lowFreeSpaceThreshold, 2_000_000_000)
        XCTAssertTrue(EvictionBar.isLowOnSpace(1_999_999_999))
        XCTAssertFalse(EvictionBar.isLowOnSpace(2_000_000_000))
        XCTAssertFalse(EvictionBar.isLowOnSpace(nil))
    }

    // MARK: - L-10: free space and the button

    func testL10_freeSpaceSuffixAndButtonOnlyUnderTwoGigabytes() async throws {
        cloud.evict(alpha, beta, gamma)
        cloud.setFreeBytes(985_000_000)
        let fixture = makeFixture()
        fixture.library.start()
        await waitUntil("bar shown") { !fixture.bar.isHidden }
        XCTAssertEqual(fixture.library.evictionStatus, .init(datalessCount: 3, freeBytes: 985_000_000))
        XCTAssertEqual(
            fixture.bar.label.stringValue,
            "3 notes not downloaded from iCloud. Search is incomplete. \u{00B7} 985 MB free")
        XCTAssertFalse(fixture.bar.storageSettingsButton.isHidden)
        XCTAssertEqual(fixture.bar.storageSettingsButton.title, "Open Storage Settings")

        // The button sits after the text, inside the bar; it opens the Storage pane.
        layout(fixture)
        let button = fixture.bar.storageSettingsButton.frame
        XCTAssertGreaterThan(button.minX, fixture.bar.label.frame.maxX)
        XCTAssertLessThanOrEqual(button.maxX, fixture.bar.bounds.width)
        XCTAssertLessThanOrEqual(button.height, EvictionBar.height)
        var opened: [URL] = []
        fixture.controller.openFile = { url in
            opened.append(url)
            return true
        }
        fixture.bar.storageSettingsButton.performClick(nil)
        XCTAssertEqual(opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.settings.Storage"])

        // Space freed: the next poll drops the suffix and the button; the count stands.
        cloud.setFreeBytes(50_000_000_000)
        await waitUntil("suffix gone") { !fixture.bar.label.stringValue.contains("free") }
        XCTAssertEqual(fixture.bar.label.stringValue, "3 notes not downloaded from iCloud. Search is incomplete.")
        XCTAssertTrue(fixture.bar.storageSettingsButton.isHidden)
        XCTAssertEqual(fixture.bar.datalessCount, 3)

        // Exactly 2 GB is not under 2 GB.
        cloud.setFreeBytes(2_000_000_000)
        await waitUntil("status at 2 GB") { fixture.library.evictionStatus.freeBytes == 2_000_000_000 }
        XCTAssertTrue(fixture.bar.storageSettingsButton.isHidden)
        XCTAssertFalse(fixture.bar.label.stringValue.contains("free"))

        // Nearly full again: back within the poll interval.
        cloud.setFreeBytes(1_999_999_999)
        await waitUntil("button back") { !fixture.bar.storageSettingsButton.isHidden }
        XCTAssertTrue(fixture.bar.label.stringValue.hasSuffix("\u{00B7} 2 GB free"))
    }

    func testL10_openStorageSettingsWithoutALibraryStillOpensTheURL() {
        let controller = makeMainWindowController()
        var opened: [URL] = []
        controller.openFile = { url in
            opened.append(url)
            return true
        }
        XCTAssertTrue(controller.openStorageSettings())
        XCTAssertEqual(opened.map(\.absoluteString), [EvictionBar.storageSettingsURLString])
    }

    func testL10_barIsNotDismissable() {
        let bar = EvictionBar()
        bar.show(datalessCount: 4, freeBytes: 500_000_000)
        // Only the text and the Storage Settings button: nothing closes the bar.
        XCTAssertEqual(bar.subviews.count, 2)
        XCTAssertTrue(bar.subviews.contains(bar.label))
        XCTAssertTrue(bar.subviews.contains(bar.storageSettingsButton))
        XCTAssertFalse(bar.isHidden)
        bar.hide()
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(bar.label.stringValue, "")
        XCTAssertTrue(bar.storageSettingsButton.isHidden)
    }

    // MARK: - V-1: snapshot

    func testV1_rendersTheWindowWithTheBarShowing() async throws {
        cloud.evict(alpha, gamma)
        cloud.setFreeBytes(985_000_000)
        let fixture = makeFixture()
        fixture.controller.window?.setContentSize(NSSize(width: 800, height: 400))
        fixture.library.start()
        await waitUntil("bar shown") { !fixture.bar.isHidden }
        fixture.controller.mainView.searchField.stringValue = ""
        let written = try Self.writeSnapshots(of: fixture.controller, named: "eviction-bar")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    /// Renders the window's content view at 2x in light and dark appearance to
    /// `build/snapshots/<name>-<appearance>.png` (V-1) and returns the files written.
    @MainActor
    private static func writeSnapshots(of controller: MainWindowController, named name: String) throws -> [URL] {
        guard let window = controller.window, let view = window.contentView else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bounds = view.bounds
            let scale = 2
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(bounds.width) * scale,
                    pixelsHigh: Int(bounds.height) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { throw CocoaError(.fileWriteUnknown) }
            rep.size = bounds.size
            view.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = directory.appendingPathComponent("\(name)-\(suffix).png")
            try png.write(to: url)
            written.append(url)
        }
        window.appearance = nil
        return written
    }
}
