import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for thematic breaks (ED-8): the typed rule is styled as a marker and
/// carries the `.rule` token style over exactly its characters, and the editor's
/// `EditorLayoutManager` paints the faded extension from its end to the trailing edge while
/// the text, the selection, the caret and copy never see it. Text goes into the real text
/// view's storage as a load does, and edits go through `insertText`, the path a keystroke
/// takes.
@MainActor
final class RuleExtensionSmokeTests: XCTestCase {
    private let keys = [EditorFontPreference.sizeDefaultsKey, MainView.listHeightDefaultsKey]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() async throws {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try await super.tearDown()
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        var textView: EditorTextView { controller.mainView.textView }
        var storage: NSTextStorage { textView.textStorage ?? NSTextStorage() }
        var layoutManager: EditorLayoutManager { textView.editorLayoutManager }

        /// Puts `text` in the editor as a load does, makes it editable so typing works, and
        /// lays every line out so glyph geometry can be asked for.
        func show(_ text: String) {
            textView.string = text
            textView.isEditable = true
            controller.mainView.layoutSubtreeIfNeeded()
            if let container = textView.textContainer {
                layoutManager.ensureLayout(for: container)
            }
        }

        /// Types `text` at `location`, replacing `length` characters, as a keystroke does.
        func type(_ text: String, at location: Int, replacing length: Int = 0) {
            textView.insertText(text, replacementRange: NSRange(location: location, length: length))
        }

        func style(at location: Int) -> EditorStyler.TokenStyle? {
            let value = storage.attributes(at: location, effectiveRange: nil)[EditorStyler.tokenAttribute] as? String
            return value.flatMap(EditorStyler.TokenStyle.init)
        }

        func color(at location: Int) -> NSColor? {
            storage.attributes(at: location, effectiveRange: nil)[.foregroundColor] as? NSColor
        }

        /// The token style of every character in `range`, or nil where there is none.
        func styles(in range: NSRange) -> [EditorStyler.TokenStyle?] {
            (range.location..<(range.location + range.length)).map { style(at: $0) }
        }

        /// Every typed rule in the text, as the layout manager reads them.
        var rules: [NSRange] { layoutManager.ruleRanges(in: NSRange(location: 0, length: storage.length)) }

        /// The extension of the rule at `rule`, which the text must hold.
        func extent(of rule: NSRange) throws -> EditorLayoutManager.RuleExtension {
            let container = try XCTUnwrap(textView.textContainer)
            return try XCTUnwrap(layoutManager.ruleExtension(for: rule, in: container), "rule at \(rule) has no extent")
        }

        /// A point in the view's coordinates on the baseline of `extent`, `fraction` of the way
        /// across it.
        func point(in extent: EditorLayoutManager.RuleExtension, fraction: CGFloat) -> NSPoint {
            let origin = textView.textContainerOrigin
            return NSPoint(
                x: origin.x + extent.rect.minX + extent.rect.width * fraction,
                y: origin.y + extent.rect.midY)
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

    @MainActor
    private final class PasteboardBox {
        let pasteboard: NSPasteboard
        init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    }

    /// A private pasteboard, released at teardown, so the user's clipboard is left alone.
    private func makePasteboard() -> NSPasteboard {
        let box = PasteboardBox(NSPasteboard(name: NSPasteboard.Name("MDNotes.tests.\(UUID().uuidString)")))
        addTeardownBlock { await MainActor.run { box.pasteboard.releaseGlobally() } }
        return box.pasteboard
    }

    /// The document with one of each rule spelling, a rule at the start, and a `---` under
    /// text that is a setext underline, not a rule (ED-9).
    private let document = """
        ***
        A paragraph before the first rule.

        ---

        Another paragraph, then a spaced rule.

        * * *

        Then an underscore rule with trailing spaces after it.

        ___\u{20}\u{20}\u{20}

        Setext heading
        ---
        The last paragraph.

        """

    // MARK: - ED-8: rule token ranges

    func testED8_ruleStyleCoversExactlyTheTypedCharacters() throws {
        let fixture = makeFixture()
        fixture.show(document)
        let text = fixture.textView.string
        let star = range(of: "***", in: text)
        let dash = range(of: "---", in: text)
        let spaced = range(of: "* * *", in: text)
        let under = range(of: "___", in: text)

        for rule in [star, dash, spaced, under] {
            XCTAssertEqual(fixture.styles(in: rule), Array(repeating: .rule, count: rule.length), "\(rule)")
            XCTAssertEqual(
                fixture.styles(in: rule).count, rule.length, "the rule is styled over exactly its own characters")
            for location in rule.location..<(rule.location + rule.length) {
                XCTAssertEqual(fixture.color(at: location), EditorStyler.markerColor, "a rule is a marker (ED-2)")
            }
            XCTAssertNotEqual(
                fixture.style(at: rule.location + rule.length), .rule, "the line break after is not a rule")
            if rule.location > 0 {
                XCTAssertNotEqual(fixture.style(at: rule.location - 1), .rule, "the line break before is not a rule")
            }
        }
        // The spaces typed after `___` are not part of the rule: the extension starts at the
        // last underscore, not after the trailing whitespace.
        XCTAssertNil(fixture.style(at: under.location + under.length))
        XCTAssertNil(fixture.style(at: under.location + under.length + 2))

        // `---` directly under text is a setext heading underline (ED-9), never a rule.
        let setext = range(of: "---", in: text, occurrence: 1)
        XCTAssertEqual(fixture.styles(in: setext), Array(repeating: .heading, count: 3))
        XCTAssertEqual(fixture.rules, [star, dash, spaced, under], "the layout manager reads the same four rules")
    }

    func testED8_ruleRangesAreReadForTheAskedRangeOnly() throws {
        let fixture = makeFixture()
        fixture.show(document)
        let text = fixture.textView.string
        let star = range(of: "***", in: text)
        let dash = range(of: "---", in: text)
        let spaced = range(of: "* * *", in: text)

        let firstLine = (text as NSString).lineRange(for: NSRange(location: 0, length: 0))
        XCTAssertEqual(fixture.layoutManager.ruleRanges(in: firstLine), [star])
        XCTAssertEqual(
            fixture.layoutManager.ruleRanges(in: NSRange(location: dash.location + 1, length: 1)), [dash],
            "a range that clips a rule still names the whole rule")
        let middle = NSRange(location: dash.location, length: spaced.location + 1 - dash.location)
        XCTAssertEqual(fixture.layoutManager.ruleRanges(in: middle), [dash, spaced])
        XCTAssertEqual(fixture.layoutManager.ruleRanges(in: NSRange(location: 0, length: 0)), [])
        XCTAssertEqual(fixture.layoutManager.ruleRanges(in: NSRange(location: 4, length: 20)), [])
    }

    // MARK: - ED-8: the extension's geometry

    func testED8_extensionRunsFromTheRuleEndToTheTrailingEdge() throws {
        let fixture = makeFixture()
        fixture.show(document)
        let text = fixture.textView.string
        let container = try XCTUnwrap(fixture.textView.textContainer)
        let layoutManager = fixture.layoutManager
        let trailingEdge = container.size.width - container.lineFragmentPadding
        XCTAssertGreaterThan(trailingEdge, 100, "the editor is wide enough for an extension to show")

        for rule in fixture.rules {
            let extent = try fixture.extent(of: rule)
            let glyphs = layoutManager.glyphRange(forCharacterRange: rule, actualCharacterRange: nil)
            let typed = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            XCTAssertEqual(extent.rule, rule)
            XCTAssertEqual(extent.rect.minX, typed.maxX, accuracy: 0.01, "starts where the typed rule ends")
            XCTAssertEqual(extent.rect.maxX, trailingEdge, accuracy: 0.01, "ends at the trailing edge")
            XCTAssertEqual(extent.rect.minY, fragment.minY, accuracy: 0.01, "on the rule's line")
            XCTAssertEqual(extent.rect.height, fragment.height, accuracy: 0.01)
            XCTAssertGreaterThan(extent.baseline, fragment.minY)
            XCTAssertLessThan(extent.baseline, fragment.maxY)
            let glyphBaseline = fragment.minY + layoutManager.location(forGlyphAt: glyphs.location).y
            XCTAssertEqual(extent.baseline, glyphBaseline, accuracy: 0.01, "the hyphens sit on the rule's baseline")
        }

        // The underscore rule's trailing spaces are not part of it: its extension starts where
        // the last underscore ends, not after the spaces.
        let under = range(of: "___", in: text)
        let underExtent = try fixture.extent(of: under)
        let withSpaces = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: under.location, length: under.length + 3), actualCharacterRange: nil)
        XCTAssertLessThan(
            underExtent.rect.minX, layoutManager.boundingRect(forGlyphRange: withSpaces, in: container).maxX)

        // A paragraph line is not a rule and has no extension.
        let prose = range(of: "A paragraph", in: text)
        XCTAssertNil(layoutManager.ruleExtension(for: prose, in: container))
        XCTAssertNil(layoutManager.ruleExtension(for: NSRange(location: 0, length: 0), in: container))
    }

    func testED8_extensionFollowsTheFontSize() throws {
        let fixture = makeFixture()
        fixture.show(document)
        let dash = range(of: "---", in: fixture.textView.string)
        let before = try fixture.extent(of: dash)
        fixture.controller.makeTextBigger(nil)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        if let container = fixture.textView.textContainer { fixture.layoutManager.ensureLayout(for: container) }
        let after = try fixture.extent(of: dash)
        XCTAssertGreaterThan(after.rect.minX, before.rect.minX, "a bigger rule ends further along (E-8)")
        XCTAssertGreaterThan(after.rect.height, before.rect.height, "on a taller line")
        XCTAssertEqual(after.rect.maxX, before.rect.maxX, accuracy: 0.01, "still to the trailing edge")
    }

    // MARK: - ED-8: the extension is not text

    func testED8_extensionIsNeitherTextNorSelectableNorCopied() throws {
        let fixture = makeFixture()
        fixture.show(document)
        let textView = fixture.textView
        let text = textView.string
        XCTAssertEqual(text, document, "the text is exactly what went in (E-1)")
        XCTAssertEqual(fixture.controller.editorController.text, document)
        XCTAssertEqual(fixture.storage.length, (document as NSString).length, "nothing was inserted")

        let dash = range(of: "---", in: text)
        let ruleEnd = dash.location + dash.length
        let extent = try fixture.extent(of: dash)
        for fraction: CGFloat in [0.1, 0.5, 0.95] {
            let point = fixture.point(in: extent, fraction: fraction)
            XCTAssertEqual(
                textView.characterIndexForInsertion(at: point), ruleEnd,
                "a click on the extension lands the caret at the rule's end, as past any line's end")
            XCTAssertNil(textView.characterIndex(under: point), "no character is drawn there")
        }

        // The caret steps from the rule's end straight onto the next line: there is nothing
        // between them to land on.
        textView.setSelectedRange(NSRange(location: ruleEnd, length: 0))
        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: ruleEnd + 1, length: 0))
        textView.moveLeft(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: ruleEnd, length: 0))
        textView.moveToEndOfLine(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: ruleEnd, length: 0))

        // Select-all covers the text and no more, and copy writes exactly the file's text.
        textView.selectAll(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: (document as NSString).length))
        // `copy:` declares the view's own writable types (the plain string type, for a plain
        // text view) before calling `writeSelection`, which writes only those.
        let types = textView.writablePasteboardTypes
        let pasteboard = makePasteboard()
        pasteboard.declareTypes(types, owner: nil)
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: types))
        XCTAssertEqual(pasteboard.string(forType: .string), document)

        // Selecting the rule's line by dragging past its end selects the typed rule and its
        // line break, nothing drawn.
        textView.setSelectedRange(NSRange(location: dash.location, length: 0))
        textView.moveToEndOfLineAndModifySelection(nil)
        XCTAssertEqual(textView.selectedRange(), dash)
        let ruleBoard = makePasteboard()
        ruleBoard.declareTypes(types, owner: nil)
        XCTAssertTrue(textView.writeSelection(to: ruleBoard, types: types))
        XCTAssertEqual(ruleBoard.string(forType: .string), "---")
    }

    // MARK: - ED-8: drawing

    /// Draws `glyphs` through the layout manager into a transparent bitmap the size of the
    /// text container, flipped as the text view is, and returns the bitmap.
    private func draw(_ glyphs: NSRange, with fixture: Fixture) throws -> NSBitmapImageRep {
        let container = try XCTUnwrap(fixture.textView.textContainer)
        let used = fixture.layoutManager.usedRect(for: container)
        let width = Int(container.size.width.rounded(.up))
        let height = Int(used.maxY.rounded(.up)) + 1
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let unflipped = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let context = NSGraphicsContext(cgContext: unflipped.cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        fixture.layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Whether any pixel of `rep` is painted on the row through `extent`'s baseline between
    /// `from` and `to` (x in container points).
    private func isPainted(
        _ rep: NSBitmapImageRep, along extent: EditorLayoutManager.RuleExtension, from: CGFloat, to: CGFloat
    )
        -> Bool
    {
        // Hyphens sit a little above the baseline; scan the rows between it and mid-height.
        let rows = Int(extent.rect.midY.rounded(.down))...Int(extent.baseline.rounded(.down))
        for y in rows {
            for x in Int(from.rounded(.up))..<Int(to.rounded(.down)) {
                guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh else { continue }
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 { return true }
            }
        }
        return false
    }

    func testED8_extensionIsPaintedToTheTrailingEdgeAndNoFurther() throws {
        let fixture = makeFixture()
        fixture.show(document)
        let layoutManager = fixture.layoutManager
        let whole = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: fixture.storage.length), actualCharacterRange: nil)
        let rep = try draw(whole, with: fixture)
        for rule in fixture.rules {
            let extent = try fixture.extent(of: rule)
            XCTAssertTrue(
                isPainted(rep, along: extent, from: extent.rect.minX + 2, to: extent.rect.minX + 40),
                "hyphens start where the rule ends, \(rule)")
            XCTAssertTrue(
                isPainted(rep, along: extent, from: extent.rect.maxX - 40, to: extent.rect.maxX - 2),
                "hyphens reach the trailing edge, \(rule)")
            XCTAssertFalse(
                isPainted(rep, along: extent, from: extent.rect.maxX + 1, to: CGFloat(rep.pixelsWide)),
                "nothing past the trailing edge, \(rule)")
        }
        // A paragraph line's tail stays clear: only rules extend.
        let prose = range(of: "A paragraph before the first rule.", in: fixture.textView.string)
        let container = try XCTUnwrap(fixture.textView.textContainer)
        let proseGlyphs = layoutManager.glyphRange(forCharacterRange: prose, actualCharacterRange: nil)
        let proseRect = layoutManager.boundingRect(forGlyphRange: proseGlyphs, in: container)
        let proseTail = EditorLayoutManager.RuleExtension(
            rule: prose,
            rect: NSRect(
                x: proseRect.maxX, y: proseRect.minY, width: container.size.width - proseRect.maxX,
                height: proseRect.height),
            baseline: proseRect.minY + layoutManager.location(forGlyphAt: proseGlyphs.location).y)
        XCTAssertFalse(isPainted(rep, along: proseTail, from: proseRect.maxX + 2, to: CGFloat(rep.pixelsWide)))
    }

    func testED8_extensionIsPaintedForTheDrawnGlyphsOnly() throws {
        let fixture = makeFixture()
        fixture.show(document)
        let text = fixture.textView.string
        let layoutManager = fixture.layoutManager
        let star = range(of: "***", in: text)
        let dash = range(of: "---", in: text)
        let spaced = range(of: "* * *", in: text)

        // Only the first rule's line is drawn, as when the rest is scrolled out of view: the
        // first extension is painted and the others' lines stay clear.
        let firstLine = (text as NSString).lineRange(for: NSRange(location: 0, length: 0))
        let rep = try draw(
            layoutManager.glyphRange(forCharacterRange: firstLine, actualCharacterRange: nil), with: fixture)
        let starExtent = try fixture.extent(of: star)
        XCTAssertTrue(isPainted(rep, along: starExtent, from: starExtent.rect.minX + 2, to: starExtent.rect.maxX - 2))
        for rule in [dash, spaced] {
            let extent = try fixture.extent(of: rule)
            XCTAssertFalse(
                isPainted(rep, along: extent, from: extent.rect.minX, to: extent.rect.maxX),
                "not drawn, so not painted: \(rule)")
        }

        // The lines from the second rule on, without the first: the reverse.
        let rest = NSRange(location: dash.location, length: fixture.storage.length - dash.location)
        let restRep = try draw(
            layoutManager.glyphRange(forCharacterRange: rest, actualCharacterRange: nil), with: fixture)
        XCTAssertFalse(isPainted(restRep, along: starExtent, from: starExtent.rect.minX, to: starExtent.rect.maxX))
        for rule in [dash, spaced] {
            let extent = try fixture.extent(of: rule)
            XCTAssertTrue(
                isPainted(restRep, along: extent, from: extent.rect.minX + 2, to: extent.rect.maxX - 2), "\(rule)")
        }
    }

    // MARK: - ED-8, E-3: edits

    func testED8_aLineThatStopsBeingARuleLosesItsMarkAndExtension() throws {
        let fixture = makeFixture()
        fixture.show(document)
        let text = fixture.textView.string
        let dash = range(of: "---", in: text)
        let container = try XCTUnwrap(fixture.textView.textContainer)
        XCTAssertTrue(fixture.rules.contains(dash))

        // Prose typed after the hyphens makes the line a paragraph.
        fixture.type(" and text", at: dash.location + dash.length)
        XCTAssertEqual(fixture.styles(in: dash), [nil, nil, nil])
        XCTAssertFalse(fixture.rules.contains(dash))
        XCTAssertNil(fixture.layoutManager.ruleExtension(for: dash, in: container))

        // Undo brings the rule and its extension back (E-7).
        fixture.textView.breakUndoCoalescing()
        fixture.textView.undoManager?.undo()
        XCTAssertEqual(fixture.textView.string, text)
        XCTAssertEqual(fixture.styles(in: dash), [.rule, .rule, .rule])
        XCTAssertNotNil(fixture.layoutManager.ruleExtension(for: dash, in: container))

        // Deleting the blank line before it puts `---` directly under text: a setext
        // underline (ED-9), so the heading takes over and the extension goes.
        fixture.type("", at: dash.location - 1, replacing: 1)
        let moved = NSRange(location: dash.location - 1, length: 3)
        XCTAssertEqual(fixture.styles(in: moved), [.heading, .heading, .heading])
        XCTAssertFalse(fixture.rules.contains(moved))
        XCTAssertNil(fixture.layoutManager.ruleExtension(for: moved, in: container))
    }

    func testED8_aTypedRuleGainsItsMarkAndExtension() throws {
        let fixture = makeFixture()
        fixture.show("A paragraph.\n\n\nMore prose.\n")
        let container = try XCTUnwrap(fixture.textView.textContainer)
        XCTAssertEqual(fixture.rules, [])
        let blank = range(of: "\n\n\n", in: fixture.textView.string).location + 2
        fixture.type("-", at: blank)
        fixture.type("-", at: blank + 1)
        XCTAssertEqual(fixture.rules, [], "two hyphens are not a rule")
        fixture.type("-", at: blank + 2)
        let rule = NSRange(location: blank, length: 3)
        XCTAssertEqual(fixture.rules, [rule], "the third makes it one")
        XCTAssertEqual(fixture.styles(in: rule), [.rule, .rule, .rule])
        fixture.layoutManager.ensureLayout(for: container)
        let extent = try fixture.extent(of: rule)
        XCTAssertEqual(extent.rect.maxX, container.size.width - container.lineFragmentPadding, accuracy: 0.01)
        XCTAssertEqual(fixture.textView.string, "A paragraph.\n\n---\nMore prose.\n", "the text is only what was typed")
    }

    // MARK: - V-1

    func testV1_editorSnapshotShowsRuleExtensions() throws {
        let fixture = makeFixture()
        fixture.show(
            """
            # Rules

            A paragraph before the first rule, long enough to show where prose wraps against the trailing edge that the rule reaches.

            ---

            The typed hyphens stay text and the faded ones continue them to the edge.

            * * *

            A spaced rule of asterisks gets the same hyphen extension.

            ___

            Setext heading
            ---
            A `---` under text is a heading underline, not a rule (ED-9), so it has no extension.

            """)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.rules.count, 3)
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-rules")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }
}
