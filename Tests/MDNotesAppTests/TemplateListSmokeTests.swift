import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the template list `LibraryController` keeps (TP-1, TP-7): listed
/// once the root is walked, and following `templates/` on disk through the real watcher as a
/// template is added, renamed and removed, without any of it reaching the note snapshot.
@MainActor
final class TemplateListSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    private var library: LibraryController?

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-template-list-\(UUID().uuidString)", isDirectory: true)
        try write("Alpha.md", "alpha body")
        try write("templates/daily.md", "---\npath: daily/{{date:yyyy-MM-dd}}\n---\n")
    }

    override func tearDown() async throws {
        library?.stop()
        library = nil
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    /// Writes `body` at `relativePath` under the root, creating folders as needed.
    private func write(_ relativePath: String, _ body: String) throws {
        try FileManager.default.createDirectory(
            at: url(relativePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url(relativePath))
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Long enough for the watcher (0.1 s latency) to have delivered anything it was going to.
    private let watcherSettle: Duration = .seconds(1)

    /// A started library over the root, ready and watching, with every template listing and
    /// snapshot publish counted.
    private func startLibrary(watching: Bool = true) async -> (LibraryController, Counts) {
        let library = LibraryController(root: root, watchesFileSystem: watching)
        self.library = library
        let counts = Counts()
        library.onTemplateNamesChange = { names in
            counts.listings.append(names)
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(names, library.templateNames, "templateNames is replaced before the callback")
        }
        library.onSnapshotChange = { _ in counts.publishes += 1 }
        // Let the fixture writes settle first, so FSEvents does not replay them as the
        // stream's first event and list the templates a second time.
        try? await Task.sleep(for: .milliseconds(200))
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        await waitUntil("templates listed") { !library.templateNames.isEmpty }
        XCTAssertEqual(library.isWatching, watching)
        return (library, counts)
    }

    @MainActor
    private final class Counts {
        var listings: [[String]] = []
        var publishes = 0
    }

    // MARK: TP-1: listed by name once the root is walked, never as notes

    func testTP1_templatesAreListedByNameAfterStartAndAreNotNotes() async throws {
        let (library, counts) = await startLibrary()
        XCTAssertEqual(library.templateNames, ["daily"])
        XCTAssertEqual(counts.listings.first, ["daily"])
        XCTAssertEqual(library.snapshot.entries.map(\.id.relativePath), ["Alpha.md"])
        XCTAssertEqual(library.templates.root, root)
        XCTAssertEqual(try library.templates.names(), ["daily"])

        library.stop()
        XCTAssertEqual(library.templateNames, [], "stop() forgets the templates")
        XCTAssertEqual(counts.listings.last, [])
    }

    // MARK: TP-7: the list follows the disk through the watcher

    func testTP7_addedTemplateAppearsInTheList() async throws {
        let (library, counts) = await startLibrary()
        let publishes = counts.publishes
        try write("templates/meeting.md", "---\npath: meetings/{{title}}\n---\n")
        await waitUntil("meeting listed") { library.templateNames == ["daily", "meeting"] }
        try? await Task.sleep(for: watcherSettle)
        XCTAssertEqual(library.templateNames, ["daily", "meeting"])
        XCTAssertEqual(library.snapshot.entries.map(\.id.relativePath), ["Alpha.md"], "a template is not a note")
        XCTAssertEqual(counts.publishes, publishes, "a template-only batch does not publish a snapshot")
    }

    func testTP7_renamedTemplateChangesNameInTheList() async throws {
        let (library, _) = await startLibrary()
        try FileManager.default.moveItem(at: url("templates/daily.md"), to: url("templates/journal.md"))
        await waitUntil("journal listed") { library.templateNames == ["journal"] }
        try? await Task.sleep(for: watcherSettle)
        XCTAssertEqual(library.templateNames, ["journal"])
        XCTAssertEqual(library.snapshot.entries.map(\.id.relativePath), ["Alpha.md"])
    }

    func testTP7_removedTemplateLeavesTheList() async throws {
        let (library, counts) = await startLibrary()
        try write("templates/meeting.md", "---\npath: meetings/{{title}}\n---\n")
        await waitUntil("meeting listed") { library.templateNames == ["daily", "meeting"] }
        try FileManager.default.removeItem(at: url("templates/daily.md"))
        await waitUntil("daily gone") { library.templateNames == ["meeting"] }
        try? await Task.sleep(for: watcherSettle)
        XCTAssertEqual(library.templateNames, ["meeting"])
        XCTAssertEqual(counts.listings.last, ["meeting"])
    }

    func testTP7_changedTemplateIsListedAgainWithTheSameNames() async throws {
        let (library, counts) = await startLibrary()
        var external: [LibraryChanges] = []
        library.onExternalChanges = { external.append($0) }
        let listings = counts.listings.count
        try write("templates/daily.md", "---\npath: journal/{{date:yyyy}}/{{date:MM-dd}}\n---\n")
        await waitUntil("relisted") { counts.listings.count > listings }
        XCTAssertEqual(library.templateNames, ["daily"])
        XCTAssertTrue(external.contains { $0.templates == ["daily"] }, "\(external)")
    }

    func testTP7_applyWithTemplatesRelistsWithoutTouchingTheSnapshot() async throws {
        let (library, counts) = await startLibrary(watching: false)
        let publishes = counts.publishes
        try write("templates/meeting.md", "---\npath: meetings/{{title}}\n---\n")
        library.apply(LibraryChanges(templates: ["meeting"]))
        await waitUntil("meeting listed") { library.templateNames == ["daily", "meeting"] }
        XCTAssertEqual(counts.publishes, publishes, "nothing to fold into the snapshot")
        XCTAssertEqual(library.snapshot.entries.map(\.id.relativePath), ["Alpha.md"])
    }
}
