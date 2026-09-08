import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// K-6 under PF-6 on the main thread: `BacklinksStrip.show` with 2,000 backlinks, expanded
/// (a button for the first `maxTitleButtons` only) and collapsed (no buttons at all). The
/// smoke tests check the bound; this gate times the bounded work with warm-up and a median so
/// a busy machine does not fail the debug suite (I-3). Runs only in `scripts/check.sh full`
/// (release); `MDNOTES_SKIP_PERF=1` skips it (ADR-0007).
@MainActor
final class BacklinksPerfTests: XCTestCase {
    private static let backlinkCount = 2_000
    private static let warmUp = 3
    private static let iterations = 15

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipIf(PerfGate.isSkipped, "MDNOTES_SKIP_PERF=1")
        UserDefaults.standard.removeObject(forKey: BacklinksStrip.collapsedDefaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: BacklinksStrip.collapsedDefaultsKey)
        try await super.tearDown()
    }

    /// The strip in a laid-out window as wide as the main window, as `BacklinksSmokeTests`
    /// makes it.
    private func makeWindowedStrip() throws -> (window: NSWindow, strip: BacklinksStrip) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let strip = BacklinksStrip()
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.topAnchor.constraint(equalTo: content.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: MainView.backlinksStripHeight),
        ])
        content.layoutSubtreeIfNeeded()
        return (window, strip)
    }

    /// One distinct list per call, so every `show` replaces the previous list rather than
    /// returning early on an equal one.
    private func makeLists(count: Int) -> [[NoteID]] {
        (0..<count).map { run in
            (0..<Self.backlinkCount).map { NoteID(relativePath: "hub/run\(run)/Note \($0).md") }
        }
    }

    private func measureShow(_ strip: BacklinksStrip, subject: String) throws -> PerfGate.Samples {
        let lists = makeLists(count: Self.warmUp + Self.iterations)
        var runs = lists.makeIterator()
        let samples = PerfGate.measure(warmUp: Self.warmUp, iterations: Self.iterations) {
            guard let notes = runs.next() else { return XCTFail("ran out of lists") }
            strip.show(notes)
        }
        XCTAssertNil(runs.next(), "every list was shown once")
        XCTAssertEqual(strip.backlinks, lists.last, "the last list is the one shown")
        PerfGate.report("PF-6", subject, samples, budget: PerfGate.Budget.backlinksShow2k)
        XCTAssertLessThan(samples.median, PerfGate.Budget.backlinksShow2k, "PF-6: \(subject) over budget")
        return samples
    }

    // MARK: PF-6

    func testPF6_showWithThousandsOfBacklinksExpandedUnderBudget() throws {
        let (window, strip) = try makeWindowedStrip()
        defer { window.close() }
        XCTAssertFalse(strip.isCollapsed)
        _ = try measureShow(strip, subject: "show \(Self.backlinkCount) backlinks expanded")
        XCTAssertEqual(strip.titleButtons.count, BacklinksStrip.maxTitleButtons)
    }

    func testPF6_showWithThousandsOfBacklinksCollapsedUnderBudget() throws {
        let (window, strip) = try makeWindowedStrip()
        defer { window.close() }
        strip.setCollapsed(true)
        _ = try measureShow(strip, subject: "show \(Self.backlinkCount) backlinks collapsed")
        XCTAssertEqual(strip.titleButtons, [])
    }
}
