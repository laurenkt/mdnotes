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

    func testE2_headingsAreBoldAtTheSameSizeAndBodyIsNot() throws {
        let fixture = makeFixture()
        let text = "# Title\nbody line\n## Second\n"
        fixture.show(text)

        let heading = try XCTUnwrap(fixture.font(at: 0))
        XCTAssertTrue(isBold(heading), "heading is bold: \(heading)")
        XCTAssertEqual(heading.pointSize, base.pointSize)
        XCTAssertEqual(heading.familyName, base.familyName)
        XCTAssertEqual(fixture.style(at: 0), .heading)
        XCTAssertEqual(fixture.style(at: 6), .heading, "the whole heading line is styled")
        XCTAssertEqual(fixture.styler.headingFont, heading)

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
        XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["wikilink"])
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

    /// E-8, E-2: the monospaced font goes on inline and fenced code and on nothing else; every
    /// other character, styled or not, keeps the system font's family at the base size.
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
            XCTAssertEqual(font.pointSize, base.pointSize, "the size never changes (E-2)")
        }
        XCTAssertEqual(fixture.style(at: range(of: "`in heading`", in: text).location), .inlineCode)
        XCTAssertEqual(fixture.style(at: range(of: "fenced", in: text).location), .fencedCode)
        XCTAssertEqual(fixture.style(at: range(of: "[[link]]", in: text).location), .wikilink)
        XCTAssertEqual(fixture.style(at: range(of: "#tag", in: text).location), .tag)
        XCTAssertTrue(isBold(fixture.font(at: 0)), "the heading keeps its weight")

        // The styler's own attributes say the same: only the two code styles carry the font.
        for style in EditorStyler.TokenStyle.allCases {
            let font = fixture.styler.attributes(for: style)[.font] as? NSFont
            switch style {
            case .inlineCode, .fencedCode: XCTAssertEqual(font, mono, "\(style)")
            case .heading: XCTAssertEqual(font, fixture.styler.headingFont)
            case .wikilink, .ambiguousLink, .tag: XCTAssertNil(font, "\(style) keeps the base font")
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
        // base's everywhere and the family too, except on code, which is monospaced (E-8).
        let allowed: Set<NSAttributedString.Key> = [
            .font, .foregroundColor, .paragraphStyle, .strikethroughStyle, EditorStyler.tokenAttribute,
        ]
        let codeStyles = [EditorStyler.TokenStyle.inlineCode.rawValue, EditorStyler.TokenStyle.fencedCode.rawValue]
        var runs = 0
        fixture.storage.enumerateAttributes(in: NSRange(location: 0, length: fixture.storage.length), options: []) {
            attributes, range, _ in
            runs += 1
            XCTAssertTrue(
                Set(attributes.keys).isSubset(of: allowed), "unexpected attributes \(attributes.keys) in \(range)")
            if let font = attributes[.font] as? NSFont {
                XCTAssertEqual(font.pointSize, base.pointSize, "size unchanged in \(range)")
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
        XCTAssertEqual(fixture.style(at: end + 3), .wikilink)
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
        XCTAssertEqual(heading.pointSize, 15)
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
        XCTAssertEqual(fixture.style(at: start + 2), .wikilink)
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
        XCTAssertEqual(fixture.style(at: range(of: "[[link]]", in: newText).location), .wikilink)
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
        XCTAssertEqual(fixture.style(at: range(of: "[[Other]]", in: body).location), .wikilink)
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
    /// ambiguous in the warning tint; a path to one of them, a unique title, an unresolved
    /// title and an embed keep the link style.
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
        for needle in ["[[daily/foo]]", "[[Bar]]", "[[none]]", "![[foo]]"] {
            let link = range(of: needle, in: text)
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["wikilink"], needle)
            XCTAssertEqual(fixture.color(at: inside(link)), NSColor.linkColor, needle)
            XCTAssertEqual(fixture.color(at: link.location), tertiary, "\(needle) brackets are dimmed (ED-2)")
        }
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
        let text = "one [[foo]] and [[Bar]] #tag\n\ntwo [[foo]]\n"
        fixture.show(text)
        let first = range(of: "[[foo]]", in: text)
        let second = range(of: "[[foo]]", in: text, occurrence: 1)
        let bar = range(of: "[[Bar]]", in: text)
        XCTAssertEqual(fixture.style(at: first.location), .wikilink, "one note titled foo is unique")
        XCTAssertEqual(fixture.style(at: second.location), .wikilink)

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
        XCTAssertEqual(fixture.style(at: bar.location), .wikilink)
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
        XCTAssertEqual(fixture.style(at: bar.location), .wikilink)
        XCTAssertEqual(fixture.textView.string, body, "the text is untouched")
        XCTAssertFalse(fixture.controller.editorController.hasUnsavedEdits, "re-styling is not an edit")

        // Typing another link to the shared title styles it as ambiguous as it arrives.
        let end = (body as NSString).length
        fixture.type("[[foo]]", at: end)
        XCTAssertEqual(fixture.style(at: end), .ambiguousLink)
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

        XCTAssertEqual(colors(of: "[t"), [tertiary, base])
        XCTAssertEqual(colors(of: "t](u)"), [base, tertiary], "the closing bracket and URL are markers")
        XCTAssertEqual(colors(of: "!["), [tertiary])
        XCTAssertEqual(colors(of: "a](u)"), [base, tertiary])
        XCTAssertEqual(colors(of: "<"), [tertiary])
        XCTAssertEqual(colors(of: "http://x.y"), [base])
        XCTAssertEqual(colors(of: ">", occurrence: 1), [tertiary])
        XCTAssertEqual(colors(of: "http://z.w"), [base], "a bare URL has no markers")

        XCTAssertEqual(colors(of: "| a | b |"), [tertiary, base])
        XCTAssertEqual(colors(of: "|", occurrence: 0), [tertiary])
        XCTAssertEqual(colors(of: " a "), [base])
        XCTAssertEqual(colors(of: "|---|---|"), [tertiary, base], "the separator's pipes")
        XCTAssertEqual(colors(of: " d "), [base])

        let link = range(of: "[[Link]]", in: text)
        XCTAssertEqual(colors(of: "[["), [tertiary])
        XCTAssertEqual(colors(of: "]]"), [tertiary])
        XCTAssertEqual(colors(of: "Link"), [NSColor.linkColor])
        XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["wikilink"])
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
            fixture.font(at: b.location), fixture.styler.headingFont, "the marker is at the heading's weight")
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
}
