import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for editor styling (E-2) and its paragraph scope (E-3). Text goes into
/// the real text view's storage, so the storage delegate styles it the way a load or a
/// keystroke does, and edits go through `insertText`, the path a keystroke takes.
@MainActor
final class EditorStylingSmokeTests: XCTestCase {
    private let keys = [EditorFontPreference.sizeDefaultsKey, MainView.listHeightDefaultsKey]
    private var root: URL = FileManager.default.temporaryDirectory

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-styling-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try await super.tearDown()
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        var textView: NSTextView { controller.mainView.textView }
        var storage: NSTextStorage { textView.textStorage ?? NSTextStorage() }
        var styler: EditorStyler { controller.editorController.styler }

        /// Puts `text` in the editor as a load does, and makes it editable so typing works.
        func show(_ text: String) {
            textView.string = text
            textView.isEditable = true
        }

        /// Types `text` at `location`, replacing `length` characters, as a keystroke does.
        func type(_ text: String, at location: Int, replacing length: Int = 0) {
            textView.insertText(text, replacementRange: NSRange(location: location, length: length))
        }

        func attributes(at location: Int) -> [NSAttributedString.Key: Any] {
            storage.attributes(at: location, effectiveRange: nil)
        }

        func style(at location: Int) -> EditorStyler.TokenStyle? {
            (attributes(at: location)[EditorStyler.tokenAttribute] as? String).flatMap(EditorStyler.TokenStyle.init)
        }

        func color(at location: Int) -> NSColor? { attributes(at: location)[.foregroundColor] as? NSColor }
        func font(at location: Int) -> NSFont? { attributes(at: location)[.font] as? NSFont }
        func strikethrough(at location: Int) -> Int? { attributes(at: location)[.strikethroughStyle] as? Int }
        func underline(at location: Int) -> Int? { attributes(at: location)[.underlineStyle] as? Int }
        func toolTip(at location: Int) -> String? { attributes(at: location)[.toolTip] as? String }

        /// The underline style of every character in `range`, nil where there is none (ED-11).
        func underlines(in range: NSRange) -> [Int?] {
            (range.location..<(range.location + range.length)).map { underline(at: $0) }
        }

        /// The tooltip of every character in `range`, nil where there is none (ED-11).
        func toolTips(in range: NSRange) -> [String?] {
            (range.location..<(range.location + range.length)).map { toolTip(at: $0) }
        }

        /// The colour of every character in `range`.
        func colors(in range: NSRange) -> [NSColor?] {
            (range.location..<(range.location + range.length)).map { color(at: $0) }
        }

        /// The token style of every character in `range`, or nil where there is none.
        func styles(in range: NSRange) -> [EditorStyler.TokenStyle?] {
            (range.location..<(range.location + range.length)).map { style(at: $0) }
        }
    }

    private func makeFixture() -> Fixture {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        return Fixture(controller: controller)
    }

    private func range(of needle: String, in text: String, occurrence: Int = 0) -> NSRange {
        var search = NSRange(location: 0, length: (text as NSString).length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = (text as NSString).range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let next = found.location + found.length
            search = NSRange(location: next, length: (text as NSString).length - next)
        }
        return found
    }

    private func isBold(_ font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
    }

    private func isItalic(_ font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
    }

    /// The colour every markdown marker is dimmed to (ED-2).
    private var tertiary: NSColor { EditorStyler.markerColor }

    /// A character inside a wikilink's brackets: the last one before `]]`.
    private func inside(_ link: NSRange) -> Int { link.location + link.length - 3 }

    /// The prose font: the system font at 13 pt (E-8).
    private var base: NSFont { NSFont.systemFont(ofSize: 13) }
    /// The code font: the system monospaced font at the same size (E-8).
    private var mono: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }

    // MARK: - E-2: what is styled and how

    func testE2_headingsAreBoldAndBodyIsNot() throws {
        let fixture = makeFixture()
        let text = "# Title\nbody line\n## Second\n"
        fixture.show(text)

        let heading = try XCTUnwrap(fixture.font(at: 0))
        XCTAssertTrue(isBold(heading), "heading is bold: \(heading)")
        XCTAssertEqual(heading.pointSize, base.pointSize * 1.4, accuracy: 0.001, "level 1 scale (ED-4)")
        XCTAssertEqual(heading.familyName, base.familyName)
        XCTAssertEqual(fixture.style(at: 0), .heading)
        XCTAssertEqual(fixture.style(at: 6), .heading, "the whole heading line is styled")
        XCTAssertEqual(fixture.styler.headingFont(forLevel: 1), heading)

        let body = try XCTUnwrap(fixture.font(at: range(of: "body", in: text).location))
        XCTAssertFalse(isBold(body))
        XCTAssertEqual(body, base)
        XCTAssertNil(fixture.style(at: range(of: "body", in: text).location))
        XCTAssertEqual(fixture.color(at: range(of: "body", in: text).location), fixture.styler.baseColor)

        XCTAssertTrue(isBold(fixture.font(at: range(of: "## Second", in: text).location)))
        XCTAssertEqual(fixture.style(at: range(of: "Second", in: text).location), .heading)
    }

    func testE2_linksTagsAndCodeTakeTheirColours() throws {
        let fixture = makeFixture()
        let text = "see [[Other|label]] and #tag, then `code #no`\n```\nfenced [[no]] #no\n```\nafter\n"
        fixture.show(text)

        let link = range(of: "[[Other|label]]", in: text)
        XCTAssertEqual(
            Set(fixture.styles(in: link).map { $0?.rawValue }), ["missingLink"], "no library, so no note has it (ED-11)"
        )
        XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor)
        XCTAssertEqual(fixture.color(at: link.location), tertiary, "the brackets are markers (ED-2)")
        XCTAssertEqual(fixture.font(at: link.location), base, "links keep the base weight")

        let tag = range(of: "#tag", in: text)
        XCTAssertEqual(Set(fixture.styles(in: tag).map { $0?.rawValue }), ["tag"])
        XCTAssertEqual(fixture.color(at: tag.location), NSColor.systemPurple)
        XCTAssertNil(fixture.style(at: tag.location + tag.length), "the comma after the tag is not")

        let code = range(of: "`code #no`", in: text)
        XCTAssertEqual(Set(fixture.styles(in: code).map { $0?.rawValue }), ["inlineCode"])
        XCTAssertEqual(fixture.color(at: code.location), NSColor.secondaryLabelColor)
        XCTAssertEqual(fixture.font(at: code.location), mono, "inline code is monospaced (E-8)")

        let fence = range(of: "```\nfenced [[no]] #no\n```\n", in: text)
        XCTAssertEqual(Set(fixture.styles(in: fence).map { $0?.rawValue }), ["fencedCode"])
        XCTAssertEqual(fixture.color(at: fence.location + 5), NSColor.secondaryLabelColor)
        XCTAssertEqual(fixture.font(at: fence.location + 5), mono, "and so is fenced code")

        let after = range(of: "after", in: text)
        XCTAssertNil(fixture.style(at: after.location))
        XCTAssertEqual(fixture.color(at: after.location), fixture.styler.baseColor)
        XCTAssertEqual(fixture.font(at: after.location), base)
        XCTAssertNil(fixture.style(at: range(of: "see", in: text).location))
    }

    /// E-8, E-2: the monospaced font goes on inline and fenced code and on nothing else here
    /// (a task box takes it too, ED-6, `TaskItemSmokeTests`); every other character, styled or
    /// not, keeps the system font's family at the base size.
    func testE8_stylerAssignsTheMonoFontToInlineAndFencedCodeOnly() throws {
        let fixture = makeFixture()
        let text = "# Head `in heading`\nprose `inline` [[link]] #tag and ![[embed.png]]\n```\nfenced #no\n```\nafter\n"
        fixture.show(text)
        XCTAssertEqual(fixture.styler.baseFont, base)
        XCTAssertEqual(fixture.styler.codeFont, mono)
        XCTAssertNotEqual(base.familyName, mono.familyName)

        let codeRanges = [
            range(of: "`in heading`", in: text), range(of: "`inline`", in: text),
            range(of: "```\nfenced #no\n```\n", in: text),
        ]
        let length = (text as NSString).length
        let headingLine = range(of: "# Head `in heading`", in: text)
        for location in 0..<length {
            let font = try XCTUnwrap(fixture.font(at: location), "every character has a font")
            let inCode = codeRanges.contains { NSLocationInRange(location, $0) }
            let character = (text as NSString).substring(with: NSRange(location: location, length: 1))
            if inCode {
                XCTAssertEqual(font.familyName, mono.familyName, "\(character) at \(location) is code")
                XCTAssertEqual(fixture.color(at: location), NSColor.secondaryLabelColor)
            } else {
                XCTAssertEqual(font.familyName, base.familyName, "\(character) at \(location) is not code")
            }
            if NSLocationInRange(location, headingLine) {
                XCTAssertEqual(
                    font.pointSize, base.pointSize * 1.4, accuracy: 0.001,
                    "\(character) at \(location) is at the heading's size, code included (ED-4, E-8)")
            } else {
                XCTAssertEqual(font.pointSize, base.pointSize, "\(character) at \(location) is at the base size")
            }
        }
        XCTAssertEqual(fixture.style(at: range(of: "`in heading`", in: text).location), .inlineCode)
        XCTAssertEqual(fixture.style(at: range(of: "fenced", in: text).location), .fencedCode)
        XCTAssertEqual(fixture.style(at: range(of: "[[link]]", in: text).location), .missingLink)
        XCTAssertEqual(fixture.style(at: range(of: "#tag", in: text).location), .tag)
        XCTAssertTrue(isBold(fixture.font(at: 0)), "the heading keeps its weight")

        // The styler's own attributes say the same: only the two code styles, the task box
        // (ED-6) and the table lines (ED-7) carry the font.
        for style in EditorStyler.TokenStyle.allCases {
            let font = fixture.styler.attributes(for: style)[.font] as? NSFont
            switch style {
            case .inlineCode, .fencedCode, .taskBox, .tableRow, .tableSeparator:
                XCTAssertEqual(font, mono, "\(style)")
            case .heading: XCTAssertNil(font, "the heading font depends on the level (ED-4)")
            case .wikilink, .missingLink, .ambiguousLink, .link, .tag, .listItem, .doneItem, .blockquote, .rule:
                XCTAssertNil(font, "\(style) keeps the base font")
            case .bold, .italic, .strikethrough: XCTAssertNil(font, "\(style) adds a trait to the font in place")
            }
        }

        // Typing code, or unfencing it, moves the family with the token.
        let end = length
        fixture.type("`x`", at: end)
        XCTAssertEqual(fixture.font(at: end)?.familyName, mono.familyName)
        fixture.type("", at: end, replacing: 1)
        XCTAssertEqual(fixture.textView.string.hasSuffix("after\nx`"), true)
        XCTAssertEqual(fixture.font(at: end)?.familyName, base.familyName, "no longer code, no longer mono")
    }

    func testE2_linksAndTagsOnAHeadingLineKeepItsWeight() throws {
        let fixture = makeFixture()
        let text = "# Head [[link]] #tag\n"
        fixture.show(text)
        let link = range(of: "[[link]]", in: text)
        XCTAssertTrue(isBold(fixture.font(at: link.location)))
        XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor)
        XCTAssertEqual(fixture.color(at: link.location), tertiary, "the brackets are markers (ED-2)")
        let tag = range(of: "#tag", in: text)
        XCTAssertTrue(isBold(fixture.font(at: tag.location)))
        XCTAssertEqual(fixture.color(at: tag.location), NSColor.systemPurple)
    }

    func testE2_stylingChangesNeitherTheTextNorItsMetrics() {
        let fixture = makeFixture()
        let text =
            "# Title\n\nsee [[Other]] and #tag `code` **bold** *it* ~~gone~~\n\n- item\n> quote\n\n```swift\nlet x = 1\n```\n\nplain end"
        fixture.show(text)
        XCTAssertEqual(fixture.textView.string, text, "the text is exactly what went in")

        // Only the font traits, colour and strikethrough vary, run by run; the size is the
        // base's everywhere but the heading line, which is scaled (ED-4), and the family too,
        // except on code, which is monospaced (E-8).
        let allowed: Set<NSAttributedString.Key> = [
            .font, .foregroundColor, .paragraphStyle, .strikethroughStyle, .underlineStyle, .toolTip,
            EditorStyler.tokenAttribute,
        ]
        let codeStyles = [EditorStyler.TokenStyle.inlineCode.rawValue, EditorStyler.TokenStyle.fencedCode.rawValue]
        let heading = range(of: "# Title", in: text)
        var runs = 0
        fixture.storage.enumerateAttributes(in: NSRange(location: 0, length: fixture.storage.length), options: []) {
            attributes, range, _ in
            runs += 1
            XCTAssertTrue(
                Set(attributes.keys).isSubset(of: allowed), "unexpected attributes \(attributes.keys) in \(range)")
            if let font = attributes[.font] as? NSFont {
                let expectedSize = NSLocationInRange(range.location, heading) ? base.pointSize * 1.4 : base.pointSize
                XCTAssertEqual(font.pointSize, expectedSize, accuracy: 0.001, "size in \(range)")
                let isCode = codeStyles.contains(attributes[EditorStyler.tokenAttribute] as? String ?? "")
                XCTAssertEqual(
                    font.familyName, isCode ? mono.familyName : base.familyName, "family in \(range)")
            } else {
                XCTFail("every run has a font: \(range)")
            }
            XCTAssertNotNil(attributes[.foregroundColor], "every run has a colour: \(range)")
        }
        XCTAssertGreaterThan(runs, 5, "the styled runs really are separate runs")
    }

    func testE2_typedTextIsStyledAsItArrives() {
        let fixture = makeFixture()
        fixture.show("plain\n")
        let end = 6
        fixture.type("#", at: end)
        XCTAssertEqual(fixture.style(at: end), .heading, "a lone # at a line start is an empty heading, not a tag")
        fixture.type("t", at: end + 1)
        XCTAssertEqual(fixture.style(at: end), .tag, "and stops being one as soon as a tag character follows")
        XCTAssertEqual(fixture.style(at: end + 1), .tag)
        fixture.type(" [[x]]", at: end + 2)
        XCTAssertEqual(fixture.style(at: end + 3), .missingLink)
        XCTAssertNil(fixture.style(at: end + 2), "the space between is plain")
        XCTAssertEqual(fixture.textView.string, "plain\n#t [[x]]")
    }

    func testE8_sizeChangeKeepsHeadingsBoldAndCodeMonospacedAtTheNewSize() throws {
        let fixture = makeFixture()
        let text = "# Title\nbody [[link]] `code`\n"
        fixture.show(text)
        XCTAssertTrue(isBold(fixture.font(at: 0)))

        UserDefaults.standard.set(15, forKey: EditorFontPreference.sizeDefaultsKey)

        let heading = try XCTUnwrap(fixture.font(at: 0))
        XCTAssertEqual(heading.familyName, base.familyName)
        XCTAssertEqual(heading.pointSize, 15 * 1.4, accuracy: 0.001, "the heading follows the size, scaled (ED-4)")
        XCTAssertTrue(isBold(heading), "the heading is bold at the new size: \(heading)")
        let body = try XCTUnwrap(fixture.font(at: range(of: "body", in: text).location))
        XCTAssertEqual(body, NSFont.systemFont(ofSize: 15))
        XCTAssertFalse(isBold(body))
        let code = try XCTUnwrap(fixture.font(at: range(of: "`code`", in: text).location))
        XCTAssertEqual(code, NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), "code follows the size")
        XCTAssertEqual(fixture.color(at: inside(range(of: "[[link]]", in: text))), NSColor.linkColor)
        XCTAssertEqual(fixture.styler.baseFont, NSFont.systemFont(ofSize: 15))
        XCTAssertEqual(fixture.styler.codeFont, NSFont.monospacedSystemFont(ofSize: 15, weight: .regular))

        // A defaults write that leaves the font alone (the split position, say) changes nothing.
        UserDefaults.standard.set(240.0, forKey: MainView.listHeightDefaultsKey)
        XCTAssertTrue(isBold(fixture.font(at: 0)))
    }

    // MARK: - E-3: the scope of a re-style

    /// Marks paragraphs with a colour the styler never uses and types in one of them: the
    /// edited paragraph is reset and re-styled, the others keep the mark, so nothing outside
    /// the edited paragraph was touched.
    func testE3_typingRestylesOnlyTheEditedParagraph() {
        let fixture = makeFixture()
        let text = "first #one\n\nsecond line\nstill second\n\nthird #three\n"
        fixture.show(text)
        let mark = NSColor.systemRed
        let whole = NSRange(location: 0, length: fixture.storage.length)
        fixture.storage.addAttribute(.foregroundColor, value: mark, range: whole)
        XCTAssertEqual(fixture.color(at: 0), mark)

        // Turn the second paragraph's first line into a heading.
        let second = range(of: "second line", in: text)
        fixture.type("# ", at: second.location)

        XCTAssertEqual(fixture.textView.string, "first #one\n\n# second line\nstill second\n\nthird #three\n")
        XCTAssertEqual(fixture.style(at: second.location), .heading)
        XCTAssertTrue(isBold(fixture.font(at: second.location)))
        let still = range(of: "still", in: fixture.textView.string)
        XCTAssertEqual(
            fixture.color(at: still.location), fixture.styler.baseColor, "the paragraph's other line was reset")
        XCTAssertNil(fixture.style(at: still.location))

        XCTAssertEqual(fixture.color(at: 0), mark, "the first paragraph was not touched")
        XCTAssertEqual(fixture.color(at: range(of: "#one", in: text).location), mark)
        let third = range(of: "third", in: fixture.textView.string)
        XCTAssertEqual(fixture.color(at: third.location), mark, "the third paragraph was not touched")
        XCTAssertEqual(fixture.color(at: range(of: "#three", in: fixture.textView.string).location), mark)
        XCTAssertEqual(fixture.color(at: second.location - 1), mark, "the blank line before was not touched")
    }

    /// Typing at the selection, as keystrokes do, in the middle of a paragraph: the re-style of
    /// that paragraph leaves the insertion point right after each typed character rather than
    /// at the end of the re-styled range.
    func testE3_restylingLeavesTheInsertionPointAfterTheTypedCharacter() {
        let fixture = makeFixture()
        let text = "first\n\nsecond paragraph with #tag and more words\nand a second line\n\nthird\n"
        fixture.show(text)
        let start = range(of: "with", in: text).location
        fixture.textView.setSelectedRange(NSRange(location: start, length: 0))
        var carets: [Int] = []
        for character in "# [[x]] " {
            fixture.textView.insertText(String(character), replacementRange: fixture.textView.selectedRange())
            carets.append(fixture.textView.selectedRange().location)
        }
        XCTAssertEqual(carets, (1...8).map { start + $0 })
        XCTAssertEqual(
            fixture.textView.string,
            "first\n\nsecond paragraph # [[x]] with #tag and more words\nand a second line\n\nthird\n")
        XCTAssertEqual(fixture.style(at: start + 2), .missingLink)
        XCTAssertEqual(fixture.style(at: range(of: "#tag", in: fixture.textView.string).location), .tag)
    }

    func testE3_deletingRestylesTheParagraphAroundTheDeletion() {
        let fixture = makeFixture()
        let text = "one\n\n# heading here\n\nthree\n"
        fixture.show(text)
        let heading = range(of: "# heading here", in: text)
        XCTAssertEqual(fixture.style(at: heading.location + 3), .heading)
        // Remove the "# " so the line stops being a heading.
        fixture.type("", at: heading.location, replacing: 2)
        XCTAssertEqual(fixture.textView.string, "one\n\nheading here\n\nthree\n")
        XCTAssertNil(fixture.style(at: heading.location))
        XCTAssertFalse(isBold(fixture.font(at: heading.location)))
        XCTAssertNil(fixture.style(at: heading.location + 8))
    }

    func testE3_typingInsideAFencedBlockKeepsTheWholeBlockStyled() {
        let fixture = makeFixture()
        let text = "```\nline one\n\nline two #x\n```\nafter #tag\n"
        fixture.show(text)
        let fence = range(of: "```\nline one\n\nline two #x\n```\n", in: text)
        XCTAssertEqual(Set(fixture.styles(in: fence).map { $0?.rawValue }), ["fencedCode"])

        fixture.type("more ", at: range(of: "line two", in: text).location)
        let newText = fixture.textView.string
        XCTAssertEqual(newText, "```\nline one\n\nmore line two #x\n```\nafter #tag\n")
        let newFence = range(of: "```\nline one\n\nmore line two #x\n```\n", in: newText)
        XCTAssertEqual(Set(fixture.styles(in: newFence).map { $0?.rawValue }), ["fencedCode"])
        XCTAssertEqual(fixture.style(at: range(of: "#tag", in: newText).location), .tag)
    }

    func testE3_openingAFenceRestylesEverythingBelowIt() {
        let fixture = makeFixture()
        let text = "top #a\n\nmiddle [[link]]\n\nbottom #b\n"
        fixture.show(text)
        XCTAssertEqual(fixture.style(at: range(of: "#b", in: text).location), .tag)

        // A fence line typed into the first paragraph opens a block that runs to the end.
        fixture.type("```\n", at: 0)
        let newText = fixture.textView.string
        XCTAssertEqual(newText, "```\ntop #a\n\nmiddle [[link]]\n\nbottom #b\n")
        let whole = NSRange(location: 0, length: (newText as NSString).length)
        XCTAssertEqual(Set(fixture.styles(in: whole).map { $0?.rawValue }), ["fencedCode"])
    }

    func testE3_removingAFenceLineRestylesTheBlockItOpened() {
        let fixture = makeFixture()
        let text = "```\ncode #x\n\n[[link]] here\n```\n\nafter #tag\n"
        fixture.show(text)
        XCTAssertEqual(fixture.style(at: range(of: "#x", in: text).location), .fencedCode)
        XCTAssertEqual(fixture.style(at: range(of: "[[link]]", in: text).location), .fencedCode)

        // Delete the opening fence line: what it fenced is ordinary text again, down to and
        // including the old closing fence, which now opens an unclosed block to the end.
        fixture.type("", at: 0, replacing: 4)
        let newText = fixture.textView.string
        XCTAssertEqual(newText, "code #x\n\n[[link]] here\n```\n\nafter #tag\n")
        XCTAssertNil(fixture.style(at: 0))
        XCTAssertEqual(fixture.color(at: 0), fixture.styler.baseColor)
        XCTAssertEqual(fixture.style(at: range(of: "#x", in: newText).location), .tag)
        XCTAssertEqual(fixture.style(at: range(of: "[[link]]", in: newText).location), .missingLink)
        let tail = range(of: "```\n\nafter #tag\n", in: newText)
        XCTAssertEqual(Set(fixture.styles(in: tail).map { $0?.rawValue }), ["fencedCode"])
    }

    func testE3_breakingAFenceLineRestylesTheBlockItOpened() {
        let fixture = makeFixture()
        let text = "```\ncode #x\n```\n\nafter #tag\n"
        fixture.show(text)
        // A backtick fence's info string may not hold a backtick, so this line is no fence.
        fixture.type("a`", at: 3)
        let newText = fixture.textView.string
        XCTAssertEqual(newText, "```a`\ncode #x\n```\n\nafter #tag\n")
        XCTAssertNil(fixture.style(at: 0))
        XCTAssertEqual(fixture.style(at: range(of: "#x", in: newText).location), .tag)
        let tail = range(of: "```\n\nafter #tag\n", in: newText)
        XCTAssertEqual(Set(fixture.styles(in: tail).map { $0?.rawValue }), ["fencedCode"])
    }

    func testE3_undoRestoresTheStyling() throws {
        let fixture = makeFixture()
        let text = "plain #tag\n"
        fixture.show(text)
        fixture.type("# ", at: 0)
        XCTAssertEqual(fixture.style(at: 0), .heading)
        let manager = try XCTUnwrap(fixture.textView.undoManager)
        manager.undo()
        XCTAssertEqual(fixture.textView.string, text)
        XCTAssertNil(fixture.style(at: 0))
        XCTAssertFalse(isBold(fixture.font(at: 0)))
        XCTAssertEqual(fixture.style(at: range(of: "#tag", in: text).location), .tag)
    }

    // MARK: - Through the library

    func testE2_aLoadedNoteIsStyled() async throws {
        let body = "# Loaded\n\nwith [[Other]] and #tag\n"
        let url = root.appendingPathComponent("Loaded.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)

        let fixture = makeFixture()
        let library = LibraryController(root: root)
        fixture.controller.attach(library)
        library.start()
        let deadline = Date().addingTimeInterval(20)
        while library.phase != .ready {
            if Date() > deadline { return XCTFail("library did not become ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let id = NoteID(relativePath: "Loaded.md")
        let row = try XCTUnwrap(fixture.controller.listController.results.firstIndex { $0.id == id })
        fixture.controller.mainView.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        while fixture.controller.editorController.body == nil {
            if Date() > deadline { return XCTFail("editor did not load the note") }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(fixture.textView.string, body)
        XCTAssertTrue(isBold(fixture.font(at: 0)))
        XCTAssertEqual(fixture.style(at: 0), .heading)
        XCTAssertEqual(
            fixture.style(at: range(of: "[[Other]]", in: body).location), .missingLink,
            "the library has no note titled Other (ED-11)")
        XCTAssertEqual(fixture.style(at: range(of: "#tag", in: body).location), .tag)
        XCTAssertTrue(fixture.textView.isEditable)
        library.stop()
    }
    // MARK: - K-2: ambiguous links

    /// Main-actor box for an index a test swaps under the styler's `linkIndex` closure.
    @MainActor
    private final class IndexBox {
        var index: LinkIndex
        init(_ index: LinkIndex) { self.index = index }
    }

    /// A link index over `foo.md` alone: the title is unique.
    private func oneFooIndex() -> LinkIndex {
        LinkIndex.empty.applying(upserts: [(NoteID(relativePath: "foo.md"), Date(), [])], removing: [])
    }

    /// A link index over `foo.md`, `daily/foo.md` and `Bar.md`: the bare title `foo` is shared.
    private func twoFooIndex() -> LinkIndex {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return LinkIndex.empty.applying(
            upserts: [
                (NoteID(relativePath: "foo.md"), base, []),
                (NoteID(relativePath: "daily/foo.md"), base.addingTimeInterval(60), []),
                (NoteID(relativePath: "Bar.md"), base, []),
            ], removing: [])
    }

    /// Two notes titled `foo`: a bare `[[foo]]`, however cased or labelled, is styled as
    /// ambiguous in the warning tint; a path to one of them, a unique title and an embed keep
    /// the link style, and an unresolved title is a missing link (ED-11).
    func testK2_ambiguousLinksAreStyledAsAmbiguous() throws {
        let fixture = makeFixture()
        let index = twoFooIndex()
        fixture.styler.linkIndex = { index }
        let text = "see [[foo]] [[Foo|label]] [[ foo ]] [[daily/foo]] [[Bar]] [[none]] ![[foo]]\n# Head [[foo]]\n"
        fixture.show(text)

        for needle in ["[[foo]]", "[[Foo|label]]", "[[ foo ]]"] {
            let link = range(of: needle, in: text)
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["ambiguousLink"], needle)
            XCTAssertEqual(fixture.color(at: inside(link)), EditorStyler.ambiguousLinkColor, needle)
            XCTAssertEqual(fixture.color(at: link.location), tertiary, "\(needle) brackets are dimmed (ED-2)")
            XCTAssertEqual(fixture.font(at: link.location), base, "\(needle) keeps the base weight")
        }
        for needle in ["[[daily/foo]]", "[[Bar]]", "![[foo]]"] {
            let link = range(of: needle, in: text)
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["wikilink"], needle)
            XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor, needle)
            XCTAssertEqual(fixture.color(at: link.location), tertiary, "\(needle) brackets are dimmed (ED-2)")
        }
        let none = range(of: "[[none]]", in: text)
        XCTAssertEqual(Set(fixture.styles(in: none).map { $0?.rawValue }), ["missingLink"])
        XCTAssertEqual(fixture.color(at: inside(none)), NSColor.linkColor)
        XCTAssertEqual(fixture.color(at: none.location), tertiary)
        XCTAssertNil(fixture.style(at: range(of: "see", in: text).location))

        let heading = range(of: "[[foo]]", in: text, occurrence: 2)
        XCTAssertEqual(fixture.style(at: heading.location), .ambiguousLink)
        XCTAssertEqual(fixture.color(at: inside(heading)), EditorStyler.ambiguousLinkColor)
        XCTAssertTrue(isBold(fixture.font(at: heading.location)), "on a heading line it keeps the heading's weight")
        XCTAssertEqual(fixture.textView.string, text)
    }

    /// The text does not change but the index does: `restyleLinks()` moves the links whose
    /// resolution changed to their new style and touches nothing else.
    func testK2_linksAreRestyledWhenTheIndexChangesTheirResolution() {
        let fixture = makeFixture()
        let box = IndexBox(oneFooIndex())
        fixture.styler.linkIndex = { box.index }
        let text = "one [[foo]] and [[none]] #tag\n\ntwo [[foo]]\n"
        fixture.show(text)
        let first = range(of: "[[foo]]", in: text)
        let second = range(of: "[[foo]]", in: text, occurrence: 1)
        let bar = range(of: "[[none]]", in: text)
        XCTAssertEqual(fixture.style(at: first.location), .wikilink, "one note titled foo is unique")
        XCTAssertEqual(fixture.style(at: second.location), .wikilink)
        XCTAssertEqual(fixture.style(at: bar.location), .missingLink, "no note is titled none, in either index")

        // Mark everything with a colour the styler never uses, so what it touched is visible.
        let mark = NSColor.systemRed
        let whole = NSRange(location: 0, length: fixture.storage.length)
        fixture.storage.addAttribute(.foregroundColor, value: mark, range: whole)

        box.index = twoFooIndex()
        fixture.styler.restyleLinks()
        XCTAssertEqual(Set(fixture.styles(in: first).map { $0?.rawValue }), ["ambiguousLink"])
        XCTAssertEqual(fixture.color(at: inside(first)), EditorStyler.ambiguousLinkColor)
        XCTAssertEqual(fixture.color(at: first.location), tertiary, "its brackets stay dimmed (ED-2)")
        XCTAssertEqual(Set(fixture.styles(in: second).map { $0?.rawValue }), ["ambiguousLink"])
        XCTAssertEqual(fixture.color(at: inside(second)), EditorStyler.ambiguousLinkColor)
        XCTAssertEqual(fixture.color(at: bar.location), mark, "a link whose resolution did not change is untouched")
        XCTAssertEqual(fixture.color(at: inside(bar)), mark)
        XCTAssertEqual(fixture.style(at: bar.location), .missingLink)
        XCTAssertEqual(fixture.color(at: 0), mark, "plain text is untouched")
        XCTAssertEqual(fixture.color(at: range(of: "#tag", in: text).location), mark, "a tag is untouched")
        XCTAssertEqual(fixture.style(at: range(of: "#tag", in: text).location), .tag)
        XCTAssertEqual(fixture.textView.string, text)

        // Back to one foo: the links are plain wikilinks again.
        box.index = oneFooIndex()
        fixture.styler.restyleLinks()
        XCTAssertEqual(fixture.style(at: first.location), .wikilink)
        XCTAssertEqual(fixture.color(at: inside(first)), NSColor.linkColor)
        XCTAssertEqual(fixture.color(at: first.location), tertiary)
        XCTAssertEqual(fixture.style(at: second.location), .wikilink)
        XCTAssertEqual(fixture.color(at: bar.location), mark)

        // A link typed now is resolved against the current index as it arrives.
        box.index = twoFooIndex()
        let end = (text as NSString).length
        fixture.type("[[foo]]", at: end)
        XCTAssertEqual(fixture.style(at: end), .ambiguousLink)
        XCTAssertEqual(fixture.style(at: first.location), .wikilink, "another paragraph is not re-styled by typing")
    }

    /// Through the library: `Linker.md` links to the one note titled `foo`, so the link is
    /// unique. Creating a second `foo` publishes a snapshot that makes the title ambiguous, and
    /// the link in the editor changes style without an edit.
    func testK2_aSecondNoteTitledFooRestylesTheOpenNotesLink() async throws {
        let body = "see [[foo]] and [[Bar]]\n"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "first foo".write(to: root.appendingPathComponent("foo.md"), atomically: true, encoding: .utf8)
        try body.write(to: root.appendingPathComponent("Linker.md"), atomically: true, encoding: .utf8)

        let fixture = makeFixture()
        let library = LibraryController(root: root)
        fixture.controller.attach(library)
        library.start()
        let deadline = Date().addingTimeInterval(20)
        while library.phase != .ready {
            if Date() > deadline { return XCTFail("library did not become ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let linker = NoteID(relativePath: "Linker.md")
        XCTAssertTrue(fixture.controller.listController.select(linker))
        while fixture.controller.editorController.body == nil {
            if Date() > deadline { return XCTFail("editor did not load the note") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.textView.string, body)
        let foo = range(of: "[[foo]]", in: body)
        let bar = range(of: "[[Bar]]", in: body)
        XCTAssertEqual(Set(fixture.styles(in: foo).map { $0?.rawValue }), ["wikilink"], "one foo is unique")
        XCTAssertEqual(fixture.color(at: inside(foo)), NSColor.linkColor)

        let second = NoteID(relativePath: "daily/foo.md")
        var created = false
        library.create(second) { result in
            if case .failure(let error) = result { XCTFail("create failed: \(error)") }
            created = true
        }
        while !created {
            if Date() > deadline { return XCTFail("second foo was not created") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(library.snapshot.entry(for: second))
        XCTAssertTrue(library.snapshot.links.resolve("foo").isAmbiguous)
        XCTAssertEqual(Set(fixture.styles(in: foo).map { $0?.rawValue }), ["ambiguousLink"])
        XCTAssertEqual(fixture.color(at: inside(foo)), EditorStyler.ambiguousLinkColor)
        XCTAssertEqual(fixture.style(at: bar.location), .missingLink, "no note is titled Bar (ED-11)")
        XCTAssertEqual(fixture.textView.string, body, "the text is untouched")
        XCTAssertFalse(fixture.controller.editorController.hasUnsavedEdits, "re-styling is not an edit")

        // Typing another link to the shared title styles it as ambiguous as it arrives.
        let end = (body as NSString).length
        fixture.type("[[foo]]", at: end)
        XCTAssertEqual(fixture.style(at: end), .ambiguousLink)
        library.stop()
    }

    // MARK: - ED-11: link state

    /// Every wikilink state against one index: a unique title, a path and an embed are plain
    /// links in link colour with no underline or tooltip; a title no note has keeps link
    /// colour, has a dotted underline under the target alone and the tooltip over the whole
    /// link, brackets included; a shared bare title stays ambiguous (K-2), with neither. On a
    /// heading line a missing link keeps the heading's weight.
    func testED11_wikilinkStateFollowsWhatTheTargetResolvesTo() throws {
        let fixture = makeFixture()
        let index = twoFooIndex()
        fixture.styler.linkIndex = { index }
        let text = "see [[Bar]] [[daily/foo]] ![[none.png]] [[none]] [[none|label]] [[foo]]\n# Head [[none]]\n"
        fixture.show(text)
        let dotted = EditorStyler.missingLinkUnderline.rawValue
        XCTAssertTrue(EditorStyler.missingLinkUnderline.contains(.patternDot), "the underline is dotted")
        XCTAssertEqual(EditorStyler.missingLinkToolTip, "Cmd-click to create")

        for needle in ["[[Bar]]", "[[daily/foo]]", "![[none.png]]"] {
            let link = range(of: needle, in: text)
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["wikilink"], needle)
            XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor, needle)
            XCTAssertEqual(Set(fixture.underlines(in: link)), [nil], "\(needle) has no underline")
            XCTAssertEqual(Set(fixture.toolTips(in: link)), [nil], "\(needle) has no tooltip")
        }
        for needle in ["[[none]]", "[[none|label]]"] {
            let link = range(of: needle, in: text)
            let target = NSRange(location: link.location + 2, length: link.length - 4)
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["missingLink"], needle)
            XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor, "\(needle) keeps link colour")
            XCTAssertEqual(fixture.color(at: link.location), tertiary, "\(needle) brackets are dimmed (ED-2)")
            XCTAssertEqual(Set(fixture.underlines(in: target)), [dotted], "\(needle) target is underlined")
            XCTAssertNil(fixture.underline(at: link.location), "\(needle) opening brackets are not")
            XCTAssertNil(fixture.underline(at: link.location + 1))
            XCTAssertNil(fixture.underline(at: link.location + link.length - 2), "\(needle) closing brackets are not")
            XCTAssertNil(fixture.underline(at: link.location + link.length - 1))
            XCTAssertEqual(
                Set(fixture.toolTips(in: link)), ["Cmd-click to create"], "\(needle) tooltip covers the brackets too")
            XCTAssertEqual(fixture.font(at: link.location), base)
        }
        let foo = range(of: "[[foo]]", in: text)
        XCTAssertEqual(Set(fixture.styles(in: foo).map { $0?.rawValue }), ["ambiguousLink"])
        XCTAssertEqual(fixture.color(at: inside(foo)), EditorStyler.ambiguousLinkColor)
        XCTAssertEqual(Set(fixture.underlines(in: foo)), [nil], "an ambiguous link is unchanged (K-2)")
        XCTAssertEqual(Set(fixture.toolTips(in: foo)), [nil])
        XCTAssertNil(fixture.underline(at: 0))
        XCTAssertNil(fixture.toolTip(at: 0))

        let heading = range(of: "[[none]]", in: text, occurrence: 1)
        XCTAssertEqual(Set(fixture.styles(in: heading).map { $0?.rawValue }), ["missingLink"])
        XCTAssertTrue(isBold(fixture.font(at: inside(heading))), "on a heading line it keeps the heading's weight")
        XCTAssertEqual(fixture.underline(at: inside(heading)), dotted)
        XCTAssertEqual(fixture.toolTip(at: heading.location), EditorStyler.missingLinkToolTip)
        XCTAssertEqual(fixture.textView.string, text)
    }

    /// A standard link, an autolink and a bare URL are links: their text (or URL) in link
    /// colour carrying `.link`, the brackets and URL dimmed as markers (ED-2), no underline or
    /// tooltip anywhere, and none of it depending on the index; an image is not a link. On a
    /// heading line a link keeps the heading's weight. A URL typed is a link as it arrives.
    func testED11_standardLinksAutolinksAndBareURLsAreStyledAsLinks() throws {
        let fixture = makeFixture()
        let text =
            "a [text](https://x.y \"title\") and <https://a.b> then https://c.d/e?f=1 but ![alt](i.png)\n# Head [h](u)\n"
        fixture.show(text)
        func colors(of needle: String) -> Set<NSColor?> { Set(fixture.colors(in: range(of: needle, in: text))) }

        let link = range(of: "[text](https://x.y \"title\")", in: text)
        XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["link"])
        XCTAssertEqual(colors(of: "text"), [NSColor.linkColor])
        XCTAssertEqual(colors(of: "[t"), [tertiary, NSColor.linkColor])
        XCTAssertEqual(colors(of: "](https://x.y \"title\")"), [tertiary], "the URL and its title are markers (ED-2)")

        let auto = range(of: "<https://a.b>", in: text)
        XCTAssertEqual(Set(fixture.styles(in: auto).map { $0?.rawValue }), ["link"])
        XCTAssertEqual(colors(of: "https://a.b"), [NSColor.linkColor])
        XCTAssertEqual(fixture.color(at: auto.location), tertiary)
        XCTAssertEqual(fixture.color(at: auto.location + auto.length - 1), tertiary)

        let bare = range(of: "https://c.d/e?f=1", in: text)
        XCTAssertEqual(Set(fixture.styles(in: bare).map { $0?.rawValue }), ["link"])
        XCTAssertEqual(Set(fixture.colors(in: bare)), [NSColor.linkColor], "a bare URL is a link end to end")

        let image = range(of: "![alt](i.png)", in: text)
        XCTAssertEqual(Set(fixture.styles(in: image).map { $0?.rawValue }), [nil], "an image is not a link")
        XCTAssertEqual(colors(of: "alt"), [fixture.styler.baseColor])
        XCTAssertEqual(colors(of: "!["), [tertiary])
        XCTAssertEqual(colors(of: "](i.png)"), [tertiary])

        let length = (text as NSString).length
        for location in 0..<length {
            XCTAssertNil(fixture.underline(at: location), "no underline at \(location)")
            XCTAssertNil(fixture.toolTip(at: location), "no tooltip at \(location)")
            XCTAssertEqual(fixture.font(at: location)?.familyName, base.familyName)
        }
        let heading = range(of: "[h](u)", in: text)
        XCTAssertEqual(fixture.style(at: heading.location + 1), .link)
        XCTAssertTrue(isBold(fixture.font(at: heading.location + 1)), "on a heading line a link keeps its weight")
        XCTAssertEqual(fixture.color(at: heading.location + 1), NSColor.linkColor)
        XCTAssertEqual(fixture.color(at: heading.location), tertiary)

        // The index has no say: a re-check of the links against another index touches none.
        let mark = NSColor.systemRed
        fixture.storage.addAttribute(.foregroundColor, value: mark, range: NSRange(location: 0, length: length))
        let index = twoFooIndex()
        fixture.styler.linkIndex = { index }
        fixture.styler.restyleLinks()
        XCTAssertEqual(colors(of: "text"), [mark])
        XCTAssertEqual(colors(of: "https://a.b"), [mark])
        XCTAssertEqual(Set(fixture.colors(in: bare)), [mark])

        // Typed, a URL is a link as it arrives and stops being one when its scheme breaks.
        fixture.type("https://t.u", at: length)
        XCTAssertEqual(Set(fixture.styles(in: NSRange(location: length, length: 11)).map { $0?.rawValue }), ["link"])
        XCTAssertEqual(fixture.color(at: length), NSColor.linkColor)
        fixture.type("", at: length + 5, replacing: 1)
        XCTAssertTrue(fixture.textView.string.hasSuffix("https//t.u"))
        XCTAssertNil(fixture.style(at: length))
        XCTAssertEqual(fixture.color(at: length), fixture.styler.baseColor)
    }

    /// The text does not change but the index does: a missing link's target appears and the
    /// underline and tooltip go, leaving link colour; the target goes and they come back; a
    /// second note with the title makes it ambiguous, with neither. Only the links whose state
    /// changed are touched, and a re-check that changes nothing touches nothing.
    func testED11_aLinkIsRestyledWhenItsTargetAppearsOrDisappears() {
        let fixture = makeFixture()
        let box = IndexBox(.empty)
        fixture.styler.linkIndex = { box.index }
        let text = "one [[foo]] and [[Bar]] <https://a.b>\n\ntwo [[foo]]\n"
        fixture.show(text)
        let first = range(of: "[[foo]]", in: text)
        let second = range(of: "[[foo]]", in: text, occurrence: 1)
        let bar = range(of: "[[Bar]]", in: text)
        let auto = range(of: "<https://a.b>", in: text)
        let dotted = EditorStyler.missingLinkUnderline.rawValue
        let tip = EditorStyler.missingLinkToolTip
        for link in [first, second, bar] {
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["missingLink"], "an empty index")
            XCTAssertEqual(fixture.underline(at: inside(link)), dotted)
            XCTAssertEqual(fixture.toolTip(at: link.location), tip)
        }

        // Mark everything with a colour the styler never uses, so what it touched is visible.
        let mark = NSColor.systemRed
        let whole = NSRange(location: 0, length: fixture.storage.length)
        fixture.storage.addAttribute(.foregroundColor, value: mark, range: whole)

        // foo.md appears: both links to it are plain links; Bar stays missing and untouched.
        box.index = oneFooIndex()
        fixture.styler.restyleLinks()
        for link in [first, second] {
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["wikilink"])
            XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor)
            XCTAssertEqual(fixture.color(at: link.location), tertiary, "its brackets stay dimmed (ED-2)")
            XCTAssertEqual(Set(fixture.underlines(in: link)), [nil], "the underline is gone")
            XCTAssertEqual(Set(fixture.toolTips(in: link)), [nil], "and so is the tooltip")
        }
        XCTAssertEqual(fixture.style(at: bar.location), .missingLink)
        XCTAssertEqual(fixture.color(at: inside(bar)), mark, "a link whose state did not change is untouched")
        XCTAssertEqual(fixture.underline(at: inside(bar)), dotted)
        XCTAssertEqual(fixture.toolTip(at: bar.location), tip)
        XCTAssertEqual(fixture.color(at: inside(auto)), mark, "a URL never depends on the index")
        XCTAssertEqual(fixture.color(at: 0), mark, "plain text is untouched")
        XCTAssertEqual(fixture.textView.string, text)

        // Nothing changed: nothing is touched.
        fixture.storage.addAttribute(.foregroundColor, value: mark, range: whole)
        fixture.styler.restyleLinks()
        XCTAssertEqual(Set(fixture.colors(in: whole)), [mark])

        // foo.md goes: the underline is back under the target and the tooltip over the link.
        box.index = .empty
        fixture.styler.restyleLinks()
        for link in [first, second] {
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["missingLink"])
            XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor)
            XCTAssertEqual(fixture.color(at: link.location), tertiary)
            XCTAssertEqual(fixture.underline(at: inside(link)), dotted)
            XCTAssertNil(fixture.underline(at: link.location))
            XCTAssertNil(fixture.underline(at: link.location + link.length - 1))
            XCTAssertEqual(Set(fixture.toolTips(in: link)), [tip])
        }
        XCTAssertEqual(fixture.color(at: inside(bar)), mark)
        XCTAssertEqual(fixture.color(at: 0), mark)

        // Two notes titled foo, and Bar.md: foo is ambiguous with neither underline nor
        // tooltip (K-2), Bar a plain link.
        box.index = twoFooIndex()
        fixture.styler.restyleLinks()
        for link in [first, second] {
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["ambiguousLink"])
            XCTAssertEqual(fixture.color(at: inside(link)), EditorStyler.ambiguousLinkColor)
            XCTAssertEqual(Set(fixture.underlines(in: link)), [nil])
            XCTAssertEqual(Set(fixture.toolTips(in: link)), [nil])
        }
        XCTAssertEqual(Set(fixture.styles(in: bar).map { $0?.rawValue }), ["wikilink"])
        XCTAssertEqual(fixture.color(at: inside(bar)), NSColor.linkColor)
        XCTAssertEqual(Set(fixture.underlines(in: bar)), [nil])
        XCTAssertEqual(Set(fixture.toolTips(in: bar)), [nil])
        XCTAssertEqual(fixture.textView.string, text)

        // A link typed now is resolved against the current index as it arrives.
        let end = (text as NSString).length
        fixture.type("[[none]]", at: end)
        XCTAssertEqual(Set(fixture.styles(in: NSRange(location: end, length: 8)).map { $0?.rawValue }), ["missingLink"])
        XCTAssertEqual(fixture.underline(at: end + 2), dotted)
        XCTAssertEqual(fixture.toolTip(at: end), tip)
        XCTAssertEqual(
            fixture.style(at: first.location), .ambiguousLink, "another paragraph is not re-styled by typing")
    }

    /// Through the library: `Linker.md` links to `foo`, which no note has, so the link is
    /// missing. Creating `foo.md` publishes a snapshot that resolves it and the link loses its
    /// underline and tooltip without an edit; the file going again brings them back.
    func testED11_theTargetNoteAppearingAndGoingRestylesTheOpenNotesLink() async throws {
        let body = "see [[foo]] and <https://a.b>\n"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body.write(to: root.appendingPathComponent("Linker.md"), atomically: true, encoding: .utf8)

        let fixture = makeFixture()
        let library = LibraryController(root: root)
        fixture.controller.attach(library)
        library.start()
        let deadline = Date().addingTimeInterval(20)
        while library.phase != .ready {
            if Date() > deadline { return XCTFail("library did not become ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let linker = NoteID(relativePath: "Linker.md")
        XCTAssertTrue(fixture.controller.listController.select(linker))
        while fixture.controller.editorController.body == nil {
            if Date() > deadline { return XCTFail("editor did not load the note") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.textView.string, body)
        let foo = range(of: "[[foo]]", in: body)
        let auto = range(of: "<https://a.b>", in: body)
        let dotted = EditorStyler.missingLinkUnderline.rawValue
        let tip = EditorStyler.missingLinkToolTip
        XCTAssertEqual(Set(fixture.styles(in: foo).map { $0?.rawValue }), ["missingLink"], "no note titled foo")
        XCTAssertEqual(fixture.color(at: inside(foo)), NSColor.linkColor)
        XCTAssertEqual(fixture.underline(at: inside(foo)), dotted)
        XCTAssertEqual(Set(fixture.toolTips(in: foo)), [tip])
        XCTAssertEqual(fixture.style(at: inside(auto)), .link)
        XCTAssertEqual(fixture.color(at: inside(auto)), NSColor.linkColor)

        let target = NoteID(relativePath: "foo.md")
        var created = false
        library.create(target) { result in
            if case .failure(let error) = result { XCTFail("create failed: \(error)") }
            created = true
        }
        while !created {
            if Date() > deadline { return XCTFail("foo was not created") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(library.snapshot.links.resolve("foo"), .unique(target))
        XCTAssertEqual(Set(fixture.styles(in: foo).map { $0?.rawValue }), ["wikilink"], "the target appeared")
        XCTAssertEqual(fixture.color(at: inside(foo)), NSColor.linkColor)
        XCTAssertEqual(fixture.color(at: foo.location), tertiary)
        XCTAssertEqual(Set(fixture.underlines(in: foo)), [nil])
        XCTAssertEqual(Set(fixture.toolTips(in: foo)), [nil])
        XCTAssertEqual(fixture.style(at: inside(auto)), .link)
        XCTAssertEqual(fixture.textView.string, body, "the text is untouched")
        XCTAssertFalse(fixture.controller.editorController.hasUnsavedEdits, "re-styling is not an edit")

        // The file goes, as the watcher would report it: the link is missing again.
        try FileManager.default.removeItem(at: root.appendingPathComponent("foo.md"))
        library.apply(LibraryChanges(removed: [target]))
        while library.snapshot.entry(for: target) != nil {
            if Date() > deadline { return XCTFail("foo was not dropped") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(library.snapshot.links.resolve("foo"), .unresolved)
        XCTAssertEqual(Set(fixture.styles(in: foo).map { $0?.rawValue }), ["missingLink"], "the target went")
        XCTAssertEqual(fixture.color(at: inside(foo)), NSColor.linkColor)
        XCTAssertEqual(fixture.underline(at: inside(foo)), dotted)
        XCTAssertNil(fixture.underline(at: foo.location))
        XCTAssertEqual(Set(fixture.toolTips(in: foo)), [tip])
        XCTAssertEqual(fixture.textView.string, body)
        XCTAssertFalse(fixture.controller.editorController.hasUnsavedEdits)
        library.stop()
    }

    // MARK: - ED-2, ED-3: markers dimmed, emphasis traits on content

    /// Each emphasis form: the content carries the trait, the token attribute and the base
    /// colour; the markers carry the marker colour, the surrounding font and no trait. The
    /// traits follow a size change (E-8).
    func testED3_emphasisContentGetsItsTraitAndItsMarkersAreDimmed() throws {
        let fixture = makeFixture()
        let text = "**bold** *it* _under_ ~~gone~~ __b2__ plain\n"
        fixture.show(text)

        let cases: [(needle: String, marker: Int, style: EditorStyler.TokenStyle)] = [
            ("**bold**", 2, .bold), ("*it*", 1, .italic), ("_under_", 1, .italic), ("~~gone~~", 2, .strikethrough),
            ("__b2__", 2, .bold),
        ]
        for (needle, marker, style) in cases {
            let token = range(of: needle, in: text)
            let content = NSRange(location: token.location + marker, length: token.length - 2 * marker)
            let markers = [
                NSRange(location: token.location, length: marker),
                NSRange(location: content.location + content.length, length: marker),
            ]
            for location in content.location..<(content.location + content.length) {
                let font = try XCTUnwrap(fixture.font(at: location), needle)
                XCTAssertEqual(fixture.style(at: location), style, needle)
                XCTAssertEqual(
                    fixture.color(at: location), fixture.styler.baseColor, "\(needle) content keeps its colour")
                XCTAssertEqual(font.pointSize, base.pointSize, "\(needle) keeps the size (E-2)")
                XCTAssertEqual(font.familyName, base.familyName, "\(needle) keeps the family")
                XCTAssertEqual(isBold(font), style == .bold, "\(needle) bold")
                XCTAssertEqual(isItalic(font), style == .italic, "\(needle) italic")
                XCTAssertEqual(
                    fixture.strikethrough(at: location),
                    style == .strikethrough ? NSUnderlineStyle.single.rawValue : nil,
                    "\(needle) strikethrough")
            }
            for run in markers {
                for location in run.location..<(run.location + run.length) {
                    XCTAssertEqual(fixture.color(at: location), tertiary, "\(needle) marker at \(location) is dimmed")
                    XCTAssertEqual(fixture.font(at: location), base, "\(needle) marker keeps the surrounding font")
                    XCTAssertNil(fixture.strikethrough(at: location), "\(needle) marker is not struck")
                    XCTAssertNil(fixture.style(at: location), "\(needle) marker carries no emphasis style")
                }
            }
        }
        let plain = range(of: "plain", in: text)
        XCTAssertEqual(fixture.font(at: plain.location), base)
        XCTAssertEqual(fixture.color(at: plain.location), fixture.styler.baseColor)
        XCTAssertNil(fixture.strikethrough(at: plain.location))
        XCTAssertNil(fixture.style(at: plain.location))
        XCTAssertEqual(fixture.textView.string, text)

        UserDefaults.standard.set(15, forKey: EditorFontPreference.sizeDefaultsKey)
        let bold = try XCTUnwrap(fixture.font(at: 2))
        XCTAssertEqual(bold.pointSize, 15)
        XCTAssertTrue(isBold(bold), "bold at the new size")
        XCTAssertEqual(fixture.font(at: 0), NSFont.systemFont(ofSize: 15), "the marker at the new size")
        XCTAssertEqual(fixture.color(at: 0), tertiary)
        let italic = try XCTUnwrap(fixture.font(at: range(of: "it", in: text).location))
        XCTAssertEqual(italic.pointSize, 15)
        XCTAssertTrue(isItalic(italic))
    }

    /// Nested emphasis composes: the inner token's trait is added to the outer's, and the
    /// inner markers, being in the outer content, carry the outer trait and the marker colour.
    func testED3_nestedEmphasisComposesTraits() {
        let fixture = makeFixture()
        let text = "***a*** and **bold *it* bold** and _x **y** z_\n"
        fixture.show(text)

        let a = range(of: "a", in: text).location
        XCTAssertTrue(isBold(fixture.font(at: a)) && isItalic(fixture.font(at: a)), "bold inside italic is both")
        XCTAssertEqual(fixture.color(at: 0), tertiary, "the outer marker")
        XCTAssertEqual(fixture.color(at: 6), tertiary)
        XCTAssertFalse(isBold(fixture.font(at: 0)) || isItalic(fixture.font(at: 0)), "the outer marker has no trait")
        for inner in [1, 2, 4, 5] {
            XCTAssertEqual(fixture.color(at: inner), tertiary, "the inner marker at \(inner) is dimmed")
            XCTAssertTrue(isItalic(fixture.font(at: inner)), "and is in the outer content, so italic")
            XCTAssertFalse(isBold(fixture.font(at: inner)), "but not bold")
        }

        let bold = range(of: "bold", in: text)
        XCTAssertTrue(isBold(fixture.font(at: bold.location)))
        XCTAssertFalse(isItalic(fixture.font(at: bold.location)))
        let it = range(of: "it", in: text)
        XCTAssertTrue(isBold(fixture.font(at: it.location)) && isItalic(fixture.font(at: it.location)))
        XCTAssertEqual(fixture.style(at: it.location), .italic, "the inner token's attribute wins")
        XCTAssertEqual(fixture.color(at: it.location - 1), tertiary, "the inner * is dimmed")
        XCTAssertTrue(isBold(fixture.font(at: it.location - 1)), "and bold, like its surroundings")

        let x = range(of: "x", in: text).location
        XCTAssertTrue(isItalic(fixture.font(at: x)) && !isBold(fixture.font(at: x)))
        let y = range(of: "y", in: text).location
        XCTAssertTrue(isItalic(fixture.font(at: y)) && isBold(fixture.font(at: y)))
        XCTAssertEqual(fixture.style(at: y), .bold)
    }

    /// Code takes the code font and colour back from any emphasis around it, drops the
    /// strikethrough, and delimiters inside code are neither markers nor emphasis.
    func testED3_nothingInsideCodeIsStyled() throws {
        let fixture = makeFixture()
        let text = "**a `code` b** ~~s `c` t~~ `**not** *no* ~~x~~`\n```\n**no** _no_ ~~no~~\n```\n"
        fixture.show(text)

        XCTAssertTrue(isBold(fixture.font(at: range(of: "a", in: text).location)))
        let code = range(of: "`code`", in: text)
        for location in code.location..<(code.location + code.length) {
            XCTAssertEqual(fixture.font(at: location), mono, "code inside bold is plain mono at \(location)")
            XCTAssertEqual(fixture.color(at: location), NSColor.secondaryLabelColor)
            XCTAssertEqual(fixture.style(at: location), .inlineCode)
        }
        XCTAssertTrue(isBold(fixture.font(at: range(of: "b", in: text).location)), "bold resumes after the code")

        XCTAssertEqual(fixture.strikethrough(at: range(of: "s", in: text).location), NSUnderlineStyle.single.rawValue)
        let c = range(of: "`c`", in: text)
        for location in c.location..<(c.location + c.length) {
            XCTAssertNil(fixture.strikethrough(at: location), "code inside strikethrough is not struck at \(location)")
        }
        XCTAssertEqual(fixture.strikethrough(at: range(of: "t", in: text).location), NSUnderlineStyle.single.rawValue)

        let span = range(of: "`**not** *no* ~~x~~`", in: text)
        let fence = range(of: "```\n**no** _no_ ~~no~~\n```\n", in: text)
        for (run, style) in [(span, EditorStyler.TokenStyle.inlineCode), (fence, .fencedCode)] {
            for location in run.location..<(run.location + run.length) {
                let font = try XCTUnwrap(fixture.font(at: location))
                XCTAssertEqual(font.familyName, mono.familyName, "\(style) at \(location)")
                XCTAssertFalse(isBold(font) || isItalic(font), "\(style) at \(location) has no trait")
                XCTAssertEqual(fixture.color(at: location), NSColor.secondaryLabelColor, "\(style) at \(location)")
                XCTAssertNil(fixture.strikethrough(at: location), "\(style) at \(location)")
                XCTAssertEqual(fixture.style(at: location), style)
            }
        }
    }

    /// Every markdown marker the scanner yields is in the marker colour and its content is
    /// not: heading hashes and setext underlines, list markers, blockquote prefixes, link
    /// brackets and URLs, autolink brackets, table pipes, wikilink brackets and rules. A tag's
    /// `#` keeps the tag colour, code delimiters the code colour, and a task box its own.
    func testED2_markersOfEveryConstructAreDimmedAndTheirContentIsNot() {
        let fixture = makeFixture()
        let text =
            "# Head\nSetext\n===\n- item\n1. num\n- [ ] task\n> quote\n[t](u) ![a](u) <http://x.y> http://z.w\n"
            + "| a | b |\n|---|---|\n| c | d |\n[[Link]] #tag `code`\n\n---\n"
        fixture.show(text)
        let base = fixture.styler.baseColor

        func colors(of needle: String, occurrence: Int = 0) -> Set<NSColor?> {
            Set(fixture.colors(in: range(of: needle, in: text, occurrence: occurrence)))
        }

        XCTAssertEqual(fixture.color(at: 0), tertiary, "the heading hash")
        XCTAssertTrue(isBold(fixture.font(at: 0)), "at the heading's weight")
        XCTAssertEqual(fixture.style(at: 0), .heading, "and carrying the heading's attribute")
        XCTAssertEqual(colors(of: "Head"), [base])
        XCTAssertEqual(colors(of: "==="), [tertiary], "the setext underline")
        XCTAssertEqual(colors(of: "Setext"), [base])
        XCTAssertTrue(isBold(fixture.font(at: range(of: "Setext", in: text).location)))

        XCTAssertEqual(colors(of: "- item"), [tertiary, base])
        XCTAssertEqual(colors(of: "- "), [tertiary], "the bullet and its space")
        XCTAssertEqual(colors(of: "item"), [base])
        XCTAssertEqual(colors(of: "1. "), [tertiary])
        XCTAssertEqual(colors(of: "num"), [base])
        XCTAssertEqual(colors(of: "- ", occurrence: 1), [tertiary])
        XCTAssertEqual(colors(of: "[ ]"), [base], "a task box is ED-6's")
        XCTAssertEqual(colors(of: "task"), [base])
        XCTAssertEqual(colors(of: ">"), [tertiary])
        XCTAssertEqual(colors(of: "quote"), [base])

        XCTAssertEqual(colors(of: "[t"), [tertiary, NSColor.linkColor], "a standard link's text is a link (ED-11)")
        XCTAssertEqual(
            colors(of: "t](u)"), [NSColor.linkColor, tertiary], "the closing bracket and URL are markers")
        XCTAssertEqual(colors(of: "!["), [tertiary])
        XCTAssertEqual(colors(of: "a](u)"), [base, tertiary], "an image's alt text is not a link")
        XCTAssertEqual(colors(of: "<"), [tertiary])
        XCTAssertEqual(colors(of: "http://x.y"), [NSColor.linkColor], "an autolink's URL is a link (ED-11)")
        XCTAssertEqual(colors(of: ">", occurrence: 1), [tertiary])
        XCTAssertEqual(colors(of: "http://z.w"), [NSColor.linkColor], "a bare URL has no markers and is a link")

        XCTAssertEqual(colors(of: "| a | b |"), [tertiary, base])
        XCTAssertEqual(colors(of: "|", occurrence: 0), [tertiary])
        XCTAssertEqual(colors(of: " a "), [base])
        XCTAssertEqual(colors(of: "|---|---|"), [tertiary], "the separator row, pipes and all (ED-7)")
        XCTAssertEqual(colors(of: " d "), [base])

        let link = range(of: "[[Link]]", in: text)
        XCTAssertEqual(colors(of: "[["), [tertiary])
        XCTAssertEqual(colors(of: "]]"), [tertiary])
        XCTAssertEqual(colors(of: "Link"), [NSColor.linkColor])
        XCTAssertEqual(
            Set(fixture.styles(in: link).map { $0?.rawValue }), ["missingLink"], "no note has the title (ED-11)")
        XCTAssertEqual(colors(of: "#tag"), [NSColor.systemPurple], "a tag's hash keeps the tag colour (T-4)")
        XCTAssertEqual(colors(of: "`code`"), [NSColor.secondaryLabelColor], "code delimiters keep the code colour")
        XCTAssertEqual(colors(of: "---\n"), [tertiary, base], "the rule")
        XCTAssertEqual(colors(of: "---", occurrence: 2), [tertiary])
        XCTAssertEqual(fixture.textView.string, text)
    }

    /// On a heading line the markers keep the heading's weight, emphasis adds to it, and a
    /// link re-style for K-2 leaves the brackets dimmed.
    func testED2_markersKeepTheSurroundingWeightAndALinkRestyleKeepsThemDimmed() {
        let fixture = makeFixture()
        let box = IndexBox(oneFooIndex())
        fixture.styler.linkIndex = { box.index }
        let text = "# Head **b** [[foo]]\n"
        fixture.show(text)

        let b = range(of: "**b**", in: text)
        XCTAssertEqual(fixture.color(at: b.location), tertiary)
        XCTAssertEqual(
            fixture.font(at: b.location), fixture.styler.headingFont(forLevel: 1),
            "the marker is at the heading's weight and size")
        XCTAssertTrue(isBold(fixture.font(at: b.location + 2)))
        XCTAssertEqual(fixture.style(at: b.location + 2), .bold)
        XCTAssertEqual(fixture.color(at: b.location + 2), fixture.styler.baseColor)

        let link = range(of: "[[foo]]", in: text)
        XCTAssertEqual(fixture.color(at: link.location), tertiary)
        XCTAssertTrue(isBold(fixture.font(at: link.location)))
        XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor)
        XCTAssertTrue(isBold(fixture.font(at: inside(link))))

        box.index = twoFooIndex()
        fixture.styler.restyleLinks()
        XCTAssertEqual(fixture.color(at: inside(link)), EditorStyler.ambiguousLinkColor)
        XCTAssertEqual(fixture.color(at: link.location), tertiary, "the brackets stay dimmed")
        XCTAssertEqual(fixture.color(at: link.location + link.length - 1), tertiary)
        XCTAssertEqual(fixture.style(at: link.location), .ambiguousLink)
        box.index = oneFooIndex()
        fixture.styler.restyleLinks()
        XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor)
        XCTAssertEqual(fixture.color(at: link.location), tertiary)
    }

    /// Emphasis typed a character at a time is styled as it arrives, and losing a delimiter
    /// takes the trait and the dimming away with the paragraph's re-style (E-3).
    func testED3_typedEmphasisIsStyledAsItArrivesAndUnstyledWhenAMarkerGoes() {
        let fixture = makeFixture()
        fixture.show("plain\n")
        let end = 6
        fixture.type("**x**", at: end)
        XCTAssertTrue(isBold(fixture.font(at: end + 2)))
        XCTAssertEqual(fixture.style(at: end + 2), .bold)
        XCTAssertEqual(fixture.color(at: end), tertiary)
        XCTAssertEqual(fixture.color(at: end + 4), tertiary)

        fixture.type("", at: end + 4, replacing: 1)
        XCTAssertEqual(fixture.textView.string, "plain\n**x*")
        XCTAssertFalse(isBold(fixture.font(at: end + 2)), "one pair left: italic, not bold")
        XCTAssertTrue(isItalic(fixture.font(at: end + 2)))
        XCTAssertEqual(fixture.color(at: end), fixture.styler.baseColor, "the unmatched * is plain")
        XCTAssertEqual(fixture.color(at: end + 1), tertiary)
        XCTAssertEqual(fixture.color(at: end + 3), tertiary)

        fixture.type("", at: end + 3, replacing: 1)
        XCTAssertEqual(fixture.textView.string, "plain\n**x")
        XCTAssertEqual(fixture.font(at: end + 2), base, "no emphasis left")
        XCTAssertNil(fixture.style(at: end + 2))
        XCTAssertEqual(fixture.color(at: end), fixture.styler.baseColor)
        XCTAssertEqual(fixture.color(at: end + 1), fixture.styler.baseColor)
    }

    // MARK: - ED-4: heading scale

    /// The scale each heading level is set at (ED-4), by level.
    private let headingScales: [Int: CGFloat] = [1: 1.4, 2: 1.25, 3: 1.1, 4: 1.0, 5: 1.0, 6: 1.0]

    func testED4_headingFontSizePerLevel() throws {
        let fixture = makeFixture()
        let text = "# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six\nbody\n"
        fixture.show(text)
        XCTAssertEqual(EditorStyler.headingScales, [1.4, 1.25, 1.1, 1.0])

        for (level, word) in [(1, "One"), (2, "Two"), (3, "Three"), (4, "Four"), (5, "Five"), (6, "Six")] {
            let scale = try XCTUnwrap(headingScales[level])
            XCTAssertEqual(EditorStyler.headingScale(forLevel: level), scale, "level \(level)")
            let line = range(of: String(repeating: "#", count: level) + " " + word, in: text)
            let content = range(of: word, in: text)
            let font = try XCTUnwrap(fixture.font(at: content.location), "level \(level)")
            XCTAssertEqual(font.pointSize, 13 * scale, accuracy: 0.001, "level \(level) content size")
            XCTAssertTrue(isBold(font), "level \(level) is bold: \(font)")
            XCTAssertEqual(font.familyName, base.familyName, "level \(level) keeps the family (E-8)")
            XCTAssertEqual(font, fixture.styler.headingFont(forLevel: level))
            XCTAssertEqual(fixture.style(at: content.location), .heading)
            XCTAssertEqual(fixture.color(at: content.location), fixture.styler.baseColor)

            let hashes = try XCTUnwrap(fixture.font(at: line.location), "level \(level)")
            XCTAssertEqual(hashes, font, "level \(level): the `#` run is at the heading's size and weight (ED-2)")
            for offset in 0..<level {
                XCTAssertEqual(fixture.color(at: line.location + offset), tertiary, "level \(level) `#` dimmed")
            }
        }
        let body = try XCTUnwrap(fixture.font(at: range(of: "body", in: text).location))
        XCTAssertEqual(body, base)
        XCTAssertEqual(fixture.styler.headingFont(forLevel: 4), fixture.styler.headingFont(forLevel: 6))
        XCTAssertEqual(fixture.styler.headingFont(forLevel: 4).pointSize, base.pointSize)
    }

    func testED4_setextHeadingsScaleWithTheUnderlineDimmedAtTheHeadingSize() throws {
        let fixture = makeFixture()
        let text = "First\n===\n\nSecond one\n---\n\nbody\n"
        fixture.show(text)

        let first = try XCTUnwrap(fixture.font(at: 0))
        XCTAssertEqual(first.pointSize, 13 * 1.4, accuracy: 0.001)
        XCTAssertTrue(isBold(first))
        XCTAssertEqual(fixture.style(at: 0), .heading)
        let equals = range(of: "===", in: text)
        XCTAssertEqual(fixture.colors(in: equals), [tertiary, tertiary, tertiary], "the underline is dimmed (ED-9)")
        XCTAssertEqual(fixture.font(at: equals.location), first, "the underline is at the heading's size")
        XCTAssertEqual(fixture.style(at: equals.location), .heading)

        let second = range(of: "Second", in: text)
        let secondFont = try XCTUnwrap(fixture.font(at: second.location))
        XCTAssertEqual(secondFont.pointSize, 13 * 1.25, accuracy: 0.001)
        XCTAssertTrue(isBold(secondFont))
        let dashes = range(of: "---", in: text)
        XCTAssertEqual(fixture.colors(in: dashes), [tertiary, tertiary, tertiary])
        XCTAssertEqual(fixture.font(at: dashes.location), secondFont)

        XCTAssertEqual(fixture.font(at: range(of: "body", in: text).location), base)
        XCTAssertEqual(fixture.color(at: range(of: "body", in: text).location), fixture.styler.baseColor)
    }

    func testED4_emphasisLinksAndCodeInAHeadingKeepItsSize() throws {
        let fixture = makeFixture()
        let text = "## Head **bold** *it* [[link]] #tag `code`\nbody `code`\n"
        fixture.show(text)
        let size = 13 * 1.25

        let bold = range(of: "bold", in: text)
        let boldFont = try XCTUnwrap(fixture.font(at: bold.location))
        XCTAssertTrue(isBold(boldFont))
        XCTAssertEqual(boldFont.pointSize, size, accuracy: 0.001)
        let italic = range(of: "it", in: text)
        let italicFont = try XCTUnwrap(fixture.font(at: italic.location))
        XCTAssertTrue(isItalic(italicFont))
        XCTAssertTrue(isBold(italicFont), "the heading's weight stays under the slant")
        XCTAssertEqual(italicFont.pointSize, size, accuracy: 0.001)
        let link = range(of: "[[link]]", in: text)
        XCTAssertEqual(fixture.font(at: inside(link))?.pointSize ?? 0, size, accuracy: 0.001)
        XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor)
        let tag = range(of: "#tag", in: text)
        XCTAssertEqual(fixture.font(at: tag.location)?.pointSize ?? 0, size, accuracy: 0.001)
        XCTAssertEqual(fixture.color(at: tag.location), NSColor.systemPurple)

        let code = range(of: "`code`", in: text)
        let codeFont = try XCTUnwrap(fixture.font(at: code.location + 1))
        XCTAssertEqual(codeFont.familyName, mono.familyName, "code in a heading is monospaced (E-8)")
        XCTAssertEqual(codeFont.pointSize, size, accuracy: 0.001, "at the heading's size")
        XCTAssertFalse(isBold(codeFont), "and not bold: nothing inside code is styled (ED-3)")
        XCTAssertEqual(fixture.color(at: code.location + 1), NSColor.secondaryLabelColor)
        let bodyCode = range(of: "`code`", in: text, occurrence: 1)
        XCTAssertEqual(fixture.font(at: bodyCode.location + 1), mono, "code in prose stays at the base size")
    }

    func testED4_headingsFollowCmdPlusAndCmdMinus() throws {
        let fixture = makeFixture()
        let text = "# One\n## Two\n### Three\n#### Four\nbody\n"
        fixture.show(text)
        XCTAssertEqual(fixture.font(at: range(of: "One", in: text).location)?.pointSize ?? 0, 13 * 1.4, accuracy: 0.001)

        fixture.controller.makeTextBigger(nil)
        XCTAssertEqual(EditorFontPreference.size(), 14)
        XCTAssertEqual(fixture.styler.baseFont.pointSize, 14)
        for (level, word) in [(1, "One"), (2, "Two"), (3, "Three"), (4, "Four")] {
            let scale = try XCTUnwrap(headingScales[level])
            let font = try XCTUnwrap(fixture.font(at: range(of: word, in: text).location))
            XCTAssertEqual(font.pointSize, 14 * scale, accuracy: 0.001, "level \(level) after Bigger")
            XCTAssertTrue(isBold(font))
            XCTAssertEqual(font, fixture.styler.headingFont(forLevel: level))
        }
        XCTAssertEqual(fixture.font(at: range(of: "body", in: text).location), NSFont.systemFont(ofSize: 14))

        fixture.controller.makeTextSmaller(nil)
        fixture.controller.makeTextSmaller(nil)
        XCTAssertEqual(fixture.styler.baseFont.pointSize, 12)
        XCTAssertEqual(fixture.font(at: range(of: "One", in: text).location)?.pointSize ?? 0, 12 * 1.4, accuracy: 0.001)
        XCTAssertEqual(
            fixture.font(at: range(of: "Two", in: text).location)?.pointSize ?? 0, 12 * 1.25, accuracy: 0.001)
        XCTAssertEqual(fixture.font(at: range(of: "Four", in: text).location)?.pointSize ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(fixture.font(at: range(of: "body", in: text).location), NSFont.systemFont(ofSize: 12))

        fixture.controller.makeTextActualSize(nil)
        XCTAssertEqual(fixture.font(at: range(of: "One", in: text).location)?.pointSize ?? 0, 13 * 1.4, accuracy: 0.001)
    }

    /// Records the glyph ranges the layout manager lays out line by line, so a test can tell
    /// which paragraphs a re-style made it lay out again (E-3).
    @MainActor
    private final class LayoutRecorder: NSObject, NSLayoutManagerDelegate {
        var glyphRanges: [NSRange] = []

        nonisolated func layoutManager(
            _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
        ) -> Bool {
            MainActor.assumeIsolated { glyphRanges.append(glyphRange) }
            return false
        }
    }

    /// The lines (as text) whose layout `recorder` saw the layout manager set, outside
    /// `paragraph` (a character range), in the current text.
    private func linesLaidOut(
        by recorder: LayoutRecorder, in layoutManager: NSLayoutManager, outside paragraph: NSRange
    ) -> Set<String> {
        let text = layoutManager.textStorage?.string as NSString? ?? ""
        var lines: Set<String> = []
        for glyphRange in recorder.glyphRanges {
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard characters.length > 0, !NSLocationInRange(characters.location, paragraph) else { continue }
            lines.insert(text.substring(with: text.lineRange(for: NSRange(location: characters.location, length: 0))))
        }
        return lines
    }

    /// A heading edit changes the size of its paragraph's fonts and nothing outside it (E-3),
    /// so the layout manager lays that paragraph out again and nothing before it, and what it
    /// lays out after it is no more than any keystroke in that paragraph makes it lay out (the
    /// re-style adds nothing to that; with the editor's non-contiguous layout, ED-8, the lines
    /// below keep their layout and move). The paragraphs after it end up moved down by the
    /// heading's growth.
    func testE3_aHeadingEditRelaysOutOnlyItsParagraph() throws {
        let fixture = makeFixture()
        let text = "first paragraph\nsecond line of it\n\n## Head\nunder the head\n\nthird paragraph\nlast line\n"
        fixture.show(text)
        let layoutManager = try XCTUnwrap(fixture.textView.layoutManager)
        let container = try XCTUnwrap(fixture.textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let head = range(of: "## Head", in: text)
        let third = range(of: "third", in: text)
        let thirdBefore = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: third.location), effectiveRange: nil)

        // A plain keystroke in the paragraph's body line, for comparison: no size changes.
        let plain = LayoutRecorder()
        layoutManager.delegate = plain
        defer { layoutManager.delegate = nil }
        let under = range(of: "under", in: text)
        fixture.type("x", at: under.location)
        layoutManager.ensureLayout(for: container)
        let paragraphAfterPlain = MarkdownScanner.paragraphRange(
            in: Array(fixture.textView.string.utf16), editedRange: NSRange(location: under.location, length: 0))
        let plainLines = linesLaidOut(by: plain, in: layoutManager, outside: paragraphAfterPlain)
        XCTAssertFalse(plainLines.contains("first paragraph\n"), "a keystroke never lays out the paragraph before")
        fixture.type("", at: under.location, replacing: 1)
        layoutManager.ensureLayout(for: container)
        XCTAssertEqual(fixture.textView.string, text)

        // Promote the heading to level 1: its font grows from 1.25 to 1.4 times the base size.
        let recorder = LayoutRecorder()
        layoutManager.delegate = recorder
        fixture.type("", at: head.location, replacing: 1)
        let after = fixture.textView.string
        XCTAssertEqual(
            after, "first paragraph\nsecond line of it\n\n# Head\nunder the head\n\nthird paragraph\nlast line\n")
        XCTAssertEqual(fixture.font(at: head.location)?.pointSize ?? 0, 13 * 1.4, accuracy: 0.001)
        let paragraph = MarkdownScanner.paragraphRange(
            in: Array(after.utf16), editedRange: NSRange(location: head.location, length: 0))
        layoutManager.ensureLayout(for: container)

        let laidOut = recorder.glyphRanges.map {
            layoutManager.characterRange(forGlyphRange: $0, actualGlyphRange: nil)
        }
        XCTAssertTrue(laidOut.contains { NSLocationInRange(head.location, $0) }, "the heading line was laid out again")
        for characters in laidOut {
            XCTAssertGreaterThanOrEqual(
                characters.location, paragraph.location, "laid out \(characters) before the heading's paragraph")
        }
        let extra = linesLaidOut(by: recorder, in: layoutManager, outside: paragraph).subtracting(plainLines)
        XCTAssertTrue(
            extra.isEmpty, "the size change made the layout manager lay out \(extra), which a plain keystroke does not")

        // The paragraphs after it moved down by the heading's growth.
        let thirdAfter = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: third.location - 1), effectiveRange: nil)
        XCTAssertGreaterThan(thirdAfter.minY, thirdBefore.minY)
        XCTAssertEqual(thirdAfter.height, thirdBefore.height, accuracy: 0.001)
    }

    // MARK: - ED-5: list items hang under their text

    /// The width `text` takes in `font`, measured the way the styler measures it.
    private func width(of text: String, in font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    /// The head indent of the paragraph style at `location`, zero when there is none.
    private func headIndent(_ fixture: Fixture, at location: Int) -> CGFloat {
        (fixture.attributes(at: location)[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0
    }

    /// The x position, in the text container, of the glyph for the character at `location`.
    private func glyphX(at location: Int, in layoutManager: NSLayoutManager) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return fragment.minX + layoutManager.location(forGlyphAt: glyph).x
    }

    /// The x position of the first glyph on the line fragment after the one holding the
    /// character at `location`: where the wrapped line starts.
    private func wrappedLineX(after location: Int, in layoutManager: NSLayoutManager) throws -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        var fragmentGlyphs = NSRange()
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
        let next = NSMaxRange(fragmentGlyphs)
        var nextGlyphs = NSRange()
        let nextFragment = layoutManager.lineFragmentRect(forGlyphAt: next, effectiveRange: &nextGlyphs)
        XCTAssertGreaterThan(nextFragment.minY, fragment.minY, "the line wrapped")
        let character = layoutManager.characterIndexForGlyph(at: next)
        XCTAssertNotEqual(
            (layoutManager.textStorage?.string as NSString?)?.substring(
                with: NSRange(location: character - 1, length: 1)),
            "\n", "the next fragment is a wrapped line, not the next paragraph")
        return nextFragment.minX + layoutManager.location(forGlyphAt: next).x
    }

    func testED5_headIndentPerLevelForBulletAndOrderedItems() throws {
        let fixture = makeFixture()
        let text = "- one\n  - two\n    - three\n1. first\n  2. second\n10. tenth\n- [ ] task\nplain\n"
        fixture.show(text)
        let styler = fixture.styler

        XCTAssertEqual(EditorStyler.nestingIndentText, "  ", "one nesting level is two spaces (ED-1)")
        XCTAssertEqual(styler.nestingIndent, width(of: "  ", in: base), accuracy: 0.001)
        XCTAssertGreaterThan(styler.nestingIndent, 0)
        let bullet = width(of: "- ", in: base)
        XCTAssertEqual(styler.markerWidth("- "), bullet, accuracy: 0.001)
        XCTAssertEqual(styler.listHeadIndent(level: 0, marker: "- "), bullet, accuracy: 0.001)
        XCTAssertEqual(
            styler.listHeadIndent(level: 2, marker: "- "), bullet + 2 * styler.nestingIndent, accuracy: 0.001)

        let expected: [(line: String, indent: CGFloat)] = [
            ("- one", bullet),
            ("  - two", bullet + styler.nestingIndent),
            ("    - three", bullet + 2 * styler.nestingIndent),
            ("1. first", width(of: "1. ", in: base)),
            ("  2. second", width(of: "2. ", in: base) + styler.nestingIndent),
            ("10. tenth", width(of: "10. ", in: base)),
            ("- [ ] task", bullet),
        ]
        for (line, indent) in expected {
            let lineRange = range(of: line, in: text)
            XCTAssertGreaterThan(indent, 0, line)
            // The style covers the whole paragraph: leading spaces, marker, text and line break.
            for offset in 0...lineRange.length {
                let style = try XCTUnwrap(
                    fixture.attributes(at: lineRange.location + offset)[.paragraphStyle] as? NSParagraphStyle,
                    "\(line) at \(offset)")
                XCTAssertEqual(style.headIndent, indent, accuracy: 0.001, "\(line) at \(offset)")
                XCTAssertEqual(style.firstLineHeadIndent, 0, "\(line): the first line is drawn as typed")
            }
            let content = lineRange.location + lineRange.length - 1
            XCTAssertEqual(fixture.style(at: content), .listItem, line)
            XCTAssertEqual(fixture.color(at: content), styler.baseColor, line)
            XCTAssertEqual(fixture.font(at: content), base, "\(line): list text is at the base size")
        }
        XCTAssertEqual(fixture.color(at: range(of: "- one", in: text).location), tertiary, "the bullet is dimmed")
        XCTAssertEqual(fixture.colors(in: range(of: "10. ", in: text)), Array(repeating: tertiary, count: 4))
        XCTAssertEqual(fixture.colors(in: range(of: "2. ", in: text)), Array(repeating: tertiary, count: 3))
        XCTAssertGreaterThan(headIndent(fixture, at: range(of: "10. tenth", in: text).location), bullet)
        XCTAssertGreaterThan(
            headIndent(fixture, at: range(of: "10. tenth", in: text).location),
            headIndent(fixture, at: range(of: "1. first", in: text).location), "a wider marker hangs further")

        let plain = range(of: "plain", in: text)
        XCTAssertEqual(headIndent(fixture, at: plain.location), 0)
        XCTAssertNil(fixture.style(at: plain.location))
        XCTAssertEqual(fixture.textView.string, text, "the text is exactly what went in (E-1)")
    }

    func testED5_wrappedLinesStartWhereTheItemTextDoes() throws {
        let fixture = makeFixture()
        let long = String(repeating: "words that wrap ", count: 20)
        let text = "- \(long)\n    - \(long)\n10. \(long)\n- [ ] \(long)\nplain \(long)\n"
        fixture.show(text)
        let layoutManager = try XCTUnwrap(fixture.textView.layoutManager)
        let container = try XCTUnwrap(fixture.textView.textContainer)
        layoutManager.ensureLayout(for: container)

        // Every line fragment starts after the container's own padding; indents add to that.
        let leadingEdge = container.lineFragmentPadding
        let plain = range(of: "plain", in: text)
        let plainWrapped = try wrappedLineX(after: plain.location, in: layoutManager)
        XCTAssertEqual(plainWrapped, glyphX(at: plain.location, in: layoutManager), accuracy: 0.5)
        XCTAssertEqual(plainWrapped, leadingEdge, accuracy: 0.5, "a plain paragraph wraps to the leading edge")

        // A task item hangs at its marker (ED-5), so its wrapped lines start under the box,
        // whose own look is ED-6's.
        for (line, textStart) in [("- ", "- "), ("    - ", "    - "), ("10. ", "10. "), ("- [ ] ", "- ")] {
            let lineRange = range(of: line + "words", in: text)
            let contentStart = lineRange.location + (textStart as NSString).length
            let wrapped = try wrappedLineX(after: contentStart, in: layoutManager)
            XCTAssertEqual(
                wrapped, glyphX(at: contentStart, in: layoutManager), accuracy: 0.5,
                "\(line.debugDescription): the wrapped line starts under the item text")
            XCTAssertEqual(
                wrapped, leadingEdge + headIndent(fixture, at: lineRange.location), accuracy: 0.5,
                "\(line.debugDescription): at the paragraph's head indent")
            XCTAssertGreaterThan(wrapped, leadingEdge)
        }
    }

    func testED5_indentsFollowCmdPlusAndCmdMinus() throws {
        let fixture = makeFixture()
        let text = "- one\n  - two\n1. first\nplain\n"
        fixture.show(text)
        let two = range(of: "  - two", in: text)
        let first = range(of: "1. first", in: text)
        let before = headIndent(fixture, at: two.location)
        XCTAssertEqual(before, width(of: "- ", in: base) + width(of: "  ", in: base), accuracy: 0.001)

        fixture.controller.makeTextBigger(nil)
        let bigger = NSFont.systemFont(ofSize: 14)
        XCTAssertEqual(fixture.styler.baseFont, bigger)
        XCTAssertEqual(fixture.styler.nestingIndent, width(of: "  ", in: bigger), accuracy: 0.001)
        XCTAssertEqual(
            headIndent(fixture, at: two.location), width(of: "- ", in: bigger) + width(of: "  ", in: bigger),
            accuracy: 0.001)
        XCTAssertGreaterThan(headIndent(fixture, at: two.location), before)
        XCTAssertEqual(headIndent(fixture, at: first.location), width(of: "1. ", in: bigger), accuracy: 0.001)
        XCTAssertEqual(headIndent(fixture, at: range(of: "plain", in: text).location), 0)

        fixture.controller.makeTextSmaller(nil)
        fixture.controller.makeTextSmaller(nil)
        let smaller = NSFont.systemFont(ofSize: 12)
        XCTAssertEqual(
            headIndent(fixture, at: two.location), width(of: "- ", in: smaller) + width(of: "  ", in: smaller),
            accuracy: 0.001)
        XCTAssertLessThan(headIndent(fixture, at: two.location), before)

        fixture.controller.makeTextActualSize(nil)
        XCTAssertEqual(headIndent(fixture, at: two.location), before, accuracy: 0.001)
    }

    /// Typing a marker gives the line its indent, the line typed after an item has none, and
    /// deleting the marker takes the indent away, all within the edited paragraph (E-3).
    func testED5_typedMarkersGainTheIndentAndTheNextLineDoesNot() throws {
        let fixture = makeFixture()
        let text = "first\nsecond\n\n- item\n"
        fixture.show(text)
        let bullet = width(of: "- ", in: base)
        XCTAssertEqual(headIndent(fixture, at: 0), 0)

        fixture.type("- ", at: 0)
        XCTAssertEqual(fixture.textView.string, "- first\nsecond\n\n- item\n")
        XCTAssertEqual(headIndent(fixture, at: 0), bullet, accuracy: 0.001)
        XCTAssertEqual(headIndent(fixture, at: 7), bullet, accuracy: 0.001, "the line break is in the paragraph")
        XCTAssertEqual(fixture.color(at: 0), tertiary)
        XCTAssertEqual(headIndent(fixture, at: 8), 0, "`second` is not an item")
        XCTAssertEqual(headIndent(fixture, at: 16), bullet, accuracy: 0.001, "`- item` still is")

        // Return at the end of the item, then a character on the new line: the new line is not
        // an item, whatever the typing attributes carried over.
        fixture.type("\n", at: 7)
        fixture.type("x", at: 8)
        XCTAssertEqual(fixture.textView.string, "- first\nx\nsecond\n\n- item\n")
        XCTAssertEqual(headIndent(fixture, at: 0), bullet, accuracy: 0.001)
        XCTAssertEqual(headIndent(fixture, at: 8), 0, "the new line hangs nowhere")
        XCTAssertEqual(headIndent(fixture, at: 9), 0)
        XCTAssertNil(fixture.style(at: 8))
        XCTAssertEqual(headIndent(fixture, at: 18), bullet, accuracy: 0.001, "`- item` still hangs")

        fixture.type("", at: 0, replacing: 2)
        XCTAssertEqual(fixture.textView.string, "first\nx\nsecond\n\n- item\n")
        for location in 0..<6 {
            XCTAssertEqual(headIndent(fixture, at: location), 0, "at \(location): no marker, no indent")
        }
        XCTAssertNil(fixture.style(at: 0))
        XCTAssertEqual(headIndent(fixture, at: 16), bullet, accuracy: 0.001, "the other item is untouched")
    }

    // MARK: - ED-7: blockquotes hang under their text, table lines are monospaced

    /// The paragraph range of `line` in `text`: the line plus its line break.
    private func paragraph(of line: String, in text: String) -> NSRange {
        let lineRange = range(of: line, in: text)
        let length = line.hasSuffix("\n") ? lineRange.length : lineRange.length + 1
        return NSRange(location: lineRange.location, length: length)
    }

    func testED7_blockquoteLinesHangAtTheirPrefixWithTheMarkersDimmed() throws {
        let fixture = makeFixture()
        let text = "> one\n> > two\n>three\n> - item\n>\n  > spaced\nplain\n"
        fixture.show(text)
        let styler = fixture.styler
        let one = width(of: "> ", in: base)
        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(styler.blockquoteHeadIndent(prefix: "> "), one, accuracy: 0.001)
        XCTAssertEqual(styler.blockquoteHeadIndent(prefix: "> > "), width(of: "> > ", in: base), accuracy: 0.001)

        // The indent is the prefix's width as typed, so a nested quote hangs further, a bare
        // `>` hangs at its own width, and a list item on a quoted line adds its marker.
        let expected: [(line: String, indent: CGFloat)] = [
            ("> one", one),
            ("> > two", width(of: "> > ", in: base)),
            (">three", width(of: ">", in: base)),
            ("> - item", one + width(of: "- ", in: base)),
            (">\n", width(of: ">", in: base)),
            ("  > spaced", width(of: "  > ", in: base)),
        ]
        for (line, indent) in expected {
            let paragraph = paragraph(of: line, in: text)
            XCTAssertGreaterThan(indent, 0, line)
            for offset in 0..<paragraph.length {
                let style = try XCTUnwrap(
                    fixture.attributes(at: paragraph.location + offset)[.paragraphStyle] as? NSParagraphStyle,
                    "\(line.debugDescription) at \(offset)")
                XCTAssertEqual(style.headIndent, indent, accuracy: 0.001, "\(line.debugDescription) at \(offset)")
                XCTAssertEqual(style.firstLineHeadIndent, 0, "\(line.debugDescription): the first line is as typed")
                XCTAssertEqual(
                    fixture.font(at: paragraph.location + offset), base,
                    "\(line.debugDescription) at \(offset): a quote keeps the base font")
            }
        }
        XCTAssertGreaterThan(
            headIndent(fixture, at: range(of: "> > two", in: text).location),
            headIndent(fixture, at: range(of: "> one", in: text).location), "a nested quote hangs further")

        // Every `>` is dimmed and the quoted text is not (ED-2); the line carries the quote's
        // attribute, or the list item's after its marker.
        XCTAssertEqual(fixture.colors(in: range(of: "> ", in: text)), [tertiary, fixture.styler.baseColor])
        XCTAssertEqual(fixture.colors(in: range(of: "one", in: text)), Array(repeating: styler.baseColor, count: 3))
        XCTAssertEqual(fixture.style(at: range(of: "one", in: text).location), .blockquote)
        XCTAssertEqual(fixture.style(at: 0), .blockquote, "the marker carries the quote's attribute")
        let two = range(of: "> > two", in: text)
        XCTAssertEqual(fixture.color(at: two.location), tertiary)
        XCTAssertEqual(fixture.color(at: two.location + 2), tertiary, "the second `>` too")
        XCTAssertEqual(fixture.color(at: two.location + 1), styler.baseColor, "the space between is text")
        XCTAssertEqual(fixture.color(at: two.location + 4), styler.baseColor)
        XCTAssertEqual(fixture.color(at: range(of: ">three", in: text).location), tertiary)
        let item = range(of: "> - item", in: text)
        XCTAssertEqual(fixture.color(at: item.location), tertiary)
        XCTAssertEqual(
            fixture.colors(in: range(of: "- item", in: text)),
            [tertiary, tertiary] + Array(repeating: styler.baseColor, count: 4))
        XCTAssertEqual(fixture.style(at: item.location + 4), .listItem, "the item text is the list item's")
        XCTAssertEqual(fixture.style(at: item.location), .blockquote)
        XCTAssertEqual(fixture.color(at: range(of: "  > spaced", in: text).location + 2), tertiary)

        let plain = range(of: "plain", in: text)
        XCTAssertEqual(headIndent(fixture, at: plain.location), 0)
        XCTAssertNil(fixture.style(at: plain.location))
        XCTAssertEqual(fixture.color(at: plain.location), styler.baseColor)
        XCTAssertEqual(fixture.textView.string, text, "the text is exactly what went in (E-1)")
    }

    func testED7_wrappedQuoteLinesStartWhereTheQuotedTextDoes() throws {
        let fixture = makeFixture()
        let long = String(repeating: "words that wrap ", count: 20)
        let text = "> \(long)\n> > \(long)\n> - \(long)\n>\(long)\nplain \(long)\n"
        fixture.show(text)
        let layoutManager = try XCTUnwrap(fixture.textView.layoutManager)
        let container = try XCTUnwrap(fixture.textView.textContainer)
        layoutManager.ensureLayout(for: container)

        let leadingEdge = container.lineFragmentPadding
        let plain = range(of: "plain", in: text)
        let plainWrapped = try wrappedLineX(after: plain.location, in: layoutManager)
        XCTAssertEqual(plainWrapped, leadingEdge, accuracy: 0.5, "a plain paragraph wraps to the leading edge")

        var seen: [CGFloat] = []
        for (line, prefix) in [("> ", "> "), ("> > ", "> > "), ("> - ", "> - "), (">w", ">")] {
            let lineRange = range(of: line + (line == ">w" ? "ords" : "words"), in: text)
            let contentStart = lineRange.location + (prefix as NSString).length
            let wrapped = try wrappedLineX(after: contentStart, in: layoutManager)
            XCTAssertEqual(
                wrapped, glyphX(at: contentStart, in: layoutManager), accuracy: 0.5,
                "\(line.debugDescription): the wrapped line starts under the quoted text")
            XCTAssertEqual(
                wrapped, leadingEdge + headIndent(fixture, at: lineRange.location), accuracy: 0.5,
                "\(line.debugDescription): at the paragraph's head indent")
            XCTAssertGreaterThan(wrapped, leadingEdge)
            seen.append(wrapped)
        }
        XCTAssertGreaterThan(seen[1], seen[0], "a nested quote hangs further than its parent")
        XCTAssertGreaterThan(seen[2], seen[0], "a quoted list item hangs past the quote's indent")
        XCTAssertLessThan(seen[3], seen[0], "a bare `>` hangs at its own width, no space")
    }

    func testED7_tableLinesAreMonospacedAndTheSeparatorRowIsDimmed() throws {
        let fixture = makeFixture()
        let text =
            "| a | **b** |\n|---|:-:|\n| 1 | `c` |\nplain\n\nx | y\n-|-\n2 | 3\n\n> | q |\n> |-|\nafter | pipe\n"
        fixture.show(text)
        let styler = fixture.styler

        func assertMono(_ needle: String, occurrence: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
            let found = range(of: needle, in: text, occurrence: occurrence)
            for location in found.location..<(found.location + found.length) {
                let font = fixture.font(at: location)
                XCTAssertEqual(font?.familyName, mono.familyName, "\(needle) at \(location)", file: file, line: line)
                XCTAssertEqual(font?.pointSize, base.pointSize, "\(needle) at \(location)", file: file, line: line)
            }
        }

        // A row, pipes, cells and spaces, is monospaced end to end; the pipes are dimmed and
        // the cells keep the text colour with their own inline styling on top.
        assertMono("| a | **b** |")
        let header = range(of: "| a | **b** |", in: text)
        XCTAssertEqual(fixture.style(at: header.location), .tableRow)
        XCTAssertEqual(fixture.color(at: header.location), tertiary)
        XCTAssertEqual(fixture.colors(in: range(of: " a ", in: text)), Array(repeating: styler.baseColor, count: 3))
        XCTAssertEqual(fixture.style(at: range(of: " a ", in: text).location + 1), .tableRow)
        let bold = range(of: "**b**", in: text)
        XCTAssertEqual(fixture.style(at: bold.location + 2), .bold)
        XCTAssertTrue(isBold(fixture.font(at: bold.location + 2)), "emphasis in a cell adds its trait to the mono font")
        XCTAssertEqual(fixture.color(at: bold.location), tertiary)
        XCTAssertEqual(fixture.color(at: header.location + header.length - 1), tertiary, "the closing pipe")

        // The separator row is dimmed whole, monospaced, and carries its own attribute.
        assertMono("|---|:-:|")
        let separator = range(of: "|---|:-:|", in: text)
        XCTAssertEqual(fixture.colors(in: separator), Array(repeating: tertiary, count: separator.length))
        XCTAssertEqual(Set(fixture.styles(in: separator).map { $0?.rawValue }), ["tableSeparator"])

        assertMono("| 1 | `c` |")
        let code = range(of: "`c`", in: text)
        XCTAssertEqual(fixture.style(at: code.location), .inlineCode, "code in a cell is code")
        XCTAssertEqual(fixture.color(at: code.location), NSColor.secondaryLabelColor)

        // A line after the table, and the text outside any table, is prose.
        for needle in ["plain", "after | pipe"] {
            let found = range(of: needle, in: text)
            for location in found.location..<(found.location + found.length) {
                XCTAssertEqual(fixture.font(at: location), base, "\(needle) at \(location)")
                XCTAssertEqual(fixture.color(at: location), styler.baseColor, "\(needle) at \(location)")
                XCTAssertNil(fixture.style(at: location), "\(needle) at \(location)")
            }
        }

        // Outer pipes are optional; the rows and separator are styled the same.
        assertMono("x | y")
        assertMono("-|-")
        assertMono("2 | 3")
        XCTAssertEqual(fixture.style(at: range(of: "x | y", in: text).location), .tableRow)
        XCTAssertEqual(fixture.colors(in: range(of: "-|-", in: text)), Array(repeating: tertiary, count: 3))
        XCTAssertEqual(fixture.style(at: range(of: "-|-", in: text).location), .tableSeparator)
        XCTAssertEqual(fixture.style(at: range(of: "2 | 3", in: text).location), .tableRow)

        // A table in a quote: the `>` stays in the base font, dimmed, the row is monospaced
        // after it, and the paragraph hangs at the quote's prefix.
        let quoted = range(of: "> | q |", in: text)
        XCTAssertEqual(fixture.font(at: quoted.location), base)
        XCTAssertEqual(fixture.color(at: quoted.location), tertiary)
        XCTAssertEqual(fixture.style(at: quoted.location), .blockquote)
        assertMono("| q |")
        XCTAssertEqual(fixture.style(at: range(of: "| q |", in: text).location), .tableRow)
        XCTAssertEqual(headIndent(fixture, at: quoted.location), width(of: "> ", in: base), accuracy: 0.001)
        assertMono("|-|")
        XCTAssertEqual(fixture.colors(in: range(of: "|-|", in: text)), Array(repeating: tertiary, count: 3))
        XCTAssertEqual(fixture.textView.string, text, "the text is exactly what went in (E-1)")
    }

    func testED7_quoteIndentsAndTableFontsFollowCmdPlusAndCmdMinus() throws {
        let fixture = makeFixture()
        let text = "> > quote\n| a |\n|-|\nplain\n"
        fixture.show(text)
        let row = range(of: "| a |", in: text)
        let separator = range(of: "|-|", in: text)
        let before = headIndent(fixture, at: 0)
        XCTAssertEqual(before, width(of: "> > ", in: base), accuracy: 0.001)
        XCTAssertEqual(fixture.font(at: row.location), mono)
        XCTAssertEqual(fixture.font(at: separator.location), mono)

        fixture.controller.makeTextBigger(nil)
        let bigger = NSFont.systemFont(ofSize: 14)
        XCTAssertEqual(fixture.styler.baseFont, bigger)
        XCTAssertEqual(headIndent(fixture, at: 0), width(of: "> > ", in: bigger), accuracy: 0.001)
        XCTAssertGreaterThan(headIndent(fixture, at: 0), before)
        XCTAssertEqual(fixture.font(at: row.location + 2), NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        XCTAssertEqual(fixture.font(at: separator.location), NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        XCTAssertEqual(fixture.color(at: separator.location + 1), tertiary)
        XCTAssertEqual(fixture.font(at: range(of: "plain", in: text).location), bigger)
        XCTAssertEqual(headIndent(fixture, at: range(of: "plain", in: text).location), 0)

        fixture.controller.makeTextSmaller(nil)
        fixture.controller.makeTextSmaller(nil)
        let smaller = NSFont.systemFont(ofSize: 12)
        XCTAssertEqual(headIndent(fixture, at: 0), width(of: "> > ", in: smaller), accuracy: 0.001)
        XCTAssertLessThan(headIndent(fixture, at: 0), before)
        XCTAssertEqual(fixture.font(at: row.location), NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))

        fixture.controller.makeTextActualSize(nil)
        XCTAssertEqual(headIndent(fixture, at: 0), before, accuracy: 0.001)
        XCTAssertEqual(fixture.font(at: row.location), mono)
    }

    /// Typing a `>` prefix gives the line its indent and takes it away again when deleted, and
    /// a separator typed under a line of pipes turns both into a table, all within the edited
    /// paragraph (E-3).
    func testED7_typedPrefixesAndSeparatorsRestyleTheirParagraph() throws {
        let fixture = makeFixture()
        let text = "first\nsecond\n\n| a |\nplain\n"
        fixture.show(text)
        let one = width(of: "> ", in: base)
        XCTAssertEqual(headIndent(fixture, at: 0), 0)
        XCTAssertNil(fixture.style(at: range(of: "| a |", in: text).location), "a lone row is not a table")
        XCTAssertEqual(fixture.font(at: range(of: "| a |", in: text).location), base)

        fixture.type("> ", at: 0)
        XCTAssertEqual(fixture.textView.string, "> first\nsecond\n\n| a |\nplain\n")
        XCTAssertEqual(headIndent(fixture, at: 0), one, accuracy: 0.001)
        XCTAssertEqual(headIndent(fixture, at: 7), one, accuracy: 0.001, "the line break is in the paragraph")
        XCTAssertEqual(fixture.color(at: 0), tertiary)
        XCTAssertEqual(fixture.style(at: 2), .blockquote)
        XCTAssertEqual(headIndent(fixture, at: 8), 0, "`second` is not quoted")
        XCTAssertNil(fixture.style(at: 8))

        fixture.type("> > ", at: 8)
        XCTAssertEqual(fixture.textView.string, "> first\n> > second\n\n| a |\nplain\n")
        XCTAssertEqual(headIndent(fixture, at: 8), width(of: "> > ", in: base), accuracy: 0.001)
        XCTAssertEqual(
            fixture.colors(in: NSRange(location: 8, length: 4)),
            [tertiary, fixture.styler.baseColor, tertiary, fixture.styler.baseColor])
        XCTAssertEqual(headIndent(fixture, at: 0), one, accuracy: 0.001, "the first line hangs as before")

        fixture.type("", at: 0, replacing: 2)
        XCTAssertEqual(fixture.textView.string, "first\n> > second\n\n| a |\nplain\n")
        for location in 0..<6 {
            XCTAssertEqual(headIndent(fixture, at: location), 0, "at \(location): no prefix, no indent")
        }
        XCTAssertNil(fixture.style(at: 0))
        XCTAssertEqual(
            headIndent(fixture, at: 6), width(of: "> > ", in: base), accuracy: 0.001, "the other quote is untouched")

        // A separator row typed under the lone row makes a table of both lines.
        let plain = range(of: "plain", in: fixture.textView.string)
        fixture.type("|-|\n", at: plain.location)
        XCTAssertEqual(fixture.textView.string, "first\n> > second\n\n| a |\n|-|\nplain\n")
        let row = range(of: "| a |", in: fixture.textView.string)
        XCTAssertEqual(Set(fixture.styles(in: row).map { $0?.rawValue }), ["tableRow"])
        XCTAssertEqual(fixture.font(at: row.location + 2)?.familyName, mono.familyName)
        let separator = range(of: "|-|", in: fixture.textView.string)
        XCTAssertEqual(Set(fixture.styles(in: separator).map { $0?.rawValue }), ["tableSeparator"])
        XCTAssertEqual(fixture.colors(in: separator), Array(repeating: tertiary, count: 3))
        let after = range(of: "plain", in: fixture.textView.string)
        XCTAssertNil(fixture.style(at: after.location), "a line without a pipe ends the table")
        XCTAssertEqual(fixture.font(at: after.location), base)

        fixture.type("", at: separator.location, replacing: 4)
        XCTAssertEqual(fixture.textView.string, "first\n> > second\n\n| a |\nplain\n")
        XCTAssertNil(fixture.style(at: row.location), "no separator, no table")
        XCTAssertEqual(fixture.font(at: row.location + 2), base)
        XCTAssertEqual(fixture.color(at: row.location), fixture.styler.baseColor, "a lone pipe is text")
    }

    // MARK: - V-1: the editor rendered with dimmed markers and emphasis

    func testV1_editorSnapshotShowsDimmedMarkersAndEmphasis() throws {
        let fixture = makeFixture()
        fixture.show(
            """
            # Meeting notes

            Prose with **bold**, *italic* and ~~struck~~ words, a [[Wikilink]], a #tag, `code` and a [link](https://example.com).

            - first item with **emphasis**
            - [ ] a task
            1. numbered

            > a quoted line

            | col | val |
            |-----|-----|
            | a   | 1   |

            ---

            After the rule.

            """)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.color(at: 0), tertiary)
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-markers")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    func testV1_editorSnapshotShowsTheHeadingScale() throws {
        let fixture = makeFixture()
        fixture.show(
            """
            # Level one heading

            Body text at the base size, with **bold** and `code` for comparison.

            ## Level two heading

            More body text under it.

            ### Level three heading

            #### Level four heading

            Setext level one
            ================

            Setext level two
            ----------------

            The last paragraph of body text.

            """)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.font(at: 2)?.pointSize ?? 0, 13 * 1.4, accuracy: 0.001)
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-headings")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    func testV1_editorSnapshotShowsListsHangingUnderTheirText() throws {
        let fixture = makeFixture()
        fixture.show(
            """
            # Lists

            - A short bullet item
            - A long bullet item whose text runs on past the edge of the editor so that it wraps onto a second line and shows the hanging indent aligning under the text
              - A nested item, two spaces in, that is also long enough to wrap onto a second line under its own text rather than under the bullet
                - Third level, short
            - Back at the first level

            1. First ordered item
            2. Second ordered item that is long enough to wrap onto a second line so the wrapped text lines up under the first word
            10. A two-digit marker hangs a little further, and this one wraps too so the alignment under its text can be seen

            - [ ] A task item that is long enough to wrap onto a second line, hanging at the marker with the box on the first line
            - [x] A done task

            A plain paragraph after the lists, long enough to wrap onto a second line, to show it wraps to the leading edge.

            """)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(headIndent(fixture, at: range(of: "- A short", in: fixture.textView.string).location), 0)
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-lists")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    func testV1_editorSnapshotShowsQuotesHangingAndTablesMonospaced() throws {
        let fixture = makeFixture()
        fixture.show(
            """
            # Quotes and tables

            > A quoted paragraph long enough to wrap onto a second line so the hanging indent under the quoted text can be seen, with the marker dimmed
            > > A nested quote, two levels in, that is also long enough to wrap onto a second line and hangs further than the outer one does, under its own text
            > - A list item inside a quote, long enough to wrap onto a second line, hanging under the item text rather than under the bullet or the quote marker

            A plain paragraph between them, long enough to wrap onto a second line, to show it wraps to the leading edge.

            | Name  | Count | Note           |
            |-------|------:|----------------|
            | alpha |     1 | with **bold**  |
            | beta  |    22 | and `code`     |
            | gamma |   333 | a [[Wikilink]] |

            Prose after the table.

            """)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        let text = fixture.textView.string
        XCTAssertGreaterThan(headIndent(fixture, at: range(of: "> A quoted", in: text).location), 0)
        XCTAssertEqual(fixture.font(at: range(of: "| Name", in: text).location)?.familyName, mono.familyName)
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-quotes-tables")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    /// ED-11: every link state at once, an existing, a missing and an ambiguous wikilink, a
    /// standard link, an autolink and a bare URL, plus links inside a done item.
    func testV1_editorSnapshotShowsLinkStates() throws {
        let fixture = makeFixture()
        let index = twoFooIndex()
        fixture.styler.linkIndex = { index }
        fixture.show(
            """
            # Links

            An existing note: [[Bar]], and one by path: [[daily/foo]].
            A missing note: [[Not yet written]], dotted, with a tooltip on hover.
            An ambiguous title: [[foo]], which two notes share.

            A [standard link](https://example.com), an autolink <https://example.org> and a bare https://example.net URL.

            - [x] done with [[Bar]], [[missing]] and https://example.com
            - [ ] open with [[Bar]], [[missing]] and https://example.com

            """)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        let text = fixture.textView.string
        XCTAssertEqual(fixture.style(at: range(of: "[[Not yet written]]", in: text).location), .missingLink)
        XCTAssertEqual(fixture.style(at: range(of: "[[foo]]", in: text).location), .ambiguousLink)
        XCTAssertEqual(fixture.style(at: range(of: "https://example.net", in: text).location), .link)
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-links")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }
}
