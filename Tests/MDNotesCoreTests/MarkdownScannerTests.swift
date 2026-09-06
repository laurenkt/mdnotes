import Foundation
import MDNotesCore
import XCTest

final class MarkdownScannerTests: XCTestCase {
    private typealias Token = MarkdownScanner.Token
    private typealias Kind = MarkdownScanner.Kind

    /// The text covered by `range` of `text`.
    private func slice(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    /// The token texts of `kind`-matching tokens, in order.
    private func texts(of text: String, where predicate: (Kind) -> Bool) -> [String] {
        MarkdownScanner.scan(text).filter { predicate($0.kind) }.map { slice(text, $0.range) }
    }

    private func tags(in text: String) -> [String] {
        MarkdownScanner.scan(text).compactMap { token -> String? in
            guard case .tag(let name) = token.kind else { return nil }
            return slice(text, name)
        }
    }

    private struct Link: Equatable {
        let text: String
        let target: String
        let label: String?
        let isEmbed: Bool
    }

    private func links(in text: String) -> [Link] {
        MarkdownScanner.scan(text).compactMap { token -> Link? in
            guard case .wikilink(let target, let label, let isEmbed) = token.kind else { return nil }
            return Link(
                text: slice(text, token.range), target: slice(text, target),
                label: label.map { slice(text, $0) }, isEmbed: isEmbed)
        }
    }

    private func headings(in text: String) -> [(level: Int, text: String)] {
        MarkdownScanner.scan(text).compactMap { token in
            guard case .heading(let level) = token.kind else { return nil }
            return (level, slice(text, token.range))
        }
    }

    private func codeSpans(in text: String) -> [String] {
        texts(of: text) { $0 == .inlineCode }
    }

    private func fences(in text: String) -> [String] {
        texts(of: text) { $0 == .fencedCode }
    }

    // MARK: E-2 headings

    func testE2_atxHeadingsOfEveryLevel() {
        let text = "# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n####### Seven\n"
        let found = headings(in: text)
        XCTAssertEqual(found.map(\.level), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(found.map(\.text), ["# One", "## Two", "### Three", "#### Four", "##### Five", "###### Six"])
    }

    func testE2_headingNeedsSpaceTabOrLineEndAfterHashes() {
        XCTAssertEqual(headings(in: "#\tTabbed").map(\.text), ["#\tTabbed"])
        XCTAssertEqual(headings(in: "#").map(\.level), [1])
        XCTAssertEqual(headings(in: "##\n").map(\.level), [2])
        XCTAssertEqual(headings(in: "#nope").count, 0, "no space: a tag, not a heading")
        XCTAssertEqual(headings(in: "text # not a heading").count, 0, "not at line start")
    }

    func testE2_headingAllowsUpToThreeSpacesOfIndent() {
        XCTAssertEqual(headings(in: "   # Indented").map(\.text), ["# Indented"])
        XCTAssertEqual(headings(in: "    # Four spaces").count, 0)
    }

    func testE2_headingRangeExcludesTheLineTerminator() {
        let text = "# Title\r\nbody"
        let token = MarkdownScanner.scan(text).first
        XCTAssertEqual(token?.kind, .heading(level: 1))
        XCTAssertEqual(token?.range, NSRange(location: 0, length: 7))
    }

    func testE2_headingLineStillYieldsItsLinksAndTags() {
        let text = "# Meeting [[Agenda]] #work"
        XCTAssertEqual(headings(in: text).map(\.level), [1])
        XCTAssertEqual(links(in: text).map(\.target), ["Agenda"])
        XCTAssertEqual(tags(in: text), ["work"])
    }

    // MARK: K-1 wikilinks and embeds

    func testK1_wikilinkTargetIsATitle() {
        XCTAssertEqual(
            links(in: "see [[Meeting Notes]] later"),
            [Link(text: "[[Meeting Notes]]", target: "Meeting Notes", label: nil, isEmbed: false)])
    }

    func testK1_wikilinkTargetMayBeARelativePathWithoutExtension() {
        XCTAssertEqual(links(in: "[[daily/2026/06-sunday]]").map(\.target), ["daily/2026/06-sunday"])
    }

    func testK1_wikilinkWithLabel() {
        XCTAssertEqual(
            links(in: "[[Meeting Notes|the notes]]"),
            [Link(text: "[[Meeting Notes|the notes]]", target: "Meeting Notes", label: "the notes", isEmbed: false)])
        XCTAssertEqual(links(in: "[[a|b|c]]").first?.label, "b|c", "only the first pipe splits")
    }

    func testK1_embedIsALinkFlaggedAsEmbed() {
        XCTAssertEqual(
            links(in: "![[20260906-101500.png]]"),
            [Link(text: "![[20260906-101500.png]]", target: "20260906-101500.png", label: nil, isEmbed: true)])
        XCTAssertEqual(links(in: "![[img.png|alt]]").first?.label, "alt")
        XCTAssertEqual(links(in: "wow! [[x]]").first?.isEmbed, false, "the bang must touch the brackets")
    }

    func testK1_targetAndLabelAreTrimmed() {
        let found = links(in: "[[ Meeting Notes | notes ]]")
        XCTAssertEqual(found.first?.target, "Meeting Notes")
        XCTAssertEqual(found.first?.label, "notes")
        XCTAssertEqual(found.first?.text, "[[ Meeting Notes | notes ]]")
    }

    func testK1_severalLinksOnOneLineAndAcrossLines() {
        let text = "[[a]] and [[b|B]]\n![[c.png]] [[d]]"
        XCTAssertEqual(links(in: text).map(\.target), ["a", "b", "c.png", "d"])
        let ranges = MarkdownScanner.scan(text).map(\.range)
        XCTAssertEqual(ranges[0], NSRange(location: 0, length: 5))
        XCTAssertEqual(ranges[1], NSRange(location: 10, length: 7))
        XCTAssertEqual(ranges[2], NSRange(location: 18, length: 10))
        XCTAssertEqual(ranges[3], NSRange(location: 29, length: 5))
    }

    func testK1_malformedLinksAreNotLinks() {
        XCTAssertEqual(links(in: "[[]]").count, 0, "empty target")
        XCTAssertEqual(links(in: "[[   ]]").count, 0, "blank target")
        XCTAssertEqual(links(in: "[[ |label]]").count, 0, "blank target with label")
        XCTAssertEqual(links(in: "[[open").count, 0, "unclosed")
        XCTAssertEqual(links(in: "[[a]").count, 0, "single closing bracket")
        XCTAssertEqual(links(in: "[single]").count, 0, "markdown link syntax is not a wikilink")
        XCTAssertEqual(links(in: "[[a\nb]]").count, 0, "no newline inside")
        XCTAssertEqual(links(in: "[[a]b]]").count, 0, "no stray bracket inside")
    }

    func testK1_innerOpeningBracketsRestartTheLink() {
        XCTAssertEqual(links(in: "[[a [[b]]").map(\.target), ["b"])
        XCTAssertEqual(links(in: "[[[c]]").map(\.text), ["[[c]]"])
    }

    func testK1_linkContentsAreNotScannedForTags() {
        XCTAssertEqual(tags(in: "[[a|#b]] [[#c]]"), [])
    }

    // MARK: T-1 tags

    func testT1_tagCharactersAreLettersDigitsUnderscoreSlashHyphen() {
        XCTAssertEqual(
            tags(in: "#swift #UI_kit #dev/swift #a-b #2026"), ["swift", "UI_kit", "dev/swift", "a-b", "2026"])
    }

    func testT1_tagNeedsLineStartOrWhitespaceBefore() {
        XCTAssertEqual(tags(in: "#start"), ["start"])
        XCTAssertEqual(tags(in: "a #mid"), ["mid"])
        XCTAssertEqual(tags(in: "a\t#tab\n#next"), ["tab", "next"])
        XCTAssertEqual(tags(in: "a\u{00A0}#nbsp"), ["nbsp"])
        XCTAssertEqual(tags(in: "issue#123 c#"), [], "glued to a word")
        XCTAssertEqual(tags(in: "(#paren) \"#quoted\""), [], "punctuation before is not whitespace")
        XCTAssertEqual(tags(in: "##double #"), [], "no tag characters after the hash")
    }

    func testT1_trailingPunctuationIsExcluded() {
        XCTAssertEqual(
            tags(in: "#swift. #ui, #dev! #x: #y; #z? (#p) #q's"), ["swift", "ui", "dev", "x", "y", "z", "q"])
        let text = "tag #swift."
        let token = MarkdownScanner.scan(text).first
        XCTAssertEqual(token?.range, NSRange(location: 4, length: 6))
        if case .tag(let name) = token?.kind {
            XCTAssertEqual(name, NSRange(location: 5, length: 5))
        } else {
            XCTFail("expected a tag, got \(String(describing: token))")
        }
    }

    func testT1_nonASCIILettersEndATag() {
        XCTAssertEqual(tags(in: "#café #日本"), ["caf"])
    }

    func testT1_tagRangeIncludesTheHash() {
        let text = "x #swift"
        XCTAssertEqual(MarkdownScanner.scan(text).map(\.range), [NSRange(location: 2, length: 6)])
    }

    // MARK: T-1 code-span and fence exclusion

    func testT1_tagsAndLinksInsideInlineCodeAreExcluded() {
        let text = "use `#swift` and `[[not a link]]` but #real [[Real]]"
        XCTAssertEqual(tags(in: text), ["real"])
        XCTAssertEqual(links(in: text).map(\.target), ["Real"])
        XCTAssertEqual(codeSpans(in: text), ["`#swift`", "`[[not a link]]`"])
    }

    func testT1_tagsAndLinksInsideFencedBlocksAreExcluded() {
        let text = "#before [[b]]\n```swift\n#inside [[c]]\n# not a heading\n```\n#after [[d]]\n"
        XCTAssertEqual(tags(in: text), ["before", "after"])
        XCTAssertEqual(links(in: text).map(\.target), ["b", "d"])
        XCTAssertEqual(headings(in: text).count, 0)
        XCTAssertEqual(fences(in: text), ["```swift\n#inside [[c]]\n# not a heading\n```\n"])
    }

    // MARK: E-2 inline code

    func testE2_codeSpanNeedsAClosingRunOfTheSameLength() {
        XCTAssertEqual(codeSpans(in: "a `b` c"), ["`b`"])
        XCTAssertEqual(codeSpans(in: "a ``b ` c`` d"), ["``b ` c``"])
        XCTAssertEqual(codeSpans(in: "a `` b ` c"), [], "no run of two closes, and the lone run has no partner")
        XCTAssertEqual(codeSpans(in: "a `b `` c` d"), ["`b `` c`"])
        XCTAssertEqual(codeSpans(in: "unclosed ` #tag"), [])
        XCTAssertEqual(tags(in: "unclosed ` #tag"), ["tag"], "an unclosed run is literal")
    }

    func testE2_codeSpanDoesNotCrossALine() {
        let text = "a `b\nc` #tag"
        XCTAssertEqual(codeSpans(in: text), [])
        XCTAssertEqual(tags(in: text), ["tag"])
    }

    func testE2_adjacentCodeSpans() {
        XCTAssertEqual(codeSpans(in: "`a``b`"), ["`a``b`"], "a run of two in the middle does not close a run of one")
        XCTAssertEqual(codeSpans(in: "`a` `b`"), ["`a`", "`b`"])
    }

    // MARK: E-2 fenced code

    func testE2_backtickAndTildeFences() {
        XCTAssertEqual(fences(in: "```\nx\n```\n"), ["```\nx\n```\n"])
        XCTAssertEqual(fences(in: "~~~\nx\n~~~"), ["~~~\nx\n~~~"])
        XCTAssertEqual(
            fences(in: "````\n```\nstill\n````\n"), ["````\n```\nstill\n````\n"], "closing run must be as long")
        XCTAssertEqual(
            fences(in: "```\n~~~\nstill\n```\n"), ["```\n~~~\nstill\n```\n"], "other character does not close")
        XCTAssertEqual(fences(in: "``\nnot a fence\n``\n"), [])
    }

    func testE2_fenceWithInfoStringIndentAndTrailingSpace() {
        XCTAssertEqual(fences(in: "  ```swift\nx\n   ```  \nafter"), ["  ```swift\nx\n   ```  \n"])
        XCTAssertEqual(fences(in: "    ```\nindented four is not a fence\n"), [])
        XCTAssertEqual(fences(in: "``` a ` b\nnot a fence: backtick in info string\n"), [])
        XCTAssertEqual(
            fences(in: "```\nx\n``` trailing text\nstill inside\n"), ["```\nx\n``` trailing text\nstill inside\n"])
    }

    func testE2_unclosedFenceRunsToTheEnd() {
        let text = "# H\n```\n#a\n[[b]]\n"
        XCTAssertEqual(fences(in: text), ["```\n#a\n[[b]]\n"])
        XCTAssertEqual(headings(in: text).map(\.level), [1])
        XCTAssertEqual(tags(in: text), [])
        XCTAssertEqual(links(in: text).count, 0)
    }

    func testE2_backtickFenceLineWithABacktickInItsInfoStringIsInlineText() {
        // CommonMark: a backtick fence's info string may not contain a backtick, so the first
        // line is ordinary text with a code span and a tag; the last line opens an unclosed fence.
        let text = "```x``` #t\nin\n```\n"
        XCTAssertEqual(codeSpans(in: text), ["```x```"])
        XCTAssertEqual(tags(in: text), ["t"])
        XCTAssertEqual(fences(in: text), ["```\n"])
    }

    // MARK: E-2 the single pass keeps every kind in document order

    func testE2_everyTokenKindInOnePass() {
        let text = """
            # Title #tag1
            Body [[link|label]] and `code` ![[img.png]]

            ```sh
            #not-a-tag
            ```
            #tag2
            """
        let kinds = MarkdownScanner.scan(text).map { token -> String in
            switch token.kind {
            case .heading(let level): "h\(level)"
            case .wikilink(_, _, let isEmbed): isEmbed ? "embed" : "link"
            case .tag: "tag"
            case .inlineCode: "code"
            case .fencedCode: "fence"
            }
        }
        XCTAssertEqual(kinds, ["h1", "tag", "link", "code", "embed", "fence", "tag"])
        // A heading spans its line and contains the tokens on it; every other token is disjoint.
        let inline = MarkdownScanner.scan(text).filter { $0.kind != .heading(level: 1) }
        for (a, b) in zip(inline, inline.dropFirst()) {
            XCTAssertLessThanOrEqual(
                a.range.location + a.range.length, b.range.location, "tokens overlap or are out of order")
        }
    }

    func testE2_emptyAndPlainTextYieldNothing() {
        XCTAssertEqual(MarkdownScanner.scan(""), [])
        XCTAssertEqual(MarkdownScanner.scan("just words\n\nand more\n"), [])
    }

    func testE2_rangesAreUTF16Offsets() {
        let text = "😀 #tag [[é]]"
        let tokens = MarkdownScanner.scan(text)
        XCTAssertEqual(tokens.map(\.range), [NSRange(location: 3, length: 4), NSRange(location: 8, length: 5)])
        XCTAssertEqual(tags(in: text), ["tag"])
        XCTAssertEqual(links(in: text).map(\.target), ["é"])
    }

    // MARK: E-3 paragraph scope

    private func paragraph(_ text: String, _ location: Int, _ length: Int = 0) -> String {
        slice(text, MarkdownScanner.paragraphRange(in: text, editedRange: NSRange(location: location, length: length)))
    }

    func testE3_paragraphIsTheBlankLineDelimitedBlockAroundTheEdit() {
        let text = "one\ntwo\n\nthree\nfour\n\nfive"
        XCTAssertEqual(paragraph(text, 5), "one\ntwo\n")
        XCTAssertEqual(paragraph(text, 0), "one\ntwo\n")
        XCTAssertEqual(paragraph(text, 9), "three\nfour\n")
        XCTAssertEqual(paragraph(text, 17), "three\nfour\n", "inside the last line of a paragraph")
        XCTAssertEqual(paragraph(text, 21), "five")
        XCTAssertEqual(paragraph(text, text.utf16.count), "five", "edit at the very end")
    }

    func testE3_editOnABlankLineIsScopedToThatLine() {
        let text = "one\n\ntwo"
        XCTAssertEqual(paragraph(text, 4), "\n")
        XCTAssertEqual(paragraph("one\n  \ntwo", 4), "  \n", "whitespace-only lines are blank")
    }

    func testE3_editSpanningParagraphsCoversThemAll() {
        let text = "one\n\ntwo\n\nthree"
        XCTAssertEqual(paragraph(text, 2, 7), "one\n\ntwo\n\n", "ends on the blank line: no join forward")
        XCTAssertEqual(paragraph(text, 2, 8), text, "ends at the start of a line: that line is included")
        XCTAssertEqual(paragraph(text, 0, text.utf16.count), text)
    }

    func testE3_insertedNewlineCoversBothHalves() {
        // "ab[[c|d]]" split by a newline typed after the pipe.
        let text = "ab[[c|\nd]]"
        XCTAssertEqual(paragraph(text, 6, 1), text)
    }

    func testE3_editInsideAFencedBlockCoversTheWholeBlock() {
        let text = "intro\n\n```\na\n\nb\n```\n\noutro\n"
        XCTAssertEqual(paragraph(text, 11), "```\na\n\nb\n```\n")
        XCTAssertEqual(paragraph(text, 13), "```\na\n\nb\n```\n", "the blank line inside the fence too")
        XCTAssertEqual(paragraph(text, 0), "intro\n")
        XCTAssertEqual(paragraph(text, 21), "outro\n")
    }

    func testE3_editOnAFenceLikeLineRunsToTheEnd() {
        let text = "intro\n\n```\na\n```\n\noutro\n"
        XCTAssertEqual(paragraph(text, 8), "```\na\n```\n\noutro\n", "editing the opening fence")
        XCTAssertEqual(paragraph(text, 13), "```\na\n```\n\noutro\n", "editing the closing fence")
        XCTAssertEqual(paragraph("x\n\n~~~ info\n\ny", 3), "~~~ info\n\ny", "with an info string")
        XCTAssertEqual(paragraph("x\n\n```x```\n\ny", 3), "```x```\n\ny", "shaped like a fence even when not one")
        let partial = "intro\n\n``\na\n\nouter\n"
        XCTAssertEqual(paragraph(partial, 8), "``\na\n", "two backticks are not yet a fence")
        XCTAssertEqual(paragraph("x\n\n`y` #t\n\nz", 3), "`y` #t\n", "a line opening with inline code is not")
    }

    func testE3_paragraphScanMatchesTheFullScan() {
        let text = """
            # Title #t1
            para [[a]] `x`

            ```
            #no
            ```
            tail #t2 ![[i.png]]

            last `y` #t3
            """
        let full = MarkdownScanner.scan(text)
        var offset = 0
        while offset <= text.utf16.count {
            let range = MarkdownScanner.paragraphRange(in: text, editedRange: NSRange(location: offset, length: 0))
            let scoped = MarkdownScanner.scan(text, in: range)
            let expected = full.filter {
                $0.range.location >= range.location && $0.range.location < range.location + range.length
            }
            XCTAssertEqual(scoped, expected, "scoped scan differs from the full scan at offset \(offset): \(range)")
            offset += 1
        }
    }

    func testE3_editedRangeIsClampedToTheText() {
        let text = "abc"
        XCTAssertEqual(paragraph(text, 10, 5), "abc")
        XCTAssertEqual(paragraph("", 0), "")
    }
}
