import AppKit
import Foundation
import MDNotesApp
import XCTest

/// `RTFToMarkdown` (ED-13): one byte-exact fixture per RTF source (TextEdit, Pages) under
/// `Fixtures/`, plus one test per construct derived from the attributed string.
final class RTFToMarkdownTests: XCTestCase {
    // MARK: ED-13 fixtures: what each app puts on the pasteboard, byte-exact

    func testED13_texteditFixture() throws {
        try assertFixture("textedit")
    }

    func testED13_pagesFixture() throws {
        try assertFixture("pages")
    }

    private func assertFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let rtf = try Data(contentsOf: fixtureURL(name, extension: "rtf"))
        let expected = try String(contentsOf: fixtureURL(name, extension: "md"), encoding: .utf8)
        let markdown = try XCTUnwrap(RTFToMarkdown.markdown(fromRTF: rtf), "\(name).rtf did not decode")
        XCTAssertEqual(markdown, expected, "\(name).rtf", file: file, line: line)
    }

    private func fixtureURL(_ name: String, extension ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "missing fixture \(name).\(ext)")
    }

    // MARK: ED-13 decoding

    func testED13_rtfDataDecodesAndUndecodableIsNil() {
        let rtf = "{\\rtf1\\ansi{\\fonttbl\\f0\\fswiss Helvetica;}\\f0\\fs24 Plain and \\b bold\\b0  text.\\\n}"
        XCTAssertEqual(RTFToMarkdown.markdown(fromRTF: Data(rtf.utf8)), "Plain and **bold** text.")
        XCTAssertNil(RTFToMarkdown.markdown(fromRTF: Data("not rtf at all".utf8)))
        XCTAssertEqual(RTFToMarkdown.markdown(fromRTF: Data("{\\rtf1\\ansi}".utf8)), "", "no text")
    }

    // MARK: ED-13 font traits

    func testED13_fontTraitsBecomeEmphasis() {
        XCTAssertEqual(convert(run("a "), run("bold", bold: true), run(" b")), "a **bold** b")
        XCTAssertEqual(convert(run("a "), run("it", italic: true), run(" b")), "a *it* b")
        XCTAssertEqual(convert(run("a "), run("both", bold: true, italic: true), run(" b")), "a ***both*** b")
        XCTAssertEqual(convert(run("a "), run("gone", strike: true), run(" b")), "a ~~gone~~ b")
        XCTAssertEqual(convert(run("all", bold: true, italic: true, strike: true)), "***~~all~~***")
    }

    func testED13_emphasisKeepsEdgeWhitespaceOutsideAndJoinsSplitRuns() {
        XCTAssertEqual(convert(run("a"), run(" bold ", bold: true), run("c")), "a **bold** c")
        XCTAssertEqual(
            convert(run("a "), run("b", bold: true), run(" ", bold: true), run("c", bold: true)), "a **b c**")
        XCTAssertEqual(convert(run("a"), run(" ", bold: true), run("b")), "a b", "whitespace-only emphasis")
        XCTAssertEqual(convert(run("red", bold: true, colour: .red), run("blue", bold: true)), "**redblue**")
        XCTAssertEqual(
            convert(run("x", bold: true), run(" ", bold: true, colour: .red), run("y", bold: true)), "**x y**")
    }

    func testED13_emphasisClosesAndReopensAtEveryChangeOfTraits() {
        XCTAssertEqual(
            convert(run("a ", bold: true), run("b", bold: true, italic: true), run(" c", italic: true)), "**a *b*** *c*"
        )
        XCTAssertEqual(
            convert(run("a", italic: true), run(" b", bold: true, italic: true), run(" c", bold: true)),
            "*a* ***b* c**", "bold is always the outer marker")
        XCTAssertEqual(
            convert(run("a", bold: true, strike: true), run("b", bold: true, italic: true)), "**~~a~~*b***")
    }

    // MARK: ED-13 links

    func testED13_links() throws {
        let url = try XCTUnwrap(URL(string: "https://x.y/z"))
        XCTAssertEqual(convert(run("see "), run("this", link: url), run(".")), "see [this](https://x.y/z).")
        XCTAssertEqual(convert(run("https://x.y/z", link: url)), "<https://x.y/z>", "URL as text")
        XCTAssertEqual(convert(run("text", link: "https://x.y/z")), "[text](https://x.y/z)", "string value")
        XCTAssertEqual(convert(run("top", link: "#top"), run(" "), run("js", link: "javascript:void(0)")), "top js")
        XCTAssertEqual(convert(run("t", link: "https://x.y/a b(c)")), "[t](https://x.y/a%20b%28c%29)")
        XCTAssertEqual(
            convert(run("x"), run(" ", link: url), run("a", link: url), run(" ", link: url), run("y")),
            "x [a](https://x.y/z) y", "whitespace at a link's edges stays outside it")
        XCTAssertEqual(
            convert(run("a", link: url), run("b", link: "https://x.y/w")), "[a](https://x.y/z)[b](https://x.y/w)")
    }

    func testED13_emphasisInsideALinkClosesBeforeTheBracket() {
        XCTAssertEqual(convert(run("x ", bold: true), run("a", bold: true, link: "u:1"), run(" b")), "**x [a](u:1)** b")
        XCTAssertEqual(convert(run("a", bold: true, link: "u:1"), run(" b")), "[**a**](u:1) b")
        XCTAssertEqual(convert(run("a ", link: "u:1"), run("b", italic: true, link: "u:1")), "[a *b*](u:1)")
        XCTAssertEqual(convert(run("a", bold: true, link: "u:1"), run("b", code: true)), "[**a**](u:1)`b`")
    }

    // MARK: ED-13 code

    func testED13_fixedPitchRunsAreCodeSpans() {
        XCTAssertEqual(convert(run("run "), run("ls -la", code: true), run(" now")), "run `ls -la` now")
        XCTAssertEqual(convert(run("x "), run("a `b` c", code: true)), "x ``a `b` c``")
        XCTAssertEqual(convert(run("x "), run("`tick", code: true)), "x `` `tick ``")
        XCTAssertEqual(
            convert(run("a "), run("x", bold: true, code: true), run(" b")), "a `x` b", "no emphasis in code")
        XCTAssertEqual(
            convert(run("a ", bold: true), run("x", bold: true, code: true), run(" b", bold: true)), "**a `x` b**")
        XCTAssertEqual(convert(run("a"), run(" ", code: true), run("b")), "a b", "empty code")
    }

    func testED13_fixedPitchParagraphsAreOneFencedBlock() {
        XCTAssertEqual(
            convert(
                run("Run:\n"), run("let x = 1\n", code: true), run("\n", code: true), run("print(x)\n", code: true),
                run("Done\n")),
            "Run:\n\n```\nlet x = 1\n\nprint(x)\n```\n\nDone")
        XCTAssertEqual(convert(run("a\n", code: true), run("\n"), run("b\n", code: true)), "```\na\n```\n\n```\nb\n```")
        XCTAssertEqual(
            convert(run("```\n", code: true), run("x\n", code: true)), "````\n```\nx\n````", "a longer fence")
        XCTAssertEqual(
            convert(run("  indented\n", code: true), run("\n", code: true)), "```\n  indented\n```", "verbatim")
    }

    // MARK: ED-13 list markers

    func testED13_listMarkersNestByTwoSpaces() {
        let bullets = NSTextList(markerFormat: .disc, options: 0)
        let numbers = NSTextList(markerFormat: .decimal, options: 0)
        XCTAssertEqual(
            convert(
                run("before\n"), run("a\n", lists: [bullets]), run("b\n", lists: [bullets, numbers]),
                run("c\n", lists: [bullets, numbers]), run("d\n", lists: [bullets]), run("after\n")),
            "before\n\n- a\n  1. b\n  2. c\n- d\n\nafter")
    }

    func testED13_orderedListsNumberFromTheirStart() {
        let numbers = NSTextList(markerFormat: .decimal, options: 0)
        numbers.startingItemNumber = 3
        let more = NSTextList(markerFormat: .lowercaseAlpha, options: 0)
        XCTAssertEqual(
            convert(run("x\n", lists: [numbers]), run("y\n", lists: [numbers]), run("z\n", lists: [more])),
            "3. x\n4. y\n\n1. z", "another list starts again")
        XCTAssertEqual(
            convert(run("x\n", lists: [numbers]), run("\n", lists: [numbers]), run("y\n", lists: [numbers])),
            "3. x\n\n4. y", "an empty item keeps the list open")
    }

    func testED13_itemTextIsTrimmedAndAMarkerLeftInTheTextIsDropped() {
        let bullets = NSTextList(markerFormat: .disc, options: 0)
        let numbers = NSTextList(markerFormat: .decimal, options: 0)
        XCTAssertEqual(
            convert(run("\t\u{2022}\ta  \n", lists: [bullets]), run("\t1.\tb\n", lists: [numbers])), "- a\n\n1. b")
        XCTAssertEqual(
            convert(
                run("one", lists: [bullets]), run("\u{2028}two\n", lists: [bullets]), run("three\n", lists: [bullets])),
            "- one\n  two\n- three", "a line break continues under the item text")
        XCTAssertEqual(convert(run("a\n", lists: [bullets]), run("b", bold: true, lists: [bullets])), "- a\n- **b**")
    }

    // MARK: ED-13 paragraphs and line breaks

    func testED13_paragraphsAreLinesAndEmptyOnesOneBlankLine() {
        XCTAssertEqual(convert(run("a\nb\n")), "a\nb")
        XCTAssertEqual(convert(run("a\n\n\n\nb\n")), "a\n\nb")
        XCTAssertEqual(convert(run("\n\na\u{2029}b\r\nc\r")), "a\nb\nc")
        XCTAssertEqual(convert(run("a\u{2028}b\n")), "a\nb", "a line separator")
        XCTAssertEqual(convert(run("a   \n  b\t\n")), "a\n  b", "trailing whitespace goes")
        XCTAssertEqual(convert(run("a \u{FFFC}b\n")), "a b", "attachment characters go")
    }

    func testED13_paragraphSpacingMakesABlankLine() {
        let spaced = NSMutableParagraphStyle()
        spaced.paragraphSpacing = 12
        let before = NSMutableParagraphStyle()
        before.paragraphSpacingBefore = 6
        XCTAssertEqual(convert(run("a\n", style: spaced), run("b\n"), run("c\n")), "a\n\nb\nc")
        XCTAssertEqual(convert(run("a\n"), run("b\n", style: before), run("c\n")), "a\n\nb\nc")
        XCTAssertEqual(convert(run("a\n", style: spaced), run("\n"), run("b\n")), "a\n\nb", "never more than one")
    }

    func testED13_otherAttributesContributeOnlyText() {
        let big = NSFont(name: "Helvetica", size: 24)
        XCTAssertEqual(
            convert(
                run("u", underline: true), run(" "), run("c", colour: .red), run(" "), run("big", font: big),
                run(" "), run("bg", background: .yellow)),
            "u c big bg")
    }

    // MARK: Helpers

    private func convert(_ runs: NSAttributedString...) -> String {
        let text = NSMutableAttributedString()
        for run in runs { text.append(run) }
        return RTFToMarkdown.markdown(from: text)
    }

    /// One run in the fonts TextEdit uses: Helvetica and its bold, oblique and bold-oblique
    /// faces, Menlo for code.
    private func run(
        _ text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, code: Bool = false,
        underline: Bool = false, link: Any? = nil, lists: [NSTextList] = [], style: NSParagraphStyle? = nil,
        colour: NSColor? = nil, background: NSColor? = nil, font: NSFont? = nil
    ) -> NSAttributedString {
        let name: String
        switch (code, bold, italic) {
        case (true, _, _): name = "Menlo-Regular"
        case (false, true, true): name = "Helvetica-BoldOblique"
        case (false, true, false): name = "Helvetica-Bold"
        case (false, false, true): name = "Helvetica-Oblique"
        case (false, false, false): name = "Helvetica"
        }
        var attributes: [NSAttributedString.Key: Any] = [:]
        attributes[.font] = font ?? NSFont(name: name, size: 12)
        if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let link { attributes[.link] = link }
        if let colour { attributes[.foregroundColor] = colour }
        if let background { attributes[.backgroundColor] = background }
        if let style {
            attributes[.paragraphStyle] = style
        } else if !lists.isEmpty {
            let style = NSMutableParagraphStyle()
            style.textLists = lists
            attributes[.paragraphStyle] = style
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}
