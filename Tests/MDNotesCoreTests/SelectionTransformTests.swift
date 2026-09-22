import Foundation
import MDNotesCore
import XCTest

/// `SelectionTransform` on its own (ED-16): the edges the editor's smoke tests leave out.
final class SelectionTransformTests: XCTestCase {
    /// `text` after `result`'s edits, applied from the last to the first.
    private func applying(_ result: SelectionTransform.Result, to text: String) -> String {
        let string = NSMutableString(string: text)
        for edit in result.edits.reversed() { string.replaceCharacters(in: edit.range, with: edit.replacement) }
        return string as String
    }

    private func units(_ text: String) -> [UInt16] { Array(text.utf16) }

    /// The range of `from` through `to` in `text`.
    private func range(in text: String, from: String, to: String) -> NSRange {
        let string = text as NSString
        let start = string.range(of: from)
        let end = string.range(of: to, range: NSRange(location: start.location, length: string.length - start.location))
        return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
    }

    func testED16_crlfLinesKeepTheirTerminators() {
        let text = "a\r\nb\r\nc\r\n"
        let quoted = SelectionTransform.quote(units(text), selection: range(in: text, from: "a", to: "b\r\n"))
        XCTAssertEqual(applying(quoted, to: text), "> a\r\n> b\r\nc\r\n", "the \\n of b's \\r\\n is still line b")
        let fenced = SelectionTransform.codeBlock(units(text), selection: range(in: text, from: "b", to: "b"))
        let after = applying(fenced, to: text)
        XCTAssertEqual(after, "a\r\n```\r\nb\r\n```\r\nc\r\n")
        XCTAssertEqual((after as NSString).substring(with: fenced.selection), "```\r\nb\r\n```")
    }

    func testED16_unclosedBlockLosesItsOpeningFence() {
        let text = "x\n```\ncode\nmore\n"
        let result = SelectionTransform.codeBlock(units(text), selection: range(in: text, from: "code", to: "code"))
        let after = applying(result, to: text)
        XCTAssertEqual(after, "x\ncode\nmore\n")
        XCTAssertEqual((after as NSString).substring(with: result.selection), "code\nmore")
    }

    func testED16_emptyBlockGoesWhole() {
        let text = "```\n```\nafter\n"
        let result = SelectionTransform.codeBlock(units(text), selection: NSRange(location: 0, length: 7))
        XCTAssertEqual(applying(result, to: text), "after\n")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 0))
    }

    func testED16_quoteOfOnlyBlankLinesAddsPrefixes() {
        let text = "a\n\n\nb"
        let result = SelectionTransform.quote(units(text), selection: NSRange(location: 2, length: 2))
        XCTAssertEqual(applying(result, to: text), "a\n> \n> \nb")
    }
}
