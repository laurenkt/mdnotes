import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the backlinks strip (K-6): the bar below the editor lists the
/// titles of the notes linking to the open note, a click on one opens it, the bar hides when
/// there are none, and its collapse state is remembered in `UserDefaults`. Clicks go through
/// `NSButton.performClick`, the path a mouse-up on a button takes.
@MainActor
final class BacklinksSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Written oldest first, so the empty query lists them newest first (S-3): Delta, Gamma,
    /// Beta, Alpha. Alpha's own `[[Delta]]` is in a code span and its `![[Alpha.png]]` is an
    /// embed, so neither is a link (K-1, T-1 rules through the scanner). Gamma links to Alpha
    /// twice, under two spellings, and once to Beta.
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "alpha body `[[Delta]]` and ![[Alpha.png]]\n"),
        ("daily/Beta.md", "beta links [[Alpha]] journal\n"),
        ("Gamma.md", "gamma links [[Alpha|the first]] and [[alpha]] and [[Beta]]\n"),
        ("Delta.md", "delta has no links\n"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")
    private let delta = NoteID(relativePath: "Delta.md")

    override func setUp() async throws {
        try await super.setUp()
        resetPersistedState()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-backlinks-\(UUID().uuidString)", isDirectory: true)
        for (i, note) in Self.notes.enumerated() {
            let url = root.appendingPathComponent(note.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try note.body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.base.addingTimeInterval(Double(i) * 60)], ofItemAtPath: url.path)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        resetPersistedState()
        try await super.tearDown()
    }

    private func resetPersistedState() {
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        UserDefaults.standard.removeObject(forKey: BacklinksStrip.collapsedDefaultsKey)
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let library: LibraryController
        let clock: ManualAutosaveClock
        var editor: EditorController { controller.editorController }
        var view: MainView { controller.mainView }
        var strip: BacklinksStrip { controller.mainView.backlinksStrip }
        var titles: [String] { strip.titleButtons.map(\.title) }
    }

    /// A laid-out window with a ready library attached, on a manual autosave clock, nothing
    /// selected and the editor empty.
    private func makeFixture() async throws -> Fixture {
        let clock = ManualAutosaveClock()
        let controller = makeMainWindowController(autosaveClock: clock)
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [delta, gamma, beta, alpha])
        return Fixture(controller: controller, library: library, clock: clock)
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

    /// Selects `id` in the list (S-8) and waits for the editor to show its body.
    private func select(_ id: NoteID, in fixture: Fixture) async {
        XCTAssertTrue(fixture.controller.listController.select(id), "\(id) is listed")
        await waitForEditor(fixture, toShow: id)
    }

    /// Waits for the editor's read of `id` to land, the async tail of S-8.
    private func waitForEditor(_ fixture: Fixture, toShow id: NoteID) async {
        await waitUntil("editor shows \(id.relativePath)") {
            fixture.editor.noteID == id && fixture.editor.body != nil
        }
    }

    /// Types `text` at the end of the editor's text, the way a keystroke does.
    private func type(_ text: String, in fixture: Fixture) {
        let end = NSRange(location: (fixture.view.textView.string as NSString).length, length: 0)
        fixture.view.textView.insertText(text, replacementRange: end)
    }

    private func button(titled title: String, in fixture: Fixture) throws -> NSButton {
        try XCTUnwrap(fixture.strip.titleButtons.first { $0.title == title }, "a button titled \(title)")
    }

    // MARK: K-6 the strip lists the notes linking to the open note

    func testK6_stripListsTheTitlesOfNotesLinkingToTheOpenNoteNewestFirst() async throws {
        let fixture = try await makeFixture()
        await select(alpha, in: fixture)

        let strip = fixture.strip
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(strip.backlinks, [gamma, beta], "most recently modified first (K-5)")
        XCTAssertEqual(fixture.titles, ["Gamma", "Beta"], "titles are file names (L-5)")
        XCTAssertEqual(
            strip.titleButtons.map(\.toolTip), ["Gamma.md", "daily/Beta.md"], "paths tell equal titles apart")
        XCTAssertFalse(strip.isCollapsed)
        XCTAssertFalse(strip.titlesStack.isHidden)
        XCTAssertEqual(strip.summaryLabel.stringValue, "Backlinks")

        // W-2: below the editor, across the window, with the split view resting on it.
        fixture.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(strip.frame.height, MainView.backlinksStripHeight, accuracy: 0.5)
        XCTAssertEqual(strip.frame.width, 800, accuracy: 0.5)
        XCTAssertEqual(fixture.view.splitView.frame.minY, strip.frame.maxY, accuracy: 0.5)
        // Every title fits at this width and none is detached.
        XCTAssertTrue(strip.titlesStack.detachedViews.isEmpty)
        for button in strip.titleButtons {
            XCTAssertTrue(button.frame.maxX <= strip.frame.width, "\(button.title) is within the bar")
        }
    }

    func testK6_titlesThatDoNotFitTheBarDropFromTheEnd() throws {
        // The strip on its own, in a narrow window: the view needs no library to lay out.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let strip = BacklinksStrip()
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.topAnchor.constraint(equalTo: content.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: MainView.backlinksStripHeight),
        ])
        let notes = (1...12).map { NoteID(relativePath: "A rather long backlink title \($0).md") }
        strip.show(notes)
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(strip.frame.width, 260, accuracy: 0.5)
        XCTAssertEqual(strip.titleButtons.count, 12, "every title is kept")
        let shown = strip.titleButtons.filter { !strip.titlesStack.detachedViews.contains($0) }
        XCTAssertFalse(shown.isEmpty, "at least the first title shows")
        XCTAssertLessThan(shown.count, 12, "not every title fits 260 points")
        XCTAssertEqual(shown.map(\.title), notes.prefix(shown.count).map(\.title), "the first titles stay")
        for button in shown {
            XCTAssertLessThanOrEqual(button.frame.maxX, strip.titlesStack.frame.width + 0.5, "\(button.title) fits")
        }
        // Wider, and every title comes back.
        window.setContentSize(NSSize(width: 3000, height: 100))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(strip.titlesStack.detachedViews.isEmpty)
    }

    func testK6_stripIsHiddenWhileNoNoteIsOpenOrTheOpenNoteHasNoBacklinks() async throws {
        let fixture = try await makeFixture()
        let strip = fixture.strip
        XCTAssertTrue(strip.isHidden, "nothing open")
        XCTAssertEqual(strip.backlinks, [])

        // A code-span `[[Delta]]` is not a link to Delta.
        await select(delta, in: fixture)
        XCTAssertTrue(strip.isHidden)
        XCTAssertEqual(strip.backlinks, [])
        fixture.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.view.splitView.frame.minY, 0, accuracy: 0.5, "the editor takes the strip's room")

        await select(alpha, in: fixture)
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(fixture.titles, ["Gamma", "Beta"])

        // Beta is linked from Gamma alone; Gamma from nothing.
        await select(beta, in: fixture)
        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(fixture.titles, ["Gamma"])
        await select(gamma, in: fixture)
        XCTAssertTrue(strip.isHidden)
        XCTAssertEqual(strip.titleButtons, [])

        // Letting go of the library empties the editor and the strip with it.
        await select(alpha, in: fixture)
        XCTAssertFalse(strip.isHidden)
        fixture.controller.detachLibrary()
        XCTAssertTrue(strip.isHidden)
        XCTAssertEqual(strip.backlinks, [])
    }

    // MARK: K-6 clicking a title opens that note

    func testK6_clickingATitleOpensThatNote() async throws {
        let fixture = try await makeFixture()
        await select(alpha, in: fixture)
        let window = try XCTUnwrap(fixture.controller.window)

        // Beta is listed: the click selects it, which loads it (S-8), and focuses the editor.
        try button(titled: "Beta", in: fixture).performClick(nil)
        await waitForEditor(fixture, toShow: beta)
        XCTAssertEqual(fixture.controller.listController.selectedID, beta)
        XCTAssertIdentical(window.firstResponder, fixture.view.textView)
        XCTAssertEqual(fixture.view.textView.string, Self.notes[1].body)
        XCTAssertEqual(fixture.titles, ["Gamma"], "the strip now belongs to Beta")

        // A note the query does not list is loaded into the editor alone (as K-3 opens one).
        fixture.controller.search(for: "journal")
        XCTAssertEqual(fixture.controller.listController.results.map(\.id), [beta])
        XCTAssertEqual(fixture.titles, ["Gamma"], "the query does not change the open note")
        try button(titled: "Gamma", in: fixture).performClick(nil)
        await waitForEditor(fixture, toShow: gamma)
        XCTAssertNil(fixture.controller.listController.selectedID)
        XCTAssertEqual(fixture.view.textView.string, Self.notes[2].body)
        XCTAssertTrue(fixture.strip.isHidden, "nothing links to Gamma")
        XCTAssertEqual(fixture.controller.query, "journal", "the query is kept")

        // A stale id opens nothing.
        XCTAssertFalse(fixture.controller.openBacklink(NoteID(relativePath: "Gone.md")))
        XCTAssertEqual(fixture.editor.noteID, gamma)
    }

    // MARK: K-6 collapse state is remembered

    func testK6_collapsingHidesTheTitlesBehindACountAndIsRemembered() async throws {
        let fixture = try await makeFixture()
        await select(alpha, in: fixture)
        let strip = fixture.strip
        XCTAssertFalse(strip.isCollapsed)
        XCTAssertEqual(strip.disclosureButton.state, .on)
        XCTAssertNil(UserDefaults.standard.object(forKey: BacklinksStrip.collapsedDefaultsKey))

        strip.disclosureButton.performClick(nil)
        XCTAssertTrue(strip.isCollapsed)
        XCTAssertEqual(strip.disclosureButton.state, .off)
        XCTAssertTrue(strip.titlesStack.isHidden)
        XCTAssertEqual(strip.summaryLabel.stringValue, "2 backlinks")
        XCTAssertFalse(strip.isHidden, "collapsed is not hidden: the bar stays to be expanded")
        XCTAssertEqual(strip.backlinks, [gamma, beta], "the list is kept behind the count")
        XCTAssertEqual(UserDefaults.standard.bool(forKey: BacklinksStrip.collapsedDefaultsKey), true)

        // The count follows the open note while collapsed; no backlinks still hides the bar.
        await select(beta, in: fixture)
        XCTAssertEqual(strip.summaryLabel.stringValue, "1 backlink")
        await select(gamma, in: fixture)
        XCTAssertTrue(strip.isHidden)
        await select(alpha, in: fixture)
        XCTAssertFalse(strip.isHidden)
        XCTAssertTrue(strip.isCollapsed)

        // A window made later starts out collapsed.
        let later = makeMainWindowController()
        XCTAssertTrue(later.mainView.backlinksStrip.isCollapsed)
        XCTAssertEqual(later.mainView.backlinksStrip.disclosureButton.state, .off)
        XCTAssertTrue(later.mainView.backlinksStrip.titlesStack.isHidden)

        // Expanding is remembered the same way.
        strip.disclosureButton.performClick(nil)
        XCTAssertFalse(strip.isCollapsed)
        XCTAssertFalse(strip.titlesStack.isHidden)
        XCTAssertEqual(strip.summaryLabel.stringValue, "Backlinks")
        XCTAssertEqual(fixture.titles, ["Gamma", "Beta"])
        XCTAssertEqual(UserDefaults.standard.bool(forKey: BacklinksStrip.collapsedDefaultsKey), false)
        strip.toggleCollapsed()
        XCTAssertTrue(strip.isCollapsed)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: BacklinksStrip.collapsedDefaultsKey), true)
        XCTAssertTrue(later.mainView.backlinksStrip.isCollapsed, "another window's strip is not driven by this one")
    }

    // MARK: K-6 with K-5 the strip follows the index

    func testK6_stripFollowsTheSnapshotAsLinksAreSavedChangedAndRenamed() async throws {
        let fixture = try await makeFixture()
        let library = fixture.library

        // A link typed and autosaved (E-4) is a backlink from then on (K-5).
        await select(delta, in: fixture)
        XCTAssertTrue(fixture.strip.isHidden)
        type("see [[Alpha]]", in: fixture)
        let saved = expectation(description: "Delta saved")
        fixture.editor.onSave = { _, _ in saved.fulfill() }
        fixture.clock.advance(by: EditorController.autosaveDelay)
        await fulfillment(of: [saved], timeout: 10)
        fixture.editor.onSave = nil
        await waitUntil("Delta's link indexed") {
            library.snapshot.links.backlinks(to: self.alpha).contains(self.delta)
        }
        await select(alpha, in: fixture)
        XCTAssertEqual(fixture.titles, ["Delta", "Gamma", "Beta"], "the note just written is the newest")

        // A change on disk that drops a link takes it out of the strip once the watcher reports
        // it (X-1); the open note is not touched.
        try "beta no longer links\n".write(
            to: root.appendingPathComponent(beta.relativePath), atomically: true, encoding: .utf8)
        await waitUntil("Beta's link gone") { fixture.strip.backlinks == [self.delta, self.gamma] }
        XCTAssertEqual(fixture.titles, ["Delta", "Gamma"])
        XCTAssertEqual(fixture.editor.noteID, alpha)

        // A linking note renamed (R-2) is listed under its new title.
        XCTAssertTrue(fixture.controller.commitTitle(of: gamma, to: "Gamma Ray"))
        let gammaRay = NoteID(relativePath: "Gamma Ray.md")
        await waitUntil("Gamma renamed in the strip") { fixture.strip.backlinks.contains(gammaRay) }
        XCTAssertEqual(Set(fixture.titles), ["Delta", "Gamma Ray"])
        XCTAssertFalse(fixture.strip.backlinks.contains(gamma))

        // A linking note deleted (D-1) leaves the strip when the snapshot drops it (D-2).
        let deleted = expectation(description: "Delta deleted")
        library.delete(delta) { _ in deleted.fulfill() }
        await fulfillment(of: [deleted], timeout: 10)
        await waitUntil("Delta gone from the strip") { fixture.strip.backlinks == [gammaRay] }
        XCTAssertEqual(fixture.titles, ["Gamma Ray"])
        XCTAssertFalse(fixture.strip.isHidden)
    }
}
