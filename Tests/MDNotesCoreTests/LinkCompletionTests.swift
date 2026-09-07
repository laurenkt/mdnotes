import Foundation
import MDNotesCore
import XCTest

/// The `[[` completion's rules (K-4) apart from the popover: when a session opens, what text
/// it filters on, and which titles that text lists.
final class LinkCompletionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func index(_ notes: [(path: String, minutes: Int, body: String)]) -> SearchIndex {
        var builder = SearchIndex.Builder()
        for note in notes {
            builder.add(
                id: NoteID(relativePath: note.path), modifiedAt: epoch.addingTimeInterval(Double(note.minutes) * 60),
                body: note.body)
        }
        return builder.build()
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    // MARK: K-4 typing `[[` opens a session

    func testK4_aSessionOpensOnlyWithTheCaretRightAfterTwoOpeningBrackets() {
        let text = "see [[ and [x[" as NSString
        XCTAssertEqual(LinkCompletion.anchor(in: text, caret: caret(6)), 6)
        XCTAssertNil(LinkCompletion.anchor(in: text, caret: caret(5)), "one bracket")
        XCTAssertNil(LinkCompletion.anchor(in: text, caret: caret(7)), "a space after the brackets")
        XCTAssertNil(LinkCompletion.anchor(in: text, caret: caret(text.length)), "[x[ is not [[")
        XCTAssertNil(LinkCompletion.anchor(in: text, caret: NSRange(location: 6, length: 1)), "a selection")
        XCTAssertNil(LinkCompletion.anchor(in: "[[" as NSString, caret: caret(3)), "past the end")
        XCTAssertEqual(LinkCompletion.anchor(in: "[[" as NSString, caret: caret(2)), 2)
        XCTAssertNil(LinkCompletion.anchor(in: "[" as NSString, caret: caret(1)))
    }

    // MARK: K-4 the text typed since `[[` is the filter

    func testK4_theFilterIsTheTextBetweenTheBracketsAndTheCaret() {
        let text = "see [[Be ta" as NSString
        XCTAssertEqual(LinkCompletion.filterText(in: text, anchor: 6, caret: caret(6)), "")
        XCTAssertEqual(LinkCompletion.filterText(in: text, anchor: 6, caret: caret(8)), "Be")
        XCTAssertEqual(LinkCompletion.filterText(in: text, anchor: 6, caret: caret(text.length)), "Be ta")
    }

    func testK4_theSessionEndsWhenTheCaretLeavesOrTheLinkIsClosedOrBroken() {
        XCTAssertNil(LinkCompletion.filterText(in: "see [[Be" as NSString, anchor: 6, caret: caret(5)), "caret before")
        XCTAssertNil(
            LinkCompletion.filterText(in: "see [[Be" as NSString, anchor: 6, caret: NSRange(location: 6, length: 2)),
            "a selection")
        XCTAssertNil(LinkCompletion.filterText(in: "see [[Be]" as NSString, anchor: 6, caret: caret(9)), "closed")
        XCTAssertNil(LinkCompletion.filterText(in: "see [[Be\n" as NSString, anchor: 6, caret: caret(9)), "line break")
        XCTAssertNil(
            LinkCompletion.filterText(in: "see [Be" as NSString, anchor: 6, caret: caret(7)), "bracket deleted")
        XCTAssertNil(
            LinkCompletion.filterText(in: "see x[Be" as NSString, anchor: 6, caret: caret(8)), "bracket replaced")
        XCTAssertNil(LinkCompletion.filterText(in: "[[" as NSString, anchor: 2, caret: caret(3)), "past the end")
        XCTAssertNil(LinkCompletion.filterText(in: "[" as NSString, anchor: 1, caret: caret(1)), "anchor too early")
    }

    // MARK: K-4 titles are matched with the S-2 rules

    func testK4_titlesMatchEveryWordAsACaseInsensitiveSubstringOfTheTitleOnly() {
        let index = self.index([
            ("Alpha.md", 1, "beta zeta in the body"),
            ("daily/Beta.md", 2, ""),
            ("Gamma.md", 3, ""),
            ("Zeta.md", 4, ""),
        ])
        XCTAssertEqual(LinkCompletion.titles(matching: "", in: index), ["Zeta", "Gamma", "Beta", "Alpha"])
        XCTAssertEqual(
            LinkCompletion.titles(matching: "ET", in: index), ["Zeta", "Beta"], "case-insensitive substring")
        XCTAssertEqual(LinkCompletion.titles(matching: "ta e", in: index), ["Zeta", "Beta"], "every word, any order")
        XCTAssertEqual(LinkCompletion.titles(matching: "beta zeta", in: index), [], "the body does not count")
        XCTAssertEqual(LinkCompletion.titles(matching: "  gam  ", in: index), ["Gamma"], "whitespace splits words")
        XCTAssertEqual(LinkCompletion.titles(matching: "nothing", in: index), [])
        XCTAssertEqual(LinkCompletion.titles(matching: "", in: .empty), [])
    }

    func testK4_titlesAreListedMostRecentlyModifiedFirstAndOnceIgnoringCase() {
        let index = self.index([
            ("archive/Zeta.md", 1, ""),
            ("Alpha.md", 2, ""),
            ("daily/zeta.md", 3, ""),
        ])
        XCTAssertEqual(LinkCompletion.titles(matching: "", in: index), ["zeta", "Alpha"], "the newest spelling")
        XCTAssertEqual(LinkCompletion.titles(matching: "zeta", in: index), ["zeta"])
    }

    func testK4_theInsertionIsTheTitleAndTheClosingBrackets() {
        XCTAssertEqual(LinkCompletion.insertion(for: "Beta"), "Beta]]")
        XCTAssertEqual(LinkCompletion.insertion(for: "daily/Beta"), "daily/Beta]]")
    }
}
