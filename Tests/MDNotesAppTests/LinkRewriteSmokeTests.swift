import AppKit
import Darwin
import Foundation
import MDNotesApp
import MDNotesCore
import Synchronization
import XCTest

/// Headless smoke tests for R-3: committing a rename through the window rewrites the links to
/// the note in the other notes on disk, atomically, logs the count, and touches nothing else.
@MainActor
final class LinkRewriteSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Written oldest first (S-3). Three notes link to Beta each way a link can be written;
    /// Beta links to itself; Alpha and Unrelated mention it only where a link is not a link.
    private static let notes: [(path: String, body: String)] = [
        ("daily/Beta.md", "beta body, and me: [[Beta]]"),
        ("One.md", "see [[Beta]] twice: [[beta|the note]]\n"),
        ("Two.md", "by path [[daily/Beta]] and by title [[BETA]]"),
        ("nested/Three.md", "[[ Beta ]] with spacing\r\nand a tab\t🙂\n"),
        ("Alpha.md", "unrelated: [[Gamma]], `[[Beta]]` in code, ![[Beta]] as an embed"),
        ("Unrelated.md", "```\n[[Beta]]\n```\nnothing links here\n"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let delta = NoteID(relativePath: "daily/Delta.md")
    private let one = NoteID(relativePath: "One.md")
    private let two = NoteID(relativePath: "Two.md")
    private let three = NoteID(relativePath: "nested/Three.md")
    private let alpha = NoteID(relativePath: "Alpha.md")
    private let unrelated = NoteID(relativePath: "Unrelated.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-link-rewrite-\(UUID().uuidString)", isDirectory: true)
        for (i, note) in Self.notes.enumerated() {
            let url = root.appendingPathComponent(note.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(note.body.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.base.addingTimeInterval(Double(i) * 60)], ofItemAtPath: url.path)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let library: LibraryController
        let log: LogSink
        var list: NoteListController { controller.listController }
        var editor: EditorController { controller.editorController }
    }

    /// Collects the lines the library logs, from whichever thread logs them.
    private final class LogSink: Sendable {
        private let storage = Mutex<[String]>([])
        var lines: [String] { storage.withLock { $0 } }
        func append(_ line: String) { storage.withLock { $0.append(line) } }
    }

    /// Main-actor box so a library can ride inside a `@Sendable` teardown block.
    @MainActor
    private final class LibraryBox {
        let library: LibraryController
        init(_ library: LibraryController) { self.library = library }
    }

    /// A laid-out window with a ready library attached, watching the root and logging into
    /// the fixture's sink. The library is stopped at teardown.
    private func makeFixture() async throws -> Fixture {
        let controller = makeMainWindowController(autosaveClock: ManualAutosaveClock())
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let log = LogSink()
        let library = LibraryController(root: root) { log.append($0) }
        let box = LibraryBox(library)
        addTeardownBlock { await MainActor.run { box.library.stop() } }
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [unrelated, alpha, three, two, one, beta])
        XCTAssertTrue(library.isWatching)
        return Fixture(controller: controller, library: library, log: log)
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

    /// Commits `title` for `id` as the list does after Return (R-2) and waits for the rename,
    /// links rewritten, to settle. Returns what `onRenameNote` reported.
    private func rename(
        _ id: NoteID, to title: String, in fixture: Fixture
    ) async throws -> (from: NoteID, to: NoteID, result: Result<Date, any Error>)? {
        let settled = expectation(description: "rename settled")
        var reported: (from: NoteID, to: NoteID, result: Result<Date, any Error>)?
        fixture.controller.onRenameNote = { from, to, result in
            reported = (from, to, result)
            settled.fulfill()
        }
        XCTAssertTrue(fixture.controller.commitTitle(of: id, to: title))
        await fulfillment(of: [settled], timeout: 10)
        fixture.controller.onRenameNote = nil
        return reported
    }

    /// Long enough for the watcher (0.1 s latency) to have delivered anything it was going to.
    private let watcherSettle: Duration = .seconds(1)

    // MARK: - Disk

    /// What identifies a file's bytes on disk: its contents, modification date and inode. An
    /// atomic write (E-5) replaces the inode; an in-place write keeps it.
    private struct FileState: Equatable {
        let bytes: Data
        let modifiedAt: Date
        let inode: UInt64
    }

    private func state(of id: NoteID) throws -> FileState {
        let path = root.appendingPathComponent(id.relativePath).path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return FileState(
            bytes: try Data(contentsOf: URL(fileURLWithPath: path)),
            modifiedAt: try XCTUnwrap(attributes[.modificationDate] as? Date),
            inode: try XCTUnwrap(attributes[.systemFileNumber] as? UInt64))
    }

    /// Every file under the root, as relative paths, hidden files included.
    private func filesOnDisk() throws -> [String] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []))
        var paths: [String] = []
        for case let url as URL in enumerator
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            paths.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
        }
        return paths.sorted()
    }

    private func text(_ id: NoteID) throws -> String {
        try String(contentsOf: root.appendingPathComponent(id.relativePath), encoding: .utf8)
    }

    // MARK: - R-3

    func testR3_renameRewritesTheLinkingNotesAtomicallyLogsTheCountAndLeavesTheRestUntouched() async throws {
        let fixture = try await makeFixture()
        let before = try [one, two, three, alpha, unrelated, beta].map { try state(of: $0) }
        var external: [LibraryChanges] = []
        let forward = fixture.library.onExternalChanges
        fixture.library.onExternalChanges = { changes in
            external.append(changes)
            forward?(changes)
        }

        let reported = try await rename(beta, to: "Delta", in: fixture)
        XCTAssertEqual(reported?.from, beta)
        XCTAssertEqual(reported?.to, delta)
        XCTAssertEqual(try reported?.result.get(), before[5].modifiedAt, "the rename itself keeps the date")

        // The three linking notes were rewritten: a title link to the new title, a path link to
        // the new path, labels, case-insensitive matches and spacing handled, the rest kept.
        XCTAssertEqual(try text(one), "see [[Delta]] twice: [[Delta|the note]]\n")
        XCTAssertEqual(try text(two), "by path [[daily/Delta]] and by title [[Delta]]")
        XCTAssertEqual(try text(three), "[[ Delta ]] with spacing\r\nand a tab\t🙂\n")

        // Each atomically (E-5): a new inode renamed over the old, a fresh date, no temp left.
        for (id, was) in zip([one, two, three], before) {
            let now = try state(of: id)
            XCTAssertNotEqual(now.inode, was.inode, "\(id) was replaced by a rename, not written in place")
            XCTAssertGreaterThan(now.modifiedAt, was.modifiedAt, "\(id)'s date reflects the write")
        }
        XCTAssertEqual(
            try filesOnDisk(),
            ["Alpha.md", "One.md", "Two.md", "Unrelated.md", "daily/Delta.md", "nested/Three.md"],
            "no temp files, nothing created")

        // The unrelated notes were not opened for writing: bytes, date and inode all as before.
        XCTAssertEqual(try state(of: alpha), before[3])
        XCTAssertEqual(try state(of: unrelated), before[4])
        // R-3 rewrites other notes: the renamed note's own text, self-link included, is as it was.
        XCTAssertEqual(try state(of: delta).bytes, before[5].bytes)
        XCTAssertEqual(try state(of: delta).inode, before[5].inode)

        // One line on the log, with the count.
        XCTAssertEqual(fixture.log.lines, ["renamed daily/Beta.md to daily/Delta.md: rewrote links in 3 notes"])

        // The snapshot that settled the rename already carries the new bodies and links.
        let snapshot = fixture.library.snapshot
        XCTAssertNil(snapshot.entry(for: beta))
        // Index bodies are case-folded (S-2); the files above hold the real text.
        XCTAssertEqual(snapshot.entry(for: one)?.body, "see [[delta]] twice: [[delta|the note]]\n")
        XCTAssertEqual(snapshot.entry(for: two)?.body, "by path [[daily/delta]] and by title [[delta]]")
        XCTAssertEqual(snapshot.entry(for: three)?.body, "[[ delta ]] with spacing\r\nand a tab\t🙂\n")
        XCTAssertEqual(snapshot.entry(for: alpha)?.body, CaseFolding.fold(Self.notes[4].body))
        XCTAssertEqual(Set(snapshot.links.backlinks(to: delta)), [one, two, three])
        XCTAssertEqual(snapshot.links.resolve("Beta"), .unresolved, "the renamed note's own self-link now dangles")
        XCTAssertEqual(snapshot.links.outgoing(of: two).map(\.text), ["daily/Delta", "Delta"])
        XCTAssertEqual(
            fixture.list.results.prefix(3).map(\.id).sorted(by: { $0.relativePath < $1.relativePath }),
            [one, two, three], "the rewritten notes were modified, so they lead the list (S-3)")
        XCTAssertEqual(fixture.list.results.suffix(3).map(\.id), [unrelated, alpha, delta])

        // The watcher's reports of the rename and the rewrites were recognised as ours (E-6).
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(external, [])
        XCTAssertEqual(try text(one), "see [[Delta]] twice: [[Delta|the note]]\n", "and nothing rewrote them again")
    }

    func testR3_renameOfANoteNothingLinksToWritesAndLogsNothing() async throws {
        let fixture = try await makeFixture()
        let before = try [one, two, three, alpha, unrelated, beta].map { try state(of: $0) }
        let omega = NoteID(relativePath: "Omega.md")

        let reported = try await rename(alpha, to: "Omega", in: fixture)
        XCTAssertEqual(reported?.to, omega)
        XCTAssertEqual(fixture.log.lines, [])
        XCTAssertEqual(
            try filesOnDisk(), ["Omega.md", "One.md", "Two.md", "Unrelated.md", "daily/Beta.md", "nested/Three.md"])
        for (id, was) in zip([one, two, three, alpha, unrelated, beta], before) where id != alpha {
            XCTAssertEqual(try state(of: id), was, "\(id) was not touched")
        }
        XCTAssertEqual(try state(of: omega).inode, before[3].inode, "the renamed file itself only moved")
        XCTAssertEqual(
            try text(omega), "unrelated: [[Gamma]], `[[Beta]]` in code, ![[Beta]] as an embed",
            "a code span and an embed are not links, so nothing was rewritten to them either")
        try await Task.sleep(for: watcherSettle)
        XCTAssertEqual(fixture.log.lines, [])
    }

    func testR3_theDefaultLogWritesOneLineToStandardError() throws {
        let capture = root.appendingPathComponent("stderr.txt")
        try Data().write(to: capture)
        let saved = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(saved, 0)
        let fd = open(capture.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(dup2(fd, STDERR_FILENO), STDERR_FILENO)
        LibraryController.standardErrorLog("renamed a to b: rewrote links in 3 notes")
        XCTAssertEqual(dup2(saved, STDERR_FILENO), STDERR_FILENO)
        close(fd)
        close(saved)
        XCTAssertEqual(
            try String(contentsOf: capture, encoding: .utf8), "MDNotes: renamed a to b: rewrote links in 3 notes\n")
    }
}
