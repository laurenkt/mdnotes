import Foundation
import MDNotesCore
import XCTest

/// `TemplateQuery` (TP-5): which queries are template mode, how the name word and the title
/// words are read out of one, and how the name word filters templates by the S-2 rules.
final class TemplateQueryTests: XCTestCase {
    // MARK: TP-5 a query whose first character is `@` is template mode

    func testTP5_onlyAQueryStartingWithAtIsTemplateMode() {
        XCTAssertNotNil(TemplateQuery("@"))
        XCTAssertNotNil(TemplateQuery("@daily"))
        XCTAssertNotNil(TemplateQuery("@ daily"))
        XCTAssertNil(TemplateQuery(""))
        XCTAssertNil(TemplateQuery("daily"))
        XCTAssertNil(TemplateQuery("daily @meeting"), "`@` must be the first character")
        XCTAssertNil(TemplateQuery(" @daily"), "leading whitespace is not skipped")
        XCTAssertTrue(TemplateQuery.isTemplateMode("@x"))
        XCTAssertFalse(TemplateQuery.isTemplateMode("x@"))
    }

    // MARK: TP-5 the word after `@` is the name filter, the remaining words are the title

    func testTP5_atAloneHasAnEmptyFilterAndNoTitle() {
        XCTAssertEqual(TemplateQuery("@"), TemplateQuery(filter: "", title: ""))
        XCTAssertEqual(TemplateQuery("@   "), TemplateQuery(filter: "", title: ""))
    }

    func testTP5_theWordAttachedToAtIsTheFilter() {
        XCTAssertEqual(TemplateQuery("@daily"), TemplateQuery(filter: "daily", title: ""))
        XCTAssertEqual(TemplateQuery("@Daily "), TemplateQuery(filter: "Daily", title: ""), "as typed")
        XCTAssertEqual(TemplateQuery("@meeting/notes"), TemplateQuery(filter: "meeting/notes", title: ""))
    }

    func testTP5_theRemainingWordsAreTheTitleJoinedBySingleSpaces() {
        XCTAssertEqual(TemplateQuery("@meeting Standup"), TemplateQuery(filter: "meeting", title: "Standup"))
        XCTAssertEqual(
            TemplateQuery("@meeting  Weekly\tsync  "), TemplateQuery(filter: "meeting", title: "Weekly sync"))
        XCTAssertEqual(TemplateQuery("@ Standup"), TemplateQuery(filter: "", title: "Standup"), "no name word")
        XCTAssertEqual(
            TemplateQuery("@meeting Ünïcode title"), TemplateQuery(filter: "meeting", title: "Ünïcode title"))
    }

    // MARK: S-2 the filter is a case-insensitive substring of the name

    func testS2_filterMatchesNamesByCaseInsensitiveSubstring() throws {
        let names = ["Alpha", "daily", "Meeting notes", "meeting"]
        XCTAssertEqual(try XCTUnwrap(TemplateQuery("@")).names(matching: names), names, "`@` alone lists all")
        XCTAssertEqual(try XCTUnwrap(TemplateQuery("@MEET")).names(matching: names), ["Meeting notes", "meeting"])
        XCTAssertEqual(try XCTUnwrap(TemplateQuery("@notes")).names(matching: names), ["Meeting notes"])
        XCTAssertEqual(try XCTUnwrap(TemplateQuery("@a")).names(matching: names), ["Alpha", "daily"])
        XCTAssertEqual(try XCTUnwrap(TemplateQuery("@zzz")).names(matching: names), [])
        XCTAssertEqual(
            try XCTUnwrap(TemplateQuery("@meeting Standup")).names(matching: names), ["Meeting notes", "meeting"],
            "the title words do not filter")
        XCTAssertTrue(try XCTUnwrap(TemplateQuery("@ALPHA")).matches("alpha"))
        XCTAssertFalse(try XCTUnwrap(TemplateQuery("@alpha")).matches("beta"))
    }

    func testS2_orderIsKeptAsGiven() throws {
        let names = ["zeta", "alpha", "Beta"]
        XCTAssertEqual(try XCTUnwrap(TemplateQuery("@")).names(matching: names), ["zeta", "alpha", "Beta"])
        XCTAssertEqual(try XCTUnwrap(TemplateQuery("@a")).names(matching: names), ["zeta", "alpha", "Beta"])
    }
}
