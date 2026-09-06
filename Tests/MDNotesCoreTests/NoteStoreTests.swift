import Foundation
import MDNotesCore
import XCTest

final class NoteStoreTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ bytes: [UInt8], to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    // MARK: L-8 UTF-8

    func testL8_readsUTF8Body() throws {
        let text = "# Heading\n\nfrantišek kupka [[link]] #tag\n"
        try write(Array(text.utf8), to: "daily/note.md")
        let body = try NoteStore(root: root).read(NoteID(relativePath: "daily/note.md"))
        XCTAssertEqual(body, .text(text))
        XCTAssertEqual(body.displayText, text)
        XCTAssertTrue(body.isWritable)
    }

    func testL8_emptyFileIsEmptyText() throws {
        try write([], to: "empty.md")
        XCTAssertEqual(try NoteStore(root: root).read(NoteID(relativePath: "empty.md")), .text(""))
    }

    func testL8_utf8IsPreservedByteForByte() throws {
        // A BOM and CRLF line endings are text, not metadata; nothing is normalised.
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("a\r\nb".utf8)
        try write(bytes, to: "bom.md")
        let body = try NoteStore(root: root).read(NoteID(relativePath: "bom.md"))
        guard case .text(let text) = body else { return XCTFail("expected .text, got \(body)") }
        XCTAssertEqual(Array(text.utf8), bytes)
    }

    func testL8_invalidUTF8IsFlaggedAndReadOnly() throws {
        // 0xFF and 0xFE never appear in UTF-8; a truncated 3-byte sequence at the end.
        let bytes: [UInt8] = Array("hello ".utf8) + [0xFF, 0xFE] + Array(" world".utf8) + [0xE2, 0x82]
        try write(bytes, to: "latin.md")
        let body = try NoteStore(root: root).read(NoteID(relativePath: "latin.md"))
        guard case .invalidUTF8(let lossy) = body else { return XCTFail("expected .invalidUTF8, got \(body)") }
        XCTAssertFalse(body.isWritable)
        XCTAssertEqual(body.displayText, lossy)
        XCTAssertTrue(lossy.hasPrefix("hello "))
        XCTAssertTrue(lossy.contains("\u{FFFD}"))
        XCTAssertTrue(lossy.contains(" world"))
    }

    func testL8_latin1BodyIsFlagged() throws {
        // "café" in ISO-8859-1: the é is a lone 0xE9.
        try write([0x63, 0x61, 0x66, 0xE9], to: "cafe.md")
        let body = try NoteStore(root: root).read(NoteID(relativePath: "cafe.md"))
        XCTAssertFalse(body.isWritable)
        XCTAssertEqual(body.displayText, "caf\u{FFFD}")
    }

    // MARK: L-7 availability

    func testL7_ordinaryFileIsDownloaded() throws {
        try write(Array("x".utf8), to: "plain.md")
        XCTAssertTrue(NoteStore.isDownloaded(root.appendingPathComponent("plain.md")))
    }

    func testL7_unavailableFileIsReportedWithoutReading() throws {
        try write(Array("on disk".utf8), to: "evicted.md")
        let store = NoteStore(root: root, isAvailable: { _ in false })
        let body = try store.read(NoteID(relativePath: "evicted.md"))
        XCTAssertEqual(body, .notDownloaded)
        XCTAssertNil(body.displayText)
        XCTAssertFalse(body.isWritable)
    }

    func testL7_probeReceivesTheNoteURL() throws {
        try write(Array("x".utf8), to: "a/b.md")
        let expected = root.appendingPathComponent("a/b.md").standardizedFileURL
        let store = NoteStore(root: root, isAvailable: { $0.standardizedFileURL == expected })
        XCTAssertEqual(try store.read(NoteID(relativePath: "a/b.md")), .text("x"))
    }

    func testL7_requestDownloadOfOrdinaryFileIsHarmless() throws {
        try write(Array("x".utf8), to: "plain.md")
        let store = NoteStore(root: root)
        store.requestDownload(of: NoteID(relativePath: "plain.md"))
        store.requestDownload(of: NoteID(relativePath: "missing.md"))
        XCTAssertEqual(try store.read(NoteID(relativePath: "plain.md")), .text("x"))
    }

    // MARK: errors

    func testMissingFileThrows() {
        XCTAssertThrowsError(try NoteStore(root: root).read(NoteID(relativePath: "missing.md")))
    }

    func testURLForIDIsUnderRoot() {
        let store = NoteStore(root: root)
        XCTAssertEqual(
            store.url(for: NoteID(relativePath: "daily/2026/06-sunday.md")).path,
            root.appendingPathComponent("daily/2026/06-sunday.md").path)
    }
}
