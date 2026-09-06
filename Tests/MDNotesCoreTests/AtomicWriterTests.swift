import Darwin
import Foundation
import MDNotesCore
import Synchronization
import XCTest

final class AtomicWriterTests: XCTestCase {
    private struct Interrupted: Error {}

    private var root: URL = FileManager.default.temporaryDirectory
    private var note: URL { root.appendingPathComponent("note.md", isDirectory: false) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        chmod(root.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    private func contents(of url: URL) throws -> [UInt8] {
        Array(try Data(contentsOf: url))
    }

    private func directoryEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    // MARK: E-5 atomic replace

    func testE5_writesNewFileByteExact() throws {
        // A BOM and CRLF are text (L-8); nothing is normalised on the way out either.
        let text = "\u{FEFF}# Title\r\nfrantišek [[link]] #tag\r\n"
        try AtomicWriter().write(text, to: note)
        XCTAssertEqual(try contents(of: note), Array(text.utf8))
        XCTAssertEqual(try directoryEntries(), ["note.md"])
    }

    func testE5_replacesExistingFileContents() throws {
        try Data("old".utf8).write(to: note)
        try AtomicWriter().write("new and longer", to: note)
        XCTAssertEqual(try contents(of: note), Array("new and longer".utf8))
        try AtomicWriter().write("", to: note)
        XCTAssertEqual(try contents(of: note), [])
        XCTAssertEqual(try directoryEntries(), ["note.md"])
    }

    func testE5_interruptedWriteLeavesOldFileIntact() throws {
        try Data("the old text".utf8).write(to: note)
        let writer = AtomicWriter(beforeCommit: { _ in throw Interrupted() })
        XCTAssertThrowsError(try writer.write("half-written replacement", to: note)) { error in
            XCTAssertTrue(error is Interrupted, "unexpected error \(error)")
        }
        XCTAssertEqual(try contents(of: note), Array("the old text".utf8))
        XCTAssertEqual(try directoryEntries(), ["note.md"], "the temp file must be cleaned up")
    }

    func testE5_tempFileIsAHiddenSiblingHoldingTheNewContent() throws {
        try Data("old".utf8).write(to: note)
        let target = note
        let seen = Mutex<Snapshot?>(nil)
        let writer = AtomicWriter(beforeCommit: { temp in
            let snapshot = Snapshot(
                parent: temp.deletingLastPathComponent().standardizedFileURL.path,
                name: temp.lastPathComponent,
                tempBytes: Array(try Data(contentsOf: temp)),
                targetBytes: Array(try Data(contentsOf: target)))
            seen.withLock { $0 = snapshot }
        })
        try writer.write("new", to: note)
        let snapshot = try XCTUnwrap(seen.withLock { $0 })
        XCTAssertEqual(snapshot.parent, root.standardizedFileURL.path, "temp file must be in the same directory")
        XCTAssertTrue(snapshot.name.hasPrefix("."), "temp file must be hidden from the scanner (L-3)")
        XCTAssertNotEqual(snapshot.name, "note.md")
        XCTAssertEqual(snapshot.tempBytes, Array("new".utf8), "temp file is complete before the commit")
        XCTAssertEqual(snapshot.targetBytes, Array("old".utf8), "destination is untouched before the commit")
        XCTAssertEqual(try contents(of: note), Array("new".utf8))
    }

    func testE5_tempFileIsInvisibleToTheScanner() throws {
        try Data("old".utf8).write(to: note)
        let libraryRoot = root
        let seen = Mutex<[String]>([])
        let writer = AtomicWriter(beforeCommit: { _ in
            let ids = try LibraryScanner.scan(root: libraryRoot).map(\.id.relativePath)
            seen.withLock { $0 = ids }
        })
        try writer.write("new", to: note)
        XCTAssertEqual(seen.withLock { $0 }, ["note.md"])
    }

    func testE5_staleTempFromACrashDoesNotBlockLaterWrites() throws {
        // A crash after writing the temp but before the rename leaves the temp behind. The next
        // write must still succeed and the destination must still be replaced whole.
        try Data("old".utf8).write(to: note)
        try Data("abandoned".utf8).write(to: root.appendingPathComponent(".note.md.stale.tmp"))
        try AtomicWriter().write("new", to: note)
        XCTAssertEqual(try contents(of: note), Array("new".utf8))
        XCTAssertEqual(try directoryEntries(), [".note.md.stale.tmp", "note.md"])
    }

    func testE5_unwritableDirectoryLeavesOldFileIntact() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores directory permissions")
        try Data("old".utf8).write(to: note)
        XCTAssertEqual(chmod(root.path, 0o555), 0)
        defer { chmod(root.path, 0o755) }
        XCTAssertThrowsError(try AtomicWriter().write("new", to: note))
        XCTAssertEqual(try contents(of: note), Array("old".utf8))
        XCTAssertEqual(try directoryEntries(), ["note.md"])
    }

    func testE5_missingDirectoryThrowsWithoutCreatingAnything() throws {
        let orphan = root.appendingPathComponent("no-such-folder/note.md")
        XCTAssertThrowsError(try AtomicWriter().write("x", to: orphan))
        XCTAssertEqual(try directoryEntries(), [])
    }

    // MARK: E-5 modification date

    func testE5_modificationDateReflectsTheWrite() throws {
        try Data("old".utf8).write(to: note)
        let longAgo = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: note.path)
        let start = Date()
        let returned = try AtomicWriter().write("new", to: note)
        let onDisk = try NoteStore(root: root).modificationDate(of: NoteID(relativePath: "note.md"))
        XCTAssertEqual(returned, onDisk, "the returned date is what the scanner will see")
        XCTAssertGreaterThan(onDisk, longAgo)
        // File-system timestamps and the wall clock are the same clock but not the same precision.
        XCTAssertGreaterThanOrEqual(onDisk.timeIntervalSince1970, start.timeIntervalSince1970 - 1)
        XCTAssertLessThanOrEqual(onDisk.timeIntervalSince1970, Date().timeIntervalSince1970 + 1)
    }

    func testE5_keepsExistingPermissions() throws {
        try Data("old".utf8).write(to: note)
        XCTAssertEqual(chmod(note.path, 0o600), 0)
        try AtomicWriter().write("new", to: note)
        var info = stat()
        XCTAssertEqual(stat(note.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    // MARK: helpers

    /// What the interruption hook observed, handed back across the `@Sendable` boundary.
    private struct Snapshot: Sendable {
        let parent: String
        let name: String
        let tempBytes: [UInt8]
        let targetBytes: [UInt8]
    }
}
