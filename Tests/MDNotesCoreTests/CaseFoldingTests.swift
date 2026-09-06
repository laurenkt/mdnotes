import Foundation
import MDNotesCore
import XCTest

final class CaseFoldingTests: XCTestCase {
    // MARK: S-2 the folding behind case-insensitive matching

    func testS2_foldLowercasesASCII() {
        XCTAssertEqual(CaseFolding.fold("Meeting Notes"), "meeting notes")
        XCTAssertEqual(CaseFolding.fold("MEETING"), "meeting")
        XCTAssertEqual(CaseFolding.fold("GuGgEnHeIm"), "guggenheim")
        XCTAssertEqual(CaseFolding.fold("already lower"), "already lower")
    }

    func testS2_foldLowercasesNonASCII() {
        XCTAssertEqual(CaseFolding.fold("FRANTIŠEK"), "františek")
        XCTAssertEqual(CaseFolding.fold("École"), "école")
        XCTAssertEqual(CaseFolding.fold("STRAßE"), "straße")
        XCTAssertEqual(CaseFolding.fold("Ärger"), "ärger")
    }

    func testS2_foldIsIdempotent() {
        for text in ["Meeting Notes", "FRANTIŠEK", "#Dev/Swift_2", "", "  \t\n"] {
            let once = CaseFolding.fold(text)
            XCTAssertEqual(CaseFolding.fold(once), once, "folding \(text) twice changed it")
        }
    }

    func testS2_foldChangesNothingButCase() {
        // No tokenising, trimming, or normalising (ADR-0003): everything that is not a cased
        // letter survives byte-for-byte, including whitespace, punctuation, `#`, `/`, digits.
        XCTAssertEqual(CaseFolding.fold("  #Dev/Swift_2 (Beta)!\t\n"), "  #dev/swift_2 (beta)!\t\n")
        XCTAssertEqual(CaseFolding.fold("2026-06-07"), "2026-06-07")
        XCTAssertEqual(CaseFolding.fold("[[Target|Label]]"), "[[target|label]]")
        XCTAssertEqual(CaseFolding.fold(""), "")
    }

    func testS2_foldIsTheSameForStringAndSubstring() {
        let text = "Alpha BETA"
        let substring = text[text.index(text.startIndex, offsetBy: 6)...]
        XCTAssertEqual(CaseFolding.fold(substring), "beta")
        XCTAssertEqual(CaseFolding.fold(String(substring)), CaseFolding.fold(substring))
    }

    func testS2_indexStoresTitlesAndBodiesWithTheSharedFolding() {
        // The search index folds with the same function, so anything folded elsewhere (a link
        // target, a tag, a typed query) compares against index text without surprises.
        let id = NoteID(relativePath: "Daily/FRANTIŠEK Kupka.md")
        let body = "Painter of Amorpha, Fugue in Two Colours. #Art/Modern"
        var builder = SearchIndex.Builder()
        builder.add(id: id, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), body: body)
        let entry = builder.build().entry(for: id)
        XCTAssertEqual(entry?.title, CaseFolding.fold(id.title))
        XCTAssertEqual(entry?.body, CaseFolding.fold(body))
    }

    // MARK: C-1 case-insensitive title equality

    func testC1_areEqualIgnoresCase() {
        XCTAssertTrue(CaseFolding.areEqual("Meeting Notes", "meeting notes"))
        XCTAssertTrue(CaseFolding.areEqual("MEETING NOTES", "Meeting Notes"))
        XCTAssertTrue(CaseFolding.areEqual("FRANTIŠEK", "františek"))
        XCTAssertTrue(CaseFolding.areEqual("", ""))
    }

    func testC1_areEqualIsExactApartFromCase() {
        XCTAssertFalse(CaseFolding.areEqual("Meeting Notes", "Meeting  Notes"))
        XCTAssertFalse(CaseFolding.areEqual("Meeting Notes", "Meeting Notes "))
        XCTAssertFalse(CaseFolding.areEqual("Meeting Notes", "Meeting Note"))
        XCTAssertFalse(CaseFolding.areEqual("Meeting Notes", "Meeting-Notes"))
        XCTAssertFalse(CaseFolding.areEqual("resume", "résumé"))
    }

    func testC1_areEqualMatchesATitleAgainstATypedQuery() {
        let id = NoteID(relativePath: "daily/2026/Sunday Plans.md")
        XCTAssertTrue(CaseFolding.areEqual(id.title, "sunday plans"))
        XCTAssertTrue(CaseFolding.areEqual(id.title, "SUNDAY PLANS"[...]))
        XCTAssertFalse(CaseFolding.areEqual(id.title, "sunday"))
        XCTAssertFalse(CaseFolding.areEqual(id.relativePath, "sunday plans"))
    }
}
