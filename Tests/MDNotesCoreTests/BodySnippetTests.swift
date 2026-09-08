import Foundation
import MDNotesCore
import XCTest

/// The single-line body snippet each list row shows (S-6), and its survival inside the index.
final class BodySnippetTests: XCTestCase {
    func testS6_snippetFlattensWhitespaceOntoOneLine() {
        let body = "  Heading\n\nline two\t\ttabbed \r\n  last\n"
        XCTAssertEqual(BodySnippet.make(from: body), "Heading line two tabbed last")
        XCTAssertFalse(BodySnippet.make(from: body).contains(where: \.isNewline))
    }

    func testS6_snippetKeepsCaseAndPunctuation() {
        XCTAssertEqual(BodySnippet.make(from: "Mixed CASE, #Tag and (more)!"), "Mixed CASE, #Tag and (more)!")
    }

    // MARK: S-6 (v2) markdown is stripped

    func testS6_snippetDropsHeadingMarkers() {
        XCTAssertEqual(BodySnippet.make(from: "# Title\n\nBody"), "Title Body")
        XCTAssertEqual(BodySnippet.make(from: "###### Six\n  ## Indented"), "Six Indented")
        XCTAssertEqual(BodySnippet.make(from: "#\ttabbed"), "tabbed")
        XCTAssertEqual(BodySnippet.make(from: "#"), "", "a bare marker is a heading with no text")
        XCTAssertEqual(BodySnippet.make(from: "#tag stays\n####### seven"), "#tag stays ####### seven")
        XCTAssertEqual(BodySnippet.make(from: "a # b"), "a # b", "only at line start")
    }

    func testS6_snippetDropsWikilinkBracketsAndShowsLabels() {
        XCTAssertEqual(BodySnippet.make(from: "See [[Kubernetes]] now"), "See Kubernetes now")
        XCTAssertEqual(BodySnippet.make(from: "See [[Kubernetes|k8s notes]] now"), "See k8s notes now")
        XCTAssertEqual(BodySnippet.make(from: "[[ spaced | label ]]"), "label")
        XCTAssertEqual(BodySnippet.make(from: "[[a/b]] and [[c]]"), "a/b and c")
        XCTAssertEqual(BodySnippet.make(from: "[[unclosed and [single]"), "[[unclosed and [single]")
    }

    func testS6_snippetDropsEmbedsEntirely() {
        XCTAssertEqual(BodySnippet.make(from: "![[photo.png]]"), "")
        XCTAssertEqual(BodySnippet.make(from: "Before ![[i/photo.png]] after"), "Before after")
        XCTAssertEqual(BodySnippet.make(from: "![[photo.png|alt]]\nText"), "Text")
        XCTAssertEqual(BodySnippet.make(from: "![[a.png]]![[b.png]]"), "")
    }

    func testS6_snippetDropsCodeFencesButKeepsTheCode() {
        XCTAssertEqual(BodySnippet.make(from: "```swift\nlet x = 1\n```\nafter"), "let x = 1 after")
        XCTAssertEqual(BodySnippet.make(from: "~~~\ncode\n~~~"), "code")
        XCTAssertEqual(BodySnippet.make(from: "```\nunclosed\nstill code"), "unclosed still code")
        XCTAssertEqual(BodySnippet.make(from: "```\n```"), "")
        XCTAssertEqual(BodySnippet.make(from: "```\n"), "")
        XCTAssertEqual(
            BodySnippet.make(from: "```\n# not a heading\n[[not a link]]\n```"), "# not a heading [[not a link]]")
        XCTAssertEqual(BodySnippet.make(from: "````\n```\n````"), "```", "a shorter run does not close")
        XCTAssertEqual(BodySnippet.make(from: "inline `code` stays"), "inline `code` stays")
    }

    func testS6_snippetDropsEmphasisMarkers() {
        XCTAssertEqual(BodySnippet.make(from: "*em* and **strong** and ***both***"), "em and strong and both")
        XCTAssertEqual(BodySnippet.make(from: "_em_ and __strong__"), "em and strong")
        XCTAssertEqual(BodySnippet.make(from: "**bold**, then *em*."), "bold, then em.")
        XCTAssertEqual(BodySnippet.make(from: "snake_case and __init__ stay"), "snake_case and init stay")
        XCTAssertEqual(BodySnippet.make(from: "2 * 3 ** 4"), "2 * 3 ** 4", "a run with space on both sides")
        XCTAssertEqual(BodySnippet.make(from: "* bullet\n* two"), "* bullet * two", "a bullet marker is not emphasis")
        XCTAssertEqual(BodySnippet.make(from: "`*not* stripped`"), "`*not* stripped`")
        XCTAssertEqual(BodySnippet.make(from: "```\na * b **c**\n```"), "a * b **c**")
    }

    func testS6_snippetOfNothingButSyntaxIsEmpty() {
        XCTAssertEqual(BodySnippet.make(from: "# \n![[a.png]]\n```\n```\n"), "")
        XCTAssertEqual(BodySnippet.make(from: "\n**\n"), "**", "a run with whitespace on both sides is literal")
    }

    func testS6_snippetStripsWithinTheScannedPrefixOnly() {
        // A fence opened inside the prefix and closed beyond it: the code still shows.
        let body = "```\n" + String(repeating: "x", count: BodySnippet.scanCharacters) + "\n```"
        XCTAssertEqual(BodySnippet.make(from: body), String(repeating: "x", count: BodySnippet.maxCharacters))
        // A surrogate pair split by the prefix cut is dropped, never decoded as garbage.
        let emoji = String(repeating: "a", count: BodySnippet.scanCharacters - 1) + "😀"
        XCTAssertEqual(BodySnippet.make(from: emoji).count, BodySnippet.maxCharacters)
        XCTAssertEqual(BodySnippet.make(from: "😀 *hi*"), "😀 hi")
    }

    func testPF2_snippetIsStrippedWhenTheIndexIsBuiltNotWhenRead() {
        let a = NoteID(relativePath: "A.md")
        var builder = SearchIndex.Builder()
        builder.add(id: a, modifiedAt: Date(), body: "# Title\n![[i/photo.png]]\n**Bold** [[Link|label]]")
        let index = builder.build()
        let entry = try? XCTUnwrap(index.entry(for: a))
        XCTAssertEqual(entry?.preview, "Title Bold label")
        // The stripped text is what the arena stores: reading it is a byte decode, and a
        // query does not touch it, so the cost of stripping stays in the build (PF-2).
        XCTAssertEqual(index.query("").first?.preview, "Title Bold label")
        XCTAssertEqual(entry?.body, "# title\n![[i/photo.png]]\n**bold** [[link|label]]", "search text is not stripped")
        XCTAssertEqual(index.query("photo").map(\.id), [a], "stripping never removes searchable words")
    }

    func testS6_snippetIsCutToMaxCharacters() {
        let ascii = String(repeating: "a", count: 500) + " b"
        XCTAssertEqual(BodySnippet.make(from: ascii).count, BodySnippet.maxCharacters)
        // Cut on character boundaries, never inside a multi-byte scalar.
        let accented = String(repeating: "é", count: 300)
        let snippet = BodySnippet.make(from: accented)
        XCTAssertEqual(snippet.count, BodySnippet.maxCharacters)
        XCTAssertEqual(snippet, String(repeating: "é", count: BodySnippet.maxCharacters))
        // Decomposed marks, a ZWJ sequence, a skin-tone modifier and an emoji pair straddling the
        // cut: the snippet ends one whole character early rather than mid-character.
        let decomposed = String(repeating: "a", count: BodySnippet.maxCharacters - 1) + "e\u{301}"
        XCTAssertEqual(BodySnippet.make(from: decomposed), String(repeating: "a", count: BodySnippet.maxCharacters - 1))
        let family = String(repeating: "a", count: BodySnippet.maxCharacters - 5) + "👩‍👩‍👧x"
        XCTAssertEqual(BodySnippet.make(from: family), String(repeating: "a", count: BodySnippet.maxCharacters - 5))
        let wave = String(repeating: "a", count: BodySnippet.maxCharacters - 2) + "👋🏽"
        XCTAssertEqual(BodySnippet.make(from: wave), String(repeating: "a", count: BodySnippet.maxCharacters - 2))
        let split = String(repeating: "a", count: BodySnippet.maxCharacters - 1) + "😀"
        XCTAssertEqual(BodySnippet.make(from: split), String(repeating: "a", count: BodySnippet.maxCharacters - 1))
        XCTAssertEqual(BodySnippet.make(from: split + "b").utf16.count, BodySnippet.maxCharacters - 1)
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
        // The limit is in UTF-16 units whatever the script: the 2048th unit is in, the next out.
        let cjk = String(repeating: " ", count: BodySnippet.scanCharacters - 1) + "漢 late"
        XCTAssertEqual(BodySnippet.make(from: cjk), "漢")
        XCTAssertEqual(
            BodySnippet.make(from: String(repeating: "漢", count: 1_000_000)).count, BodySnippet.maxCharacters)
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
