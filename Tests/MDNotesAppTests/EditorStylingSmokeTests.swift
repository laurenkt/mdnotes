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
    private let keys = [
        EditorFontPreference.familyDefaultsKey, EditorFontPreference.sizeDefaultsKey, MainView.listHeightDefaultsKey,
    ]
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

    private var base: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }

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
        XCTAssertEqual(fixture.color(at: link.location), NSColor.linkColor)
        XCTAssertEqual(fixture.font(at: link.location), base, "links keep the base weight")

        let tag = range(of: "#tag", in: text)
        XCTAssertEqual(Set(fixture.styles(in: tag).map { $0?.rawValue }), ["tag"])
        XCTAssertEqual(fixture.color(at: tag.location), NSColor.systemPurple)
        XCTAssertNil(fixture.style(at: tag.location + tag.length), "the comma after the tag is not")

        let code = range(of: "`code #no`", in: text)
        XCTAssertEqual(Set(fixture.styles(in: code).map { $0?.rawValue }), ["inlineCode"])
        XCTAssertEqual(fixture.color(at: code.location), NSColor.secondaryLabelColor)

        let fence = range(of: "```\nfenced [[no]] #no\n```\n", in: text)
        XCTAssertEqual(Set(fixture.styles(in: fence).map { $0?.rawValue }), ["fencedCode"])
        XCTAssertEqual(fixture.color(at: fence.location + 5), NSColor.secondaryLabelColor)

        let after = range(of: "after", in: text)
        XCTAssertNil(fixture.style(at: after.location))
        XCTAssertEqual(fixture.color(at: after.location), fixture.styler.baseColor)
        XCTAssertNil(fixture.style(at: range(of: "see", in: text).location))
    }

    func testE2_linksAndTagsOnAHeadingLineKeepItsWeight() throws {
        let fixture = makeFixture()
        let text = "# Head [[link]] #tag\n"
        fixture.show(text)
        let link = range(of: "[[link]]", in: text)
        XCTAssertTrue(isBold(fixture.font(at: link.location)))
        XCTAssertEqual(fixture.color(at: link.location), NSColor.linkColor)
        let tag = range(of: "#tag", in: text)
        XCTAssertTrue(isBold(fixture.font(at: tag.location)))
        XCTAssertEqual(fixture.color(at: tag.location), NSColor.systemPurple)
    }

    func testE2_stylingChangesNeitherTheTextNorItsMetrics() {
        let fixture = makeFixture()
        let text = "# Title\n\nsee [[Other]] and #tag `code`\n\n```swift\nlet x = 1\n```\n\nplain end"
        fixture.show(text)
        XCTAssertEqual(fixture.textView.string, text, "the text is exactly what went in")

        // Only the font weight and colour vary, run by run; family and size are the base's.
        let allowed: Set<NSAttributedString.Key> = [
            .font, .foregroundColor, .paragraphStyle, EditorStyler.tokenAttribute,
        ]
        var runs = 0
        fixture.storage.enumerateAttributes(in: NSRange(location: 0, length: fixture.storage.length), options: []) {
            attributes, range, _ in
            runs += 1
            XCTAssertTrue(
                Set(attributes.keys).isSubset(of: allowed), "unexpected attributes \(attributes.keys) in \(range)")
            if let font = attributes[.font] as? NSFont {
                XCTAssertEqual(font.pointSize, base.pointSize, "size unchanged in \(range)")
                XCTAssertEqual(font.familyName, base.familyName, "family unchanged in \(range)")
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

    func testE2_fontPreferenceChangeKeepsHeadingsBoldInTheNewFont() throws {
        let fixture = makeFixture()
        let text = "# Title\nbody [[link]]\n"
        fixture.show(text)
        XCTAssertTrue(isBold(fixture.font(at: 0)))

        UserDefaults.standard.set("Menlo", forKey: EditorFontPreference.familyDefaultsKey)
        UserDefaults.standard.set(15, forKey: EditorFontPreference.sizeDefaultsKey)

        let heading = try XCTUnwrap(fixture.font(at: 0))
        XCTAssertEqual(heading.familyName, "Menlo")
        XCTAssertEqual(heading.pointSize, 15)
        XCTAssertTrue(isBold(heading), "the heading is bold in the new font: \(heading)")
        let body = try XCTUnwrap(fixture.font(at: range(of: "body", in: text).location))
        XCTAssertEqual(body.familyName, "Menlo")
        XCTAssertEqual(body.pointSize, 15)
        XCTAssertFalse(isBold(body))
        XCTAssertEqual(fixture.color(at: range(of: "[[link]]", in: text).location), NSColor.linkColor)
        XCTAssertEqual(fixture.styler.baseFont.familyName, "Menlo")

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
            XCTAssertEqual(fixture.color(at: link.location), EditorStyler.ambiguousLinkColor, needle)
            XCTAssertEqual(fixture.font(at: link.location), base, "\(needle) keeps the base weight")
        }
        for needle in ["[[daily/foo]]", "[[Bar]]", "[[none]]", "![[foo]]"] {
            let link = range(of: needle, in: text)
            XCTAssertEqual(Set(fixture.styles(in: link).map { $0?.rawValue }), ["wikilink"], needle)
            XCTAssertEqual(fixture.color(at: link.location), NSColor.linkColor, needle)
        }
        XCTAssertNil(fixture.style(at: range(of: "see", in: text).location))

        let heading = range(of: "[[foo]]", in: text, occurrence: 2)
        XCTAssertEqual(fixture.style(at: heading.location), .ambiguousLink)
        XCTAssertEqual(fixture.color(at: heading.location), EditorStyler.ambiguousLinkColor)
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
        XCTAssertEqual(fixture.color(at: first.location), EditorStyler.ambiguousLinkColor)
        XCTAssertEqual(Set(fixture.styles(in: second).map { $0?.rawValue }), ["ambiguousLink"])
        XCTAssertEqual(fixture.color(at: second.location), EditorStyler.ambiguousLinkColor)
        XCTAssertEqual(fixture.color(at: bar.location), mark, "a link whose resolution did not change is untouched")
        XCTAssertEqual(fixture.style(at: bar.location), .wikilink)
        XCTAssertEqual(fixture.color(at: 0), mark, "plain text is untouched")
        XCTAssertEqual(fixture.color(at: range(of: "#tag", in: text).location), mark, "a tag is untouched")
        XCTAssertEqual(fixture.style(at: range(of: "#tag", in: text).location), .tag)
        XCTAssertEqual(fixture.textView.string, text)

        // Back to one foo: the links are plain wikilinks again.
        box.index = oneFooIndex()
        fixture.styler.restyleLinks()
        XCTAssertEqual(fixture.style(at: first.location), .wikilink)
        XCTAssertEqual(fixture.color(at: first.location), NSColor.linkColor)
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
        XCTAssertEqual(fixture.color(at: foo.location), NSColor.linkColor)

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
        XCTAssertEqual(fixture.color(at: foo.location), EditorStyler.ambiguousLinkColor)
        XCTAssertEqual(fixture.style(at: bar.location), .wikilink)
        XCTAssertEqual(fixture.textView.string, body, "the text is untouched")
        XCTAssertFalse(fixture.controller.editorController.hasUnsavedEdits, "re-styling is not an edit")

        // Typing another link to the shared title styles it as ambiguous as it arrives.
        let end = (body as NSString).length
        fixture.type("[[foo]]", at: end)
        XCTAssertEqual(fixture.style(at: end), .ambiguousLink)
        library.stop()
    }
}
