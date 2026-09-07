import Foundation
import MDNotesCore
import XCTest

/// The `#` completion's rules (T-3) apart from the popover: when a session opens, what prefix
/// it filters on, and which known tags that prefix lists.
final class TagCompletionTests: XCTestCase {
    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    private func tags(_ notes: [(path: String, tags: [String])]) -> TagIndex {
        TagIndex.empty.applying(
            upserts: notes.map { (id: NoteID(relativePath: $0.path), tags: $0.tags) }, removing: [])
    }

    // MARK: T-3 typing `#` opens a session where a tag can begin (T-1)

    func testT3_aSessionOpensWithTheCaretRightAfterAHashAtLineStartOrAfterWhitespace() {
        XCTAssertEqual(TagCompletion.anchor(in: "#" as NSString, caret: caret(1)), 1, "start of the text")
        XCTAssertEqual(TagCompletion.anchor(in: "see #" as NSString, caret: caret(5)), 5, "after a space")
        XCTAssertEqual(TagCompletion.anchor(in: "see\n#" as NSString, caret: caret(5)), 5, "start of a line")
        XCTAssertEqual(TagCompletion.anchor(in: "see\t#" as NSString, caret: caret(5)), 5, "after a tab")
        XCTAssertNil(TagCompletion.anchor(in: "C#" as NSString, caret: caret(2)), "glued to a word is not a tag")
        XCTAssertNil(TagCompletion.anchor(in: "[[#" as NSString, caret: caret(3)), "nor inside brackets")
        XCTAssertNil(TagCompletion.anchor(in: "see #" as NSString, caret: caret(4)), "the caret before the #")
        XCTAssertNil(TagCompletion.anchor(in: "see #x" as NSString, caret: caret(6)), "the caret after more text")
        XCTAssertNil(
            TagCompletion.anchor(in: "see #" as NSString, caret: NSRange(location: 4, length: 1)), "a selection")
        XCTAssertNil(TagCompletion.anchor(in: "#" as NSString, caret: caret(2)), "past the end")
        XCTAssertNil(TagCompletion.anchor(in: "" as NSString, caret: caret(0)))
    }

    // MARK: T-3 the text typed since `#` is the prefix

    func testT3_theFilterIsTheTextBetweenTheHashAndTheCaret() {
        let text = "see #pro/Ject_1-x" as NSString
        XCTAssertEqual(TagCompletion.filterText(in: text, anchor: 5, caret: caret(5)), "")
        XCTAssertEqual(TagCompletion.filterText(in: text, anchor: 5, caret: caret(8)), "pro")
        XCTAssertEqual(
            TagCompletion.filterText(in: text, anchor: 5, caret: caret(text.length)), "pro/Ject_1-x",
            "every T-1 character")
    }

    func testT3_theSessionEndsWhenTheCaretLeavesOrTheTagEnds() {
        XCTAssertNil(TagCompletion.filterText(in: "see #pr" as NSString, anchor: 5, caret: caret(4)), "caret before")
        XCTAssertNil(
            TagCompletion.filterText(in: "see #pr" as NSString, anchor: 5, caret: NSRange(location: 5, length: 2)),
            "a selection")
        XCTAssertNil(TagCompletion.filterText(in: "see #pr " as NSString, anchor: 5, caret: caret(8)), "a space")
        XCTAssertNil(
            TagCompletion.filterText(in: "see # " as NSString, anchor: 5, caret: caret(6)), "a heading's space")
        XCTAssertNil(TagCompletion.filterText(in: "see #pr." as NSString, anchor: 5, caret: caret(8)), "punctuation")
        XCTAssertNil(TagCompletion.filterText(in: "see #pr\n" as NSString, anchor: 5, caret: caret(8)), "a line break")
        XCTAssertNil(TagCompletion.filterText(in: "see #p]" as NSString, anchor: 5, caret: caret(7)), "a bracket")
        XCTAssertNil(TagCompletion.filterText(in: "see pr" as NSString, anchor: 5, caret: caret(6)), "hash deleted")
        XCTAssertNil(TagCompletion.filterText(in: "see xpr" as NSString, anchor: 5, caret: caret(7)), "hash replaced")
        XCTAssertNil(
            TagCompletion.filterText(in: "seex#pr" as NSString, anchor: 5, caret: caret(7)), "the space before went")
        XCTAssertNil(TagCompletion.filterText(in: "#" as NSString, anchor: 1, caret: caret(2)), "past the end")
        XCTAssertNil(TagCompletion.filterText(in: "#" as NSString, anchor: 0, caret: caret(1)), "anchor too early")
    }

    // MARK: T-3 known tags are filtered by prefix

    func testT3_tagsAreFilteredByCaseInsensitivePrefixInTheLibrarySpelling() {
        let index = tags([
            ("a.md", ["swift", "AppKit", "project/mdnotes"]),
            ("b.md", ["swift", "Swift-UI"]),
            ("c.md", ["Swift", "golang"]),
        ])
        XCTAssertEqual(
            TagCompletion.tags(withPrefix: "", in: index),
            ["AppKit", "golang", "project/mdnotes", "swift", "Swift-UI"], "every tag, sorted ignoring case")
        XCTAssertEqual(TagCompletion.tags(withPrefix: "s", in: index), ["swift", "Swift-UI"])
        XCTAssertEqual(
            TagCompletion.tags(withPrefix: "SW", in: index), ["swift", "Swift-UI"], "the prefix's case is ignored")
        XCTAssertEqual(TagCompletion.tags(withPrefix: "swift-", in: index), ["Swift-UI"])
        XCTAssertEqual(
            TagCompletion.tags(withPrefix: "swift", in: index), ["swift", "Swift-UI"], "an exact tag still lists")
        XCTAssertEqual(TagCompletion.tags(withPrefix: "wift", in: index), [], "a prefix, not a substring")
        XCTAssertEqual(TagCompletion.tags(withPrefix: "project/m", in: index), ["project/mdnotes"])
        XCTAssertEqual(TagCompletion.tags(withPrefix: "q", in: index), [])
        XCTAssertEqual(TagCompletion.tags(withPrefix: "", in: .empty), [])
    }

    func testT3_theInsertionIsTheTagName() {
        XCTAssertEqual(TagCompletion.insertion(for: "swift"), "swift")
        XCTAssertEqual(TagCompletion.insertion(for: "project/mdnotes"), "project/mdnotes")
    }
}
