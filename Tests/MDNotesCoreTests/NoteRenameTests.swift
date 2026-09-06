import Foundation
import MDNotesCore
import XCTest

/// `NoteRename` turns an edited title into the renamed note or a rejection (R-2), and
/// `NoteStore.rename` moves the file without ever writing over another.
final class NoteRenameTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-rename-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ id: NoteID, _ body: String, modifiedAt: Date? = nil) throws {
        let url = root.appendingPathComponent(id.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    private func snapshot() -> SearchIndex {
        var builder = SearchIndex.Builder()
        for (i, id) in [alpha, beta, gamma].enumerated() {
            builder.add(id: id, modifiedAt: Date(timeIntervalSinceReferenceDate: Double(i)), body: "")
        }
        return builder.build()
    }

    // MARK: R-2 the new title names a file in the same folder

    func testR2_theNewTitleKeepsTheFolderAndTheExtension() throws {
        XCTAssertEqual(try NoteRename.noteID(renaming: beta, toTitle: "Delta"), NoteID(relativePath: "daily/Delta.md"))
        XCTAssertEqual(try NoteRename.noteID(renaming: alpha, toTitle: "Omega"), NoteID(relativePath: "Omega.md"))
        XCTAssertEqual(
            try NoteRename.noteID(renaming: NoteID(relativePath: "a/b/c.md"), toTitle: "d"),
            NoteID(relativePath: "a/b/d.md"))
        XCTAssertEqual(try NoteRename.noteID(renaming: alpha, toTitle: "  Padded  "), NoteID(relativePath: "Padded.md"))
        XCTAssertEqual(try NoteRename.noteID(renaming: alpha, toTitle: "alpha"), NoteID(relativePath: "alpha.md"))
        XCTAssertEqual(
            try NoteRename.noteID(renaming: alpha, toTitle: "notes.md"), NoteID(relativePath: "notes.md.md"),
            "the title is taken literally; the extension is always added")
    }

    func testR2_illegalTitlesAreRejectedWithAMessage() {
        let cases: [(String, NoteRename.Rejection)] = [
            ("", .empty), ("  \n", .empty),
            ("a:b", .illegalCharacter(":")), ("a/b", .illegalCharacter("/")), ("a\0b", .illegalCharacter("\0")),
            (".", .relativeName(".")), ("..", .relativeName("..")),
            (".hidden", .hidden(".hidden")), (" .hidden", .hidden(".hidden")),
        ]
        for (title, expected) in cases {
            XCTAssertThrowsError(try NoteRename.noteID(renaming: beta, toTitle: title), title) { error in
                XCTAssertEqual(error as? NoteRename.Rejection, expected, title)
            }
            XCTAssertFalse(expected.message.isEmpty)
        }
        XCTAssertTrue(NoteRename.Rejection.illegalCharacter("\0").message.contains("NUL"))
        XCTAssertTrue(NoteRename.Rejection.collision(gamma).message.contains("Gamma"))
    }

    func testR2_aCollisionIsAnotherNoteWithTheSameFileNameIgnoringCase() {
        let index = snapshot()
        XCTAssertEqual(
            NoteRename.collision(renaming: alpha, to: NoteID(relativePath: "gamma.md"), in: index), gamma,
            "the file system would treat gamma.md and Gamma.md as one file")
        XCTAssertEqual(NoteRename.collision(renaming: alpha, to: NoteID(relativePath: "Gamma.md"), in: index), gamma)
        XCTAssertNil(
            NoteRename.collision(renaming: alpha, to: NoteID(relativePath: "alpha.md"), in: index),
            "a note may change the case of its own name")
        XCTAssertNil(
            NoteRename.collision(renaming: alpha, to: NoteID(relativePath: "Beta.md"), in: index),
            "the other Beta is in another folder")
        XCTAssertEqual(
            NoteRename.collision(renaming: gamma, to: NoteID(relativePath: "daily/beta.md"), in: index), beta)
        XCTAssertNil(NoteRename.collision(renaming: alpha, to: NoteID(relativePath: "Omega.md"), in: index))
    }

    // MARK: R-2 the store renames the file without writing over anything

    func testR2_storeRenamesWithinTheFolderKeepingContentsAndDate() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try write(beta, "beta body", modifiedAt: stamp)
        let store = NoteStore(root: root)
        let delta = NoteID(relativePath: "daily/Delta.md")

        XCTAssertEqual(try store.rename(beta, to: delta), stamp, "a rename leaves the modification date alone")
        XCTAssertFalse(exists("daily/Beta.md"))
        XCTAssertEqual(try store.read(delta), .text("beta body"))
        XCTAssertEqual(try store.modificationDate(of: delta), stamp)
        XCTAssertThrowsError(try store.modificationDate(of: beta))
    }

    func testR2_storeNeverRenamesOverAnExistingFile() throws {
        try write(alpha, "alpha body")
        try write(gamma, "gamma body")
        let store = NoteStore(root: root)
        XCTAssertThrowsError(try store.rename(alpha, to: gamma)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try store.read(alpha), .text("alpha body"))
        XCTAssertEqual(try store.read(gamma), .text("gamma body"))

        // The same holds when the names differ only in case on a case-insensitive volume.
        XCTAssertThrowsError(try store.rename(alpha, to: NoteID(relativePath: "gamma.md")))
        XCTAssertEqual(try store.read(alpha), .text("alpha body"))
        XCTAssertEqual(try store.read(gamma), .text("gamma body"))
    }

    func testR2_storeChangesTheCaseOfAName() throws {
        try write(alpha, "alpha body")
        let store = NoteStore(root: root)
        let lower = NoteID(relativePath: "alpha.md")
        XCTAssertNoThrow(try store.rename(alpha, to: lower))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["alpha.md"])
        XCTAssertEqual(try store.read(lower), .text("alpha body"))
        XCTAssertNoThrow(try store.modificationDate(of: lower))
        XCTAssertThrowsError(try store.modificationDate(of: alpha), "the old id is gone (L-4)")
    }

    func testR2_storeRenameToTheSameIdOrOfAMissingNote() throws {
        let store = NoteStore(root: root)
        XCTAssertThrowsError(try store.rename(alpha, to: NoteID(relativePath: "Omega.md")))
        XCTAssertFalse(exists("Omega.md"))
        try write(alpha, "alpha body")
        XCTAssertNoThrow(try store.rename(alpha, to: alpha), "nothing to do")
        XCTAssertEqual(try store.read(alpha), .text("alpha body"))
    }

    // MARK: L-4 a note's identity is its exact path

    func testL4_modificationDateAndExistenceAreExactAboutCase() throws {
        try write(alpha, "alpha body")
        let store = NoteStore(root: root)
        XCTAssertNoThrow(try store.modificationDate(of: alpha))
        XCTAssertThrowsError(try store.modificationDate(of: NoteID(relativePath: "alpha.md"))) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile)
        }
        XCTAssertTrue(NoteStore.fileExistsExactly(at: root.appendingPathComponent("Alpha.md")))
        XCTAssertFalse(NoteStore.fileExistsExactly(at: root.appendingPathComponent("alpha.md")))
        XCTAssertFalse(NoteStore.fileExistsExactly(at: root.appendingPathComponent("Omega.md")))
    }
}
