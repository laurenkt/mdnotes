import Foundation
import MDNotesCore
import MDNotesTestSupport
import XCTest

final class LibraryScannerTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-scan-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes an empty file at `relativePath` under the root, creating folders as needed.
    private func touch(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func scannedPaths() throws -> [String] {
        try LibraryScanner.scan(root: root).map(\.id.relativePath)
    }

    // MARK: L-2 recursive walk, counts

    func testL2_syntheticLibraryCountsMatch() throws {
        let generated = try SyntheticLibrary.generate(
            at: root, options: .init(noteCount: 300, largeNoteCount: 0))
        let scanned = try scannedPaths()
        XCTAssertEqual(scanned.count, 300)
        XCTAssertEqual(Set(scanned), Set(generated))
        XCTAssertEqual(scanned, scanned.sorted(), "results are sorted by relative path")
    }

    func testL2_emptyRootListsNothing() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(try scannedPaths(), [])
    }

    func testL2_missingRootThrows() {
        XCTAssertThrowsError(try LibraryScanner.scan(root: root))
    }

    func testL2_directoryNamedLikeANoteIsWalkedNotListed() throws {
        try touch("weird.md/inner.md")
        XCTAssertEqual(try scannedPaths(), ["weird.md/inner.md"])
    }

    // MARK: L-3 skip rules

    func testL3_skipsHiddenFilesAndFolders() throws {
        try touch("visible.md")
        try touch(".hidden.md")
        try touch(".hiddenFolder/inside.md")
        try touch("daily/.nestedHidden/inside.md")
        try touch("daily/.dotfile.md")
        try touch("daily/kept.md")
        XCTAssertEqual(try scannedPaths(), ["daily/kept.md", "visible.md"])
    }

    func testL3_skipsTrashObsidianAndTemplates() throws {
        try touch("kept.md")
        try touch("Trash/old.md")
        try touch("Trash/deeper/older.md")
        try touch(".obsidian/workspace.md")
        try touch("templates/daily.md")
        XCTAssertEqual(try scannedPaths(), ["kept.md"])
    }

    func testL3_skipRulesApplyToRootFoldersOnly() throws {
        try touch("projects/Trash/kept.md")
        try touch("projects/templates/kept.md")
        XCTAssertEqual(try scannedPaths(), ["projects/Trash/kept.md", "projects/templates/kept.md"])
    }

    func testL3_skipRulesAreCaseSensitive() throws {
        try touch("trash/kept.md")
        XCTAssertEqual(try scannedPaths(), ["trash/kept.md"])
    }

    // MARK: L-4 identity, nested paths

    func testL4_nestedPathsUseSlashSeparatorsWithExtension() throws {
        try touch("daily/2026/06-sunday.md")
        try touch("a/b/c/d/deep.md")
        try touch("top.md")
        let ids = try LibraryScanner.scan(root: root).map(\.id)
        XCTAssertEqual(
            ids,
            [
                NoteID(relativePath: "a/b/c/d/deep.md"),
                NoteID(relativePath: "daily/2026/06-sunday.md"),
                NoteID(relativePath: "top.md"),
            ])
    }

    func testL4_identityIsRelativeToRootRegardlessOfRootSpelling() throws {
        try touch("daily/note.md")
        let viaSymlinkedTmp = URL(fileURLWithPath: root.path + "/")
        let viaResolved = root.resolvingSymlinksInPath()
        XCTAssertEqual(try LibraryScanner.scan(root: viaSymlinkedTmp).map(\.id.relativePath), ["daily/note.md"])
        XCTAssertEqual(try LibraryScanner.scan(root: viaResolved).map(\.id.relativePath), ["daily/note.md"])
    }

    // MARK: L-5 title

    func testL5_titleIsFilenameWithoutExtension() throws {
        try touch("daily/2026/06-sunday.md")
        try touch("frantisek kupka.md")
        let titles = try LibraryScanner.scan(root: root).map(\.id.title)
        XCTAssertEqual(titles, ["06-sunday", "frantisek kupka"])
    }

    // MARK: L-6 non-md files

    func testL6_nonMdFilesAreNotListed() throws {
        try touch("note.md")
        try touch("readme.txt")
        try touch("data.json")
        try touch("i/20260601-120000.png")
        try touch("note.md.bak")
        try touch("markdown")
        try touch("Makefile")
        XCTAssertEqual(try scannedPaths(), ["note.md"])
    }

    // MARK: modification dates

    func testScanReturnsModificationDates() throws {
        try touch("old.md")
        try touch("new.md")
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: root.appendingPathComponent("old.md").path)
        try FileManager.default.setAttributes(
            [.modificationDate: newDate], ofItemAtPath: root.appendingPathComponent("new.md").path)

        let byID = Dictionary(
            uniqueKeysWithValues: try LibraryScanner.scan(root: root).map { ($0.id.relativePath, $0.modifiedAt) })
        XCTAssertEqual(try XCTUnwrap(byID["old.md"]).timeIntervalSince1970, oldDate.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(byID["new.md"]).timeIntervalSince1970, newDate.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: folder scan and path classification (used by the watcher, X-1)

    func testL3_folderScanListsOnlyThatFolderWithRootRelativeIDs() throws {
        try touch("top.md")
        try touch("daily/2026/a.md")
        try touch("daily/2026/b.txt")
        try touch("daily/other.md")
        try touch("daily/.hidden/c.md")
        XCTAssertEqual(
            try LibraryScanner.scan(root: root, folder: "daily").map(\.id.relativePath),
            ["daily/2026/a.md", "daily/other.md"])
        XCTAssertEqual(
            try LibraryScanner.scan(root: root, folder: "daily/2026").map(\.id.relativePath), ["daily/2026/a.md"])
        XCTAssertEqual(try LibraryScanner.scan(root: root, folder: "").map(\.id.relativePath), try scannedPaths())
    }

    func testL3_folderScanOfSkippedFolderListsNothing() throws {
        try touch("Trash/old.md")
        try touch(".obsidian/x.md")
        try touch("templates/t.md")
        try touch("a/.hidden/h.md")
        for folder in ["Trash", ".obsidian", "templates", "a/.hidden"] {
            XCTAssertEqual(try LibraryScanner.scan(root: root, folder: folder), [], folder)
            XCTAssertFalse(LibraryScanner.isScannedFolder(relativePath: folder), folder)
        }
        XCTAssertTrue(LibraryScanner.isScannedFolder(relativePath: ""))
        XCTAssertTrue(LibraryScanner.isScannedFolder(relativePath: "a/Trash"))
        XCTAssertThrowsError(try LibraryScanner.scan(root: root, folder: "missing"))
    }

    func testL2_noteIDForRelativePathMirrorsTheScan() {
        XCTAssertEqual(LibraryScanner.noteID(forRelativePath: "note.md"), NoteID(relativePath: "note.md"))
        XCTAssertEqual(
            LibraryScanner.noteID(forRelativePath: "daily/2026/06-sunday.md"),
            NoteID(relativePath: "daily/2026/06-sunday.md"))
        XCTAssertEqual(LibraryScanner.noteID(forRelativePath: "a/Trash/x.md"), NoteID(relativePath: "a/Trash/x.md"))
        for rejected in [
            "readme.txt", "note.md.bak", "note.MD", ".hidden.md", ".obsidian/x.md", "a/.h/x.md", "Trash/x.md",
            "templates/x.md", "", ".md", "a//b.md", "/a.md",
        ] {
            XCTAssertNil(LibraryScanner.noteID(forRelativePath: rejected), rejected)
        }
    }
}
