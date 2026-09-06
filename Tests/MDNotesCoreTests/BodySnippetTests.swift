import Foundation
import MDNotesCore
import XCTest

/// The single-line body snippet each list row shows (S-6), and its survival inside the index.
final class BodySnippetTests: XCTestCase {
    func testS6_snippetFlattensWhitespaceOntoOneLine() {
        let body = "  # Heading\n\nline two\t\ttabbed \r\n  last\n"
        XCTAssertEqual(BodySnippet.make(from: body), "# Heading line two tabbed last")
        XCTAssertFalse(BodySnippet.make(from: body).contains(where: \.isNewline))
    }

    func testS6_snippetKeepsCaseAndPunctuation() {
        XCTAssertEqual(BodySnippet.make(from: "Mixed CASE, #Tag and [[Link]]!"), "Mixed CASE, #Tag and [[Link]]!")
    }

    func testS6_snippetIsCutToMaxCharacters() {
        let ascii = String(repeating: "a", count: 500) + " b"
        XCTAssertEqual(BodySnippet.make(from: ascii).count, BodySnippet.maxCharacters)
        // Cut on character boundaries, never inside a multi-byte scalar.
        let accented = String(repeating: "é", count: 300)
        let snippet = BodySnippet.make(from: accented)
        XCTAssertEqual(snippet.count, BodySnippet.maxCharacters)
        XCTAssertEqual(snippet, String(repeating: "é", count: BodySnippet.maxCharacters))
    }

    func testS6_snippetOfBlankBodyIsEmpty() {
        XCTAssertEqual(BodySnippet.make(from: ""), "")
        XCTAssertEqual(BodySnippet.make(from: "\n \t\n"), "")
    }

    func testS6_snippetOnlyLooksAtTheStartOfALargeBody() {
        let body = String(repeating: " ", count: BodySnippet.scanCharacters + 10) + "late"
        XCTAssertEqual(BodySnippet.make(from: body), "")
        let large = "first words\n" + String(repeating: "x", count: 1_000_000)
        XCTAssertTrue(BodySnippet.make(from: large).hasPrefix("first words x"))
    }

    func testS6_entryPreviewIsOriginalCaseAndSurvivesRepack() {
        let a = NoteID(relativePath: "A.md")
        let b = NoteID(relativePath: "B.md")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        var builder = SearchIndex.Builder()
        builder.add(id: a, modifiedAt: at, body: "Alpha Body\nsecond line")
        builder.add(id: b, modifiedAt: at.addingTimeInterval(60), body: "Beta Body")
        let index = builder.build()
        XCTAssertEqual(index.entry(for: a)?.preview, "Alpha Body second line")
        XCTAssertEqual(index.entry(for: a)?.body, "alpha body\nsecond line", "the searched text stays folded")
        XCTAssertEqual(index.entry(for: b)?.preview, "Beta Body")

        // Updating one note repacks the arena; the other note's preview must come through intact.
        let updated = index.applying(changes: LibraryChanges(modified: [b])) { _ in
            (modifiedAt: at.addingTimeInterval(120), body: "Beta REWRITTEN")
        }
        XCTAssertEqual(updated.entry(for: a)?.preview, "Alpha Body second line")
        XCTAssertEqual(updated.entry(for: b)?.preview, "Beta REWRITTEN")
        // And the preview bytes are not searchable text: "rewritten" matches via the body only,
        // while a word split across the body/preview boundary must not match.
        XCTAssertEqual(updated.query("rewritten").map(\.id), [b])
        XCTAssertEqual(updated.query("lineAlpha").count, 0)
        XCTAssertEqual(updated.query("rewrittenBeta").count, 0)
    }
}
