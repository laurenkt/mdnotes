import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// PF-1 around the real launch path: `AppDelegate.applicationDidFinishLaunching` shows the
/// window and starts the library; the root is walked off the main thread and a titles-only
/// snapshot of every note is published (PF-7); the list reloads with it and lays out its first
/// page of rows. The clock runs from the delegate call to the end of that publish. Against the
/// 20k library. Runs only in `scripts/check.sh full` (release); `MDNOTES_SKIP_PERF=1` skips it
/// (ADR-0007).
///
/// Key window: `showWindow` orders the window front and makes it key, and AppKit hands the
/// search field's editor the first responder (interactive, S-1). But a test process is never
/// the active application (activation is cooperative and nothing hands it over), and an
/// inactive application owns no key window. So the window being key is asserted only when the
/// process is active; what AppKit keys on activation is always asserted: the window is on
/// screen, can become key, and has the search field editing.
@MainActor
final class LaunchPerfTests: XCTestCase {
    /// The 20k-note library, generated on first use and shared by every test in the class.
    nonisolated private static let library: Result<URL, any Error> = Result {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-launchperf-\(UUID().uuidString)", isDirectory: true)
        // Writing 20k files leaves tens of thousands of autoreleased objects behind; drained
        // here, not on the main thread's next turn, which is the first launch's (I-11).
        _ = try autoreleasepool {
            try SyntheticLibrary.generate(at: root, options: .init(noteCount: PerfGate.referenceNoteCount))
        }
        return root
    }

    override class func tearDown() {
        if !PerfGate.isSkipped, let root = try? library.get() {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    private func libraryRoot() throws -> URL {
        try XCTSkipIf(PerfGate.isSkipped, "MDNOTES_SKIP_PERF=1")
        return try Self.library.get()
    }

    /// One measured launch: the state of the window when the clock stopped.
    private struct Launch {
        /// Delegate call to the first page of the full list laid out, in milliseconds.
        let milliseconds: Double
        /// Notes the list showed.
        let listed: Int
        /// Rows on the first page, made and configured.
        let firstPageRows: Int
        /// Rows the table's visible rect holds.
        let visibleRows: Int
        /// The top row's title, to check against the snapshot (S-3).
        let topTitle: String?
        let phase: LibraryController.Phase
        let isVisible: Bool
        let isKey: Bool
        let canBecomeKey: Bool
        let searchFieldIsEditing: Bool
        let appIsActive: Bool
    }

    /// Launches through a real `AppDelegate` against `root` and returns what a user sees when
    /// the list first fills: the clock stops inside the publish that lists every note, once
    /// the table has reloaded and its visible rows are laid out and populated. Then waits for
    /// the bodies to finish indexing, so the next launch starts on an idle machine, and closes
    /// the window.
    private func launch(root: URL) async throws -> Launch {
        let controller = makeMainWindowController()
        let delegate = AppDelegate(mainWindowController: controller, libraryRoot: root)
        let window = try XCTUnwrap(controller.window)
        let table = controller.mainView.tableView
        let searchField = controller.mainView.searchField
        let filled = expectation(description: "list filled")
        let ready = expectation(description: "bodies indexed")
        var result: Launch?

        let start = DispatchTime.now().uptimeNanoseconds
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let library = try XCTUnwrap(delegate.libraryController)
        // The window controller's reload runs first; this runs after it, on the same publish.
        let reload = library.onSnapshotChange
        library.onSnapshotChange = { snapshot in
            reload?(snapshot)
            if result == nil, snapshot.count == PerfGate.referenceNoteCount {
                // The reload marked the table for layout and display; do both now, as the run
                // loop would before the next event, so the rows the user sees exist.
                window.layoutIfNeeded()
                window.displayIfNeeded()
                let visible = table.rows(in: table.visibleRect)
                var rows = 0
                var topTitle: String?
                for row in visible.location..<(visible.location + visible.length) {
                    guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NoteRowView else {
                        continue
                    }
                    rows += 1
                    if row == visible.location { topTitle = view.titleLabel.stringValue }
                }
                let end = DispatchTime.now().uptimeNanoseconds
                let editor = searchField.currentEditor()
                result = Launch(
                    milliseconds: Double(end - start) / 1_000_000,
                    listed: controller.listController.results.count,
                    firstPageRows: rows,
                    visibleRows: visible.length,
                    topTitle: topTitle,
                    phase: library.phase,
                    isVisible: window.isVisible,
                    isKey: window.isKeyWindow,
                    canBecomeKey: window.canBecomeKey,
                    searchFieldIsEditing: editor != nil && window.firstResponder === editor,
                    appIsActive: NSApplication.shared.isActive)
                filled.fulfill()
            }
            if library.phase == .ready { ready.fulfill() }
        }
        await fulfillment(of: [filled, ready], timeout: 60, enforceOrder: true)
        let launch = try XCTUnwrap(result)

        library.onSnapshotChange = nil
        library.stop()
        window.close()
        // The next launch's window takes over the frame autosave name (W-1).
        _ = window.setFrameAutosaveName("")
        return launch
    }

    // MARK: PF-1

    func testPF1_finishLaunchingToListPopulatedAndWindowKeyUnder300msWith20kNotes() async throws {
        let root = try libraryRoot()
        let expected = try LibraryScanner.scan(root: root)
        XCTAssertEqual(expected.count, PerfGate.referenceNoteCount)
        let newest = try XCTUnwrap(expected.max { $0.modifiedAt < $1.modifiedAt })

        // The OS, not the app, is warmed before the clock (PF-1a, ADR-0020): on macOS 27.0 the
        // first text field to become first responder in a process makes AppKit soft-link
        // WritingToolsUI and 415 further images on the main thread, 170 to 250 ms once per
        // process, ungated by `allowsWritingTools`. Reading this loads the same closure, so the
        // cold launch below measures our own launch path. Test only; the app pre-loads nothing.
        _ = NSWritingToolsCoordinator.isWritingToolsAvailable

        // Seven launches: the first is the cold one PF-1 names and is gated on its own; the
        // median over all seven is stable across runs on an idle machine (I-1). There is no
        // warm launch of the app, since a warm launch is not what PF-1 measures.
        let iterations = 7
        var launches: [Launch] = []
        for _ in 0..<iterations {
            let launch = try await launch(root: root)
            launches.append(launch)
            XCTAssertEqual(launch.listed, PerfGate.referenceNoteCount, "the list shows every note")
            XCTAssertEqual(
                launch.phase, .indexing(bodiesRead: 0, of: PerfGate.referenceNoteCount),
                "the list is populated from titles before any body is read (PF-7)")
            XCTAssertGreaterThan(launch.visibleRows, 0, "the list has a first page")
            XCTAssertEqual(launch.firstPageRows, launch.visibleRows, "every row on the first page is made")
            XCTAssertEqual(launch.topTitle, newest.id.title, "row 0 is the most recently modified note (S-3)")
            XCTAssertTrue(launch.isVisible, "the window is on screen")
            XCTAssertTrue(launch.canBecomeKey, "the window can be key")
            XCTAssertTrue(launch.searchFieldIsEditing, "the search field has focus (S-1)")
            if launch.appIsActive {
                XCTAssertTrue(launch.isKey, "the window is key")
            }
        }

        let samples = PerfGate.Samples(launches.map(\.milliseconds))
        let first = launches[0]
        print(
            "PF-1 finish-launching to list populated (\(first.firstPageRows) rows on the first page; "
                + "window key \(first.isKey), app active \(first.appIsActive)): "
                + samples.milliseconds.map { String(format: "%.1f", $0) }.joined(separator: " ")
                + " ms; first (cold) \(String(format: "%.1f", first.milliseconds)) ms")
        PerfGate.report(
            "PF-1", "finish-launching to list populated with \(PerfGate.referenceNoteCount) notes", samples,
            budget: PerfGate.Budget.coldLaunchToInteractive)
        XCTAssertLessThan(
            samples.median, PerfGate.Budget.coldLaunchToInteractive, "PF-1: launch to list populated over budget")
        XCTAssertLessThan(
            first.milliseconds, PerfGate.Budget.coldLaunchToInteractive,
            "PF-1: first launch in the process (the cold one) over budget")
    }
}
