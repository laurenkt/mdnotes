import Foundation
import MDNotesCore
import XCTest

/// The pure half of create-on-Enter: which file a query names (C-2) and which queries are
/// rejected (C-3), plus `NoteStore.create` writing the file and its folders.
final class NoteCreationTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func id(forQuery query: String) throws -> NoteID {
        try NoteCreation.noteID(forQuery: query)
    }

    private func rejection(forQuery query: String) -> NoteCreation.Rejection? {
        do {
            _ = try NoteCreation.noteID(forQuery: query)
            return nil
        } catch {
            return error
        }
    }

    // MARK: C-2 the query names <query>.md at the root; `/` makes folders; trimmed

    func testC2_queryNamesAFileAtTheRootWithTheMDExtension() throws {
        XCTAssertEqual(try id(forQuery: "Shopping list"), NoteID(relativePath: "Shopping list.md"))
        XCTAssertEqual(try id(forQuery: "Shopping list").title, "Shopping list")
        // Punctuation, unicode and an extension-looking suffix are all just characters.
        XCTAssertEqual(try id(forQuery: "notes.md"), NoteID(relativePath: "notes.md.md"))
        XCTAssertEqual(try id(forQuery: "#tag & 100%"), NoteID(relativePath: "#tag & 100%.md"))
        XCTAssertEqual(try id(forQuery: "Straße café"), NoteID(relativePath: "Straße café.md"))
    }

    func testC2_slashSegmentsAreFoldersUnderTheRoot() throws {
        XCTAssertEqual(try id(forQuery: "daily/2026/06-sunday"), NoteID(relativePath: "daily/2026/06-sunday.md"))
        XCTAssertEqual(try id(forQuery: "daily/2026/06-sunday").title, "06-sunday")
        XCTAssertEqual(try id(forQuery: "projects/a b/c d"), NoteID(relativePath: "projects/a b/c d.md"))
    }

    func testC2_theQueryIsTrimmed() throws {
        XCTAssertEqual(try id(forQuery: "  Padded  "), NoteID(relativePath: "Padded.md"))
        XCTAssertEqual(try id(forQuery: "\tTabs and newline\n"), NoteID(relativePath: "Tabs and newline.md"))
        XCTAssertEqual(try id(forQuery: " daily/x "), NoteID(relativePath: "daily/x.md"))
        // Only the ends are trimmed: inner whitespace is part of the name.
        XCTAssertEqual(try id(forQuery: "two  spaces"), NoteID(relativePath: "two  spaces.md"))
        XCTAssertEqual(rejection(forQuery: ""), .empty)
        XCTAssertEqual(rejection(forQuery: "   \n"), .empty)
    }

    func testC2_queryFormIsThePathWithoutTheExtension() {
        XCTAssertEqual(NoteCreation.queryForm(of: NoteID(relativePath: "Alpha.md")), "Alpha")
        XCTAssertEqual(NoteCreation.queryForm(of: NoteID(relativePath: "daily/2026/x.md")), "daily/2026/x")
        for query in ["Alpha", "daily/2026/x", "a b/c d"] {
            XCTAssertEqual(NoteCreation.queryForm(of: try id(forQuery: query)), query, "round trip of \(query)")
        }
    }

    // MARK: C-3 illegal characters and segments are rejected

    func testC3_colonAndNULAreRejected() {
        XCTAssertEqual(rejection(forQuery: "time: 10"), .illegalCharacter(":"))
        XCTAssertEqual(rejection(forQuery: "daily/a:b"), .illegalCharacter(":"))
        XCTAssertEqual(rejection(forQuery: "nul\0here"), .illegalCharacter("\0"))
        XCTAssertEqual(rejection(forQuery: ":"), .illegalCharacter(":"))
    }

    func testC3_emptySegmentsAreRejected() {
        XCTAssertEqual(rejection(forQuery: "/"), .emptySegment)
        XCTAssertEqual(rejection(forQuery: "/leading"), .emptySegment)
        XCTAssertEqual(rejection(forQuery: "trailing/"), .emptySegment)
        XCTAssertEqual(rejection(forQuery: "a//b"), .emptySegment)
    }

    func testC3_dotSegmentsAreRejected() {
        // `.` and `..` would escape the folder; anything else starting with `.` is hidden and
        // would never be listed (L-3).
        XCTAssertEqual(rejection(forQuery: "."), .relativeSegment("."))
        XCTAssertEqual(rejection(forQuery: "../outside"), .relativeSegment(".."))
        XCTAssertEqual(rejection(forQuery: "a/./b"), .relativeSegment("."))
        XCTAssertEqual(rejection(forQuery: ".hidden"), .hiddenSegment(".hidden"))
        XCTAssertEqual(rejection(forQuery: ".obsidian/x"), .hiddenSegment(".obsidian"))
        XCTAssertEqual(rejection(forQuery: "a/.b"), .hiddenSegment(".b"))
    }

    func testC3_skippedRootFoldersAreRejected() {
        // The scanner never lists these folders (L-3), so a note in one could not be shown.
        XCTAssertEqual(rejection(forQuery: "Trash/gone"), .skippedFolder("Trash"))
        XCTAssertEqual(rejection(forQuery: "templates/daily"), .skippedFolder("templates"))
        // As a title at the root, or deeper down, the names are ordinary.
        XCTAssertEqual(try id(forQuery: "Trash"), NoteID(relativePath: "Trash.md"))
        XCTAssertEqual(try id(forQuery: "notes/templates/x"), NoteID(relativePath: "notes/templates/x.md"))
    }

    func testC3_everyRejectionHasAMessage() {
        let rejections: [NoteCreation.Rejection] = [
            .empty, .illegalCharacter(":"), .illegalCharacter("\0"), .emptySegment, .relativeSegment(".."),
            .hiddenSegment(".x"), .skippedFolder("Trash"),
        ]
        for rejection in rejections {
            XCTAssertFalse(rejection.message.isEmpty, "\(rejection)")
            XCTAssertFalse(rejection.message.contains("\0"), "the message must be showable")
        }
        XCTAssertTrue(NoteCreation.Rejection.illegalCharacter(":").message.contains(":"))
        XCTAssertTrue(NoteCreation.Rejection.illegalCharacter("\0").message.contains("NUL"))
        XCTAssertTrue(NoteCreation.Rejection.skippedFolder("Trash").message.contains("Trash"))
    }

    // MARK: C-2 the store writes the file and its folders

    func testC2_createWritesAnEmptyFileAtTheRoot() throws {
        let store = NoteStore(root: root)
        let id = try self.id(forQuery: "New note")
        let before = Date().addingTimeInterval(-2)
        let creation = try store.create(id)
        XCTAssertTrue(creation.created)
        XCTAssertGreaterThanOrEqual(creation.modifiedAt, before)
        XCTAssertEqual(try store.read(id), .text(""))
        XCTAssertEqual(try store.modificationDate(of: id), creation.modifiedAt)
        XCTAssertEqual(try LibraryScanner.scan(root: root).map(\.id), [id], "the scanner lists it")
    }

    func testC2_createMakesMissingFolders() throws {
        let store = NoteStore(root: root)
        let id = try self.id(forQuery: "daily/2026/06-sunday")
        let creation = try store.create(id)
        XCTAssertTrue(creation.created)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("daily/2026").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try store.read(id), .text(""))
        XCTAssertEqual(try LibraryScanner.scan(root: root).map(\.id), [id])

        // A sibling in an existing folder reuses it.
        let sibling = try self.id(forQuery: "daily/2026/07-monday")
        XCTAssertTrue(try store.create(sibling).created)
        XCTAssertEqual(try LibraryScanner.scan(root: root).map(\.id), [id, sibling])
    }

    func testC2_createNeverOverwritesAnExistingFile() throws {
        let store = NoteStore(root: root)
        let id = try self.id(forQuery: "Keep me")
        let url = store.url(for: id)
        try "precious".write(to: url, atomically: true, encoding: .utf8)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        let creation = try store.create(id)
        XCTAssertFalse(creation.created)
        XCTAssertEqual(creation.modifiedAt, stamp)
        XCTAssertEqual(try store.read(id), .text("precious"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["Keep me.md"],
            "no temp file is left behind")
    }
}
