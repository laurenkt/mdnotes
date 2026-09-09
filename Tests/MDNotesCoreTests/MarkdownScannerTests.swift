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
            case .emphasis, .link, .autolink, .bareURL, .listItem, .taskBox, .blockquote, .tableRow,
                .tableSeparator, .thematicBreak:
                "other"
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

    func testE3_editOnABlankLineCoversTheParagraphsEitherSide() {
        // A blank line's presence splits or joins its neighbours and decides ED-8 and ED-9 for
        // the line under it, so an edit that leaves a line blank re-scans both sides.
        let text = "one\n\ntwo"
        XCTAssertEqual(paragraph(text, 4), text)
        XCTAssertEqual(paragraph("one\n  \ntwo", 4), "one\n  \ntwo", "whitespace-only lines are blank")
        XCTAssertEqual(paragraph("a\n\n\n---", 2), "a\n\n", "two blank lines: only the neighbour that touches")
        XCTAssertEqual(paragraph("a\n\n\n---", 3), "\n---")
        XCTAssertEqual(paragraph("one\n\n", 4), "one\n\n", "nothing after")
        XCTAssertEqual(paragraph("\ntwo", 0), "\ntwo", "nothing before")
        XCTAssertEqual(paragraph("\n\ntwo", 0), "\n", "another blank line between: nothing touches")
    }

    func testED8_paragraphScopeReachesARuleWhoseBlankLineChanged() {
        // Deleting the text of the line before `---` leaves a blank line: the rule below is
        // now a break (ED-8) and the line above is no longer a heading's text (ED-9).
        let text = "a\n\n---"
        XCTAssertEqual(paragraph(text, 2), text)
        let tokens = MarkdownScanner.scan(
            text, in: MarkdownScanner.paragraphRange(in: text, editedRange: NSRange(location: 2, length: 0)))
        XCTAssertEqual(tokens.map(\.kind), [.thematicBreak])
    }

    func testE3_editSpanningParagraphsCoversThemAll() {
        let text = "one\n\ntwo\n\nthree"
        XCTAssertEqual(paragraph(text, 2, 7), text, "ends on a blank line: the paragraph after it too")
        XCTAssertEqual(paragraph(text, 2, 8), text, "ends at the start of a line: that line is included")
        XCTAssertEqual(paragraph(text, 0, text.utf16.count), text)
        XCTAssertEqual(paragraph("one\ntwo\n\nthree", 0, 3), "one\ntwo\n", "no blank line edited: no join forward")
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

            Setext **bold** _it_
            ===
            - item [link](u) <a:b> https://x.y
              - [ ] nested ~~gone~~
            > quote
            > ---

            | a | b |
            |---|---|
            | 1 | 2 |

            ***
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

    // MARK: ED-1 helpers

    /// A token as `kind` plus the texts of its markers and content, for one-line assertions.
    private struct Shape: Equatable {
        let kind: Kind
        let text: String
        let markers: [String]
        let content: String
    }

    private func shapes(in text: String, where predicate: (Kind) -> Bool = { _ in true }) -> [Shape] {
        MarkdownScanner.scan(text).filter { predicate($0.kind) }.map { token in
            Shape(
                kind: token.kind, text: slice(text, token.range), markers: token.markers.map { slice(text, $0) },
                content: slice(text, token.content))
        }
    }

    private func emphasis(in text: String) -> [(trait: MarkdownScanner.Emphasis, text: String, content: String)] {
        MarkdownScanner.scan(text).compactMap { token in
            guard case .emphasis(let trait) = token.kind else { return nil }
            return (trait, slice(text, token.range), slice(text, token.content))
        }
    }

    private func kinds(in text: String) -> [Kind] {
        MarkdownScanner.scan(text).map(\.kind)
    }

    // MARK: ED-1 emphasis

    func testED1_boldWithAsterisksAndUnderscores() {
        let text = "**b** and __c__"
        let found = shapes(in: text)
        XCTAssertEqual(
            found,
            [
                Shape(kind: .emphasis(.bold), text: "**b**", markers: ["**", "**"], content: "b"),
                Shape(kind: .emphasis(.bold), text: "__c__", markers: ["__", "__"], content: "c"),
            ])
    }

    func testED1_italicWithAsterisksAndUnderscores() {
        let text = "*i* and _j_"
        XCTAssertEqual(
            shapes(in: text),
            [
                Shape(kind: .emphasis(.italic), text: "*i*", markers: ["*", "*"], content: "i"),
                Shape(kind: .emphasis(.italic), text: "_j_", markers: ["_", "_"], content: "j"),
            ])
        XCTAssertEqual(emphasis(in: "*a*b").map(\.content), ["a"], "asterisks work inside a word")
        XCTAssertEqual(emphasis(in: "a*b*c").map(\.content), ["b"])
    }

    func testED1_underscoreEmphasisOnlyAtWordBoundaries() {
        XCTAssertEqual(emphasis(in: "snake_case_name").count, 0)
        XCTAssertEqual(emphasis(in: "a_b_").count, 0)
        XCTAssertEqual(emphasis(in: "_foo_bar").count, 0)
        XCTAssertEqual(emphasis(in: "foo_bar_").count, 0)
        XCTAssertEqual(emphasis(in: "__init__ method").map(\.content), ["init"])
        XCTAssertEqual(emphasis(in: "(_x_)").map(\.content), ["x"], "punctuation around is a boundary")
        XCTAssertEqual(emphasis(in: "_x_, then").map(\.content), ["x"])
    }

    func testED1_strikethrough() {
        let text = "a ~~gone~~ b"
        XCTAssertEqual(
            shapes(in: text),
            [Shape(kind: .emphasis(.strikethrough), text: "~~gone~~", markers: ["~~", "~~"], content: "gone")])
        XCTAssertEqual(emphasis(in: "a ~one~ b").count, 0, "a single tilde is not strikethrough")
        XCTAssertEqual(emphasis(in: "a ~~~x~~~ b").count, 0, "nor a run of three")
        XCTAssertEqual(emphasis(in: "~~a~~b").map(\.content), ["a"])
    }

    func testED1_spacedDelimitersAreNotEmphasis() {
        XCTAssertEqual(emphasis(in: "2 * 3 * 4").count, 0)
        XCTAssertEqual(emphasis(in: "a ** b ** c").count, 0)
        XCTAssertEqual(emphasis(in: "*unclosed").count, 0)
        XCTAssertEqual(emphasis(in: "**a*").map(\.content), ["a"], "one of the two pairs")
        XCTAssertEqual(emphasis(in: "**a*").map(\.text), ["*a*"])
    }

    func testED1_nestedEmphasisYieldsNestedTokensEnclosingFirst() {
        XCTAssertEqual(
            shapes(in: "***a***"),
            [
                Shape(kind: .emphasis(.italic), text: "***a***", markers: ["*", "*"], content: "**a**"),
                Shape(kind: .emphasis(.bold), text: "**a**", markers: ["**", "**"], content: "a"),
            ])
        XCTAssertEqual(
            shapes(in: "**bold *it* bold**"),
            [
                Shape(
                    kind: .emphasis(.bold), text: "**bold *it* bold**", markers: ["**", "**"], content: "bold *it* bold"
                ),
                Shape(kind: .emphasis(.italic), text: "*it*", markers: ["*", "*"], content: "it"),
            ])
        XCTAssertEqual(emphasis(in: "*foo**bar*").map(\.text), ["*foo**bar*"], "the rule of three")
        XCTAssertEqual(emphasis(in: "_a **b** c_").map(\.text), ["_a **b** c_", "**b**"])
    }

    func testED1_backslashEscapesPunctuation() {
        XCTAssertEqual(kinds(in: "\\*not\\* \\[a](b) \\<c:d> \\#t"), [])
        XCTAssertEqual(emphasis(in: "*a\\*").count, 0, "an escaped closer does not close")
    }

    // MARK: ED-1 links

    func testED1_standardLink() {
        let text = "see [text](https://x.com \"T\") now"
        XCTAssertEqual(
            shapes(in: text),
            [
                Shape(
                    kind: .link(url: NSRange(location: 11, length: 13), isImage: false),
                    text: "[text](https://x.com \"T\")", markers: ["[", "](https://x.com \"T\")"], content: "text")
            ])
        XCTAssertEqual(shapes(in: "[a](<u v>)").map(\.content), ["a"])
        if case .link(let url, _) = MarkdownScanner.scan("[a](<u v>)").first?.kind {
            XCTAssertEqual(slice("[a](<u v>)", url), "u v")
        } else {
            XCTFail("expected a link")
        }
        if case .link(let url, _) = MarkdownScanner.scan("[a](b(c))").first?.kind {
            XCTAssertEqual(slice("[a](b(c))", url), "b(c)", "balanced parentheses stay in the URL")
        } else {
            XCTFail("expected a link")
        }
        XCTAssertEqual(shapes(in: "[a](b (c))").map(\.markers), [["[", "](b (c))"]], "a title in parentheses")
        XCTAssertEqual(shapes(in: "[a [b] c](d)").map(\.content), ["a [b] c"], "balanced brackets stay in the text")
        XCTAssertEqual(shapes(in: "[a]()").map(\.text), ["[a]()"], "an empty destination is allowed")
        XCTAssertEqual(kinds(in: "[a](b"), [])
        XCTAssertEqual(kinds(in: "[a] (b)"), [])
        XCTAssertEqual(kinds(in: "[a](b c)"), [])
        XCTAssertEqual(kinds(in: "[a]\n(b)"), [])
        XCTAssertEqual(kinds(in: "[not a link]"), [])
    }

    func testED1_image() {
        let text = "![alt text](i.png)"
        XCTAssertEqual(
            shapes(in: text),
            [
                Shape(
                    kind: .link(url: NSRange(location: 12, length: 5), isImage: true), text: text,
                    markers: ["![", "](i.png)"], content: "alt text")
            ])
        XCTAssertEqual(kinds(in: "wow! [a](b)"), [.link(url: NSRange(location: 9, length: 1), isImage: false)])
    }

    func testED1_linkTextHasItsOwnTokens() {
        let text = "*[**b** #t](u)* [[w]]"
        XCTAssertEqual(
            kinds(in: text),
            [
                .emphasis(.italic),
                .link(url: NSRange(location: 12, length: 1), isImage: false),
                .emphasis(.bold),
                .tag(name: NSRange(location: 9, length: 1)),
                .wikilink(target: NSRange(location: 18, length: 1), label: nil, isEmbed: false),
            ])
        XCTAssertEqual(emphasis(in: "*a [b*](c) d").count, 0, "emphasis never straddles a link's text")
    }

    func testED1_autolink() {
        let text = "at <https://x.com/a?b=c> or <mailto:a@b.c>"
        XCTAssertEqual(
            shapes(in: text),
            [
                Shape(
                    kind: .autolink(url: NSRange(location: 4, length: 19)), text: "<https://x.com/a?b=c>",
                    markers: ["<", ">"], content: "https://x.com/a?b=c"),
                Shape(
                    kind: .autolink(url: NSRange(location: 29, length: 12)), text: "<mailto:a@b.c>",
                    markers: ["<", ">"],
                    content: "mailto:a@b.c"),
            ])
        XCTAssertEqual(kinds(in: "<not a link> <a> <x:> <http://a b>"), [], "a scheme and no spaces")
        XCTAssertEqual(kinds(in: "<https://x.com"), [])
    }

    func testED1_bareURL() {
        let text = "go to https://x.com/a_b. now"
        XCTAssertEqual(
            shapes(in: text),
            [
                Shape(
                    kind: .bareURL(url: NSRange(location: 6, length: 17)), text: "https://x.com/a_b", markers: [],
                    content: "https://x.com/a_b")
            ])
        XCTAssertEqual(shapes(in: "(http://a.b)").map(\.text), ["http://a.b"], "an unbalanced paren is left out")
        XCTAssertEqual(shapes(in: "http://a.b/(c)").map(\.text), ["http://a.b/(c)"], "a balanced one stays")
        XCTAssertEqual(shapes(in: "HTTP://A.B,").map(\.text), ["HTTP://A.B"], "any case, trailing comma out")
        XCTAssertEqual(shapes(in: "*http://a.b*").map(\.text), ["*http://a.b*", "http://a.b"])
        XCTAssertEqual(kinds(in: "xhttp://a.b"), [], "must start a word")
        XCTAssertEqual(kinds(in: "http:// nothing"), [])
        XCTAssertEqual(kinds(in: "ftp://a.b"), [], "http and https only")
        XCTAssertEqual(kinds(in: "<https://a.b>").count, 1, "an autolink is not also a bare URL")
    }

    // MARK: ED-1 lists

    func testED1_bulletListItems() {
        let text = "- a\n* b\n+ c"
        XCTAssertEqual(
            shapes(in: text),
            [
                Shape(kind: .listItem(level: 0, ordered: false), text: "- a", markers: ["- "], content: "a"),
                Shape(kind: .listItem(level: 0, ordered: false), text: "* b", markers: ["* "], content: "b"),
                Shape(kind: .listItem(level: 0, ordered: false), text: "+ c", markers: ["+ "], content: "c"),
            ])
        XCTAssertEqual(kinds(in: "-a"), [], "a space must follow the marker")
        XCTAssertEqual(kinds(in: "-"), [])
        XCTAssertEqual(kinds(in: "- "), [.listItem(level: 0, ordered: false)], "an empty item is one")
        XCTAssertEqual(shapes(in: "-   spaced").map(\.markers), [["-   "]], "the spaces after belong to the marker")
        XCTAssertEqual(
            kinds(in: "- **b** #t"),
            [.listItem(level: 0, ordered: false), .emphasis(.bold), .tag(name: NSRange(location: 9, length: 1))])
    }

    func testED1_orderedListItems() {
        let text = "1. a\n12. b\n1234567890. c\n1) d\n1.e"
        XCTAssertEqual(
            shapes(in: text),
            [
                Shape(kind: .listItem(level: 0, ordered: true), text: "1. a", markers: ["1. "], content: "a"),
                Shape(kind: .listItem(level: 0, ordered: true), text: "12. b", markers: ["12. "], content: "b"),
            ])
    }

    func testED1_taskItems() {
        let text = "- [ ] todo\n- [x] done\n- [X] DONE\n- [y] no\n- [ ]\n- [ ]x"
        let items = shapes(in: text) {
            guard case .listItem = $0 else { return false }
            return true
        }
        XCTAssertEqual(items.map(\.content), ["todo", "done", "DONE", "[y] no", "", "[ ]x"])
        XCTAssertEqual(
            shapes(in: text) {
                guard case .taskBox = $0 else { return false }
                return true
            },
            [
                Shape(kind: .taskBox(isDone: false), text: "[ ]", markers: ["[", "]"], content: " "),
                Shape(kind: .taskBox(isDone: true), text: "[x]", markers: ["[", "]"], content: "x"),
                Shape(kind: .taskBox(isDone: true), text: "[X]", markers: ["[", "]"], content: "X"),
                Shape(kind: .taskBox(isDone: false), text: "[ ]", markers: ["[", "]"], content: " "),
            ])
        XCTAssertEqual(kinds(in: "[ ] not in a list"), [])
    }

    func testED1_listNestingDepthIsTwoSpacesPerLevel() {
        let text = "- a\n  - b\n    - c\n   - d\n      1. e\n\t- f"
        let levels = MarkdownScanner.scan(text).compactMap { token -> Int? in
            guard case .listItem(let level, _) = token.kind else { return nil }
            return level
        }
        XCTAssertEqual(levels, [0, 1, 2, 1, 3])
        XCTAssertEqual(shapes(in: "    - c").map(\.text), ["- c"], "the indent is outside the token")
    }

    // MARK: ED-1 blockquotes

    func testED1_blockquotePrefixes() {
        let text = "> a\n> > b\n>c\n>"
        XCTAssertEqual(
            shapes(in: text),
            [
                Shape(kind: .blockquote(level: 1), text: "> a", markers: [">"], content: "a"),
                Shape(kind: .blockquote(level: 2), text: "> > b", markers: [">", ">"], content: "b"),
                Shape(kind: .blockquote(level: 1), text: ">c", markers: [">"], content: "c"),
                Shape(kind: .blockquote(level: 1), text: ">", markers: [">"], content: ""),
            ])
        XCTAssertEqual(kinds(in: "> **b**"), [.blockquote(level: 1), .emphasis(.bold)])
        XCTAssertEqual(kinds(in: "> # H"), [.blockquote(level: 1), .heading(level: 1)])
        XCTAssertEqual(
            kinds(in: ">  - [ ] x"),
            [.blockquote(level: 1), .listItem(level: 0, ordered: false), .taskBox(isDone: false)])
        XCTAssertEqual(kinds(in: "a > b"), [], "only at the line start")
    }

    // MARK: ED-1 tables

    func testED1_pipeTableRowsAndSeparatorRow() {
        let text = "| a | b |\n|---|:-:|\n| 1 | 2 |\nplain\n\n| x |"
        XCTAssertEqual(
            shapes(in: text),
            [
                Shape(kind: .tableRow, text: "| a | b |", markers: ["|", "|", "|"], content: "| a | b |"),
                Shape(kind: .tableSeparator, text: "|---|:-:|", markers: ["|", "|", "|"], content: "|---|:-:|"),
                Shape(kind: .tableRow, text: "| 1 | 2 |", markers: ["|", "|", "|"], content: "| 1 | 2 |"),
            ])
        XCTAssertEqual(kinds(in: "a | b\n-|-\n1 | 2"), [.tableRow, .tableSeparator, .tableRow], "outer pipes optional")
        XCTAssertEqual(kinds(in: "| **a** |\n|-|"), [.tableRow, .emphasis(.bold), .tableSeparator])
        XCTAssertEqual(shapes(in: "| a \\| b |\n|-|").first?.markers, ["|", "|"], "an escaped pipe is text")
        XCTAssertEqual(kinds(in: "|-|"), [], "a separator needs a header row")
        XCTAssertEqual(kinds(in: "a | b\n\n-|-"), [], "directly above it")
        XCTAssertEqual(kinds(in: "a\n---"), [.heading(level: 2)], "no pipe: a setext underline")
    }

    // MARK: ED-8 thematic breaks

    func testED8_thematicBreakNeedsABlankLineBeforeOrTheDocumentStart() {
        XCTAssertEqual(
            shapes(in: "---"), [Shape(kind: .thematicBreak, text: "---", markers: ["---"], content: "")])
        XCTAssertEqual(kinds(in: "* * *"), [.thematicBreak])
        XCTAssertEqual(kinds(in: "___"), [.thematicBreak])
        XCTAssertEqual(kinds(in: "   -  -  -  "), [.thematicBreak])
        XCTAssertEqual(kinds(in: "-----"), [.thematicBreak])
        XCTAssertEqual(kinds(in: "text\n\n***"), [.thematicBreak])
        XCTAssertEqual(kinds(in: "text\n***"), [], "no blank line before: not a break")
        XCTAssertEqual(kinds(in: "text\n---"), [.heading(level: 2)], "a setext underline instead")
        XCTAssertEqual(kinds(in: "# h\n---"), [.heading(level: 1)], "a heading is not a paragraph line")
        XCTAssertEqual(kinds(in: "---\n---"), [.thematicBreak], "a break is not a blank line")
        XCTAssertEqual(kinds(in: "--"), [], "three or more")
        XCTAssertEqual(kinds(in: "-*-"), [], "one character")
        XCTAssertEqual(kinds(in: "--- a"), [], "nothing else on the line")
        XCTAssertEqual(kinds(in: "    ---"), [], "at most three spaces of indent")
        XCTAssertEqual(
            kinds(in: "> a\n>\n> ***"),
            [.blockquote(level: 1), .blockquote(level: 1), .blockquote(level: 1), .thematicBreak])
    }

    // MARK: ED-9 setext headings

    func testED9_setextHeadingUnderText() {
        let text = "Title\n==="
        XCTAssertEqual(
            shapes(in: text), [Shape(kind: .heading(level: 1), text: text, markers: ["==="], content: "Title")])
        XCTAssertEqual(shapes(in: "Sub\n---").map(\.kind), [.heading(level: 2)])
        XCTAssertEqual(shapes(in: "Sub\n-").map(\.kind), [.heading(level: 2)], "one character is enough")
        XCTAssertEqual(shapes(in: "Two\nlines\n---").map(\.content), ["lines"], "the line directly above")
        XCTAssertEqual(shapes(in: "a \n  === ").map(\.content), ["a"], "trimmed")
        XCTAssertEqual(kinds(in: "a\n\n==="), [], "a blank line between: neither heading nor break")
        XCTAssertEqual(kinds(in: "a\n=-="), [], "one character only")
        XCTAssertEqual(
            kinds(in: "- item\n---"), [.listItem(level: 0, ordered: false)], "a list item is not a paragraph line")
        XCTAssertEqual(kinds(in: "> q\n> ---"), [.blockquote(level: 1), .heading(level: 2), .blockquote(level: 1)])
        XCTAssertEqual(kinds(in: "> q\n---"), [.blockquote(level: 1)], "quote levels must match")
        XCTAssertEqual(
            kinds(in: "Title #t\n==="), [.heading(level: 1), .tag(name: NSRange(location: 7, length: 1))],
            "the heading comes before the tokens on its text line")
        XCTAssertEqual(MarkdownScanner.scan("Title\n===\nbody").first?.range, NSRange(location: 0, length: 9))
    }

    // MARK: ED-1 exclusion in code

    func testED1_constructsInsideCodeSpansAreExcluded() {
        let text = "`**a** [b](c) <d:e> https://f.g ~~h~~ - > |`"
        XCTAssertEqual(kinds(in: text), [.inlineCode])
        XCTAssertEqual(shapes(in: "**`a**`**").map(\.kind), [.emphasis(.bold), .inlineCode], "code binds first")
        XCTAssertEqual(shapes(in: "**`a**`**").map(\.content), ["`a**`", "a**"])
    }

    func testED1_constructsInsideFencedBlocksAreExcluded() {
        let text = "```\n**a** [b](c) <d:e>\n- item\n> q\n\n---\n| a |\n|-|\nTitle\n===\nhttps://f.g\n```\n"
        XCTAssertEqual(kinds(in: text), [.fencedCode])
    }

    // MARK: ED-1 markers and content

    func testED1_everyKindCarriesMarkersAndContentSeparately() {
        XCTAssertEqual(
            shapes(in: "## Title  "),
            [Shape(kind: .heading(level: 2), text: "## Title  ", markers: ["##"], content: "Title")])
        XCTAssertEqual(
            shapes(in: "``a``"), [Shape(kind: .inlineCode, text: "``a``", markers: ["``", "``"], content: "a")])
        XCTAssertEqual(
            shapes(in: "```swift\nx\n```\n"),
            [Shape(kind: .fencedCode, text: "```swift\nx\n```\n", markers: ["```swift", "```"], content: "x\n")])
        XCTAssertEqual(shapes(in: "```\nx").first?.markers, ["```"], "an unclosed fence has no closing marker")
        XCTAssertEqual(shapes(in: "```\nx").first?.content, "x")
        XCTAssertEqual(
            shapes(in: "![[a|b]]").map { ($0.markers, $0.content) }.first.map { "\($0.0) \($0.1)" },
            "[\"![[\", \"]]\"] a|b")
        XCTAssertEqual(shapes(in: "#t").first?.markers, ["#"])
        XCTAssertEqual(shapes(in: "#t").first?.content, "t")
    }

    func testED1_tokensAreInDocumentOrderEnclosingFirst() {
        let text = "> - **a *b* c** [d](e)\n> ---"
        let scanned = MarkdownScanner.scan(text)
        XCTAssertEqual(
            scanned.map(\.kind),
            [
                .blockquote(level: 1), .listItem(level: 0, ordered: false), .emphasis(.bold), .emphasis(.italic),
                .link(url: NSRange(location: 20, length: 1), isImage: false), .blockquote(level: 1),
            ])
        for (a, b) in zip(scanned, scanned.dropFirst()) {
            XCTAssertLessThanOrEqual(a.range.location, b.range.location)
            if a.range.location == b.range.location { XCTAssertGreaterThanOrEqual(a.range.length, b.range.length) }
        }
    }
}
