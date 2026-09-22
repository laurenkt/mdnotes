import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for section banding (ED-10): the thematic breaks divide the text into
/// sections, every second one is painted on `EditorLayoutManager.bandColor` from the middle of
/// its rule's hyphens down to the middle of the next rule's, across the editor's full width,
/// for the drawn range only, and the layout manager's rule list follows edits. Text goes into
/// the real text view's storage as a load does, and edits go through `insertText`, the path a
/// keystroke takes.
@MainActor
final class SectionBandSmokeTests: XCTestCase {
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
        var whole: NSRange { NSRange(location: 0, length: storage.length) }

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

        /// The range of the `occurrence`th `needle` in the text.
        func range(of needle: String, occurrence: Int = 0) -> NSRange {
            let text = textView.string as NSString
            var search = NSRange(location: 0, length: text.length)
            var found = NSRange(location: NSNotFound, length: 0)
            for _ in 0...occurrence {
                found = text.range(of: needle, options: [], range: search)
                guard found.location != NSNotFound else { break }
                let next = found.location + found.length
                search = NSRange(location: next, length: text.length - next)
            }
            return found
        }

        /// The whole line holding `location`, line break included.
        func line(at location: Int) -> NSRange {
            (textView.string as NSString).lineRange(for: NSRange(location: location, length: 0))
        }

        /// The top of the line fragment that holds `location`.
        func lineTop(at location: Int) -> CGFloat {
            layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: location), effectiveRange: nil
            ).minY
        }

        /// The bottom of the line fragment that holds `location`.
        func lineBottom(at location: Int) -> CGFloat {
            layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: location), effectiveRange: nil
            ).maxY
        }

        /// The vertical centre of the ink of `rule`'s own glyphs (a `---`), in container
        /// coordinates: the union of the glyphs' bounding boxes in the rule's font, placed on
        /// the rule's baseline. Read from Core Text, not from the layout manager's midline.
        func inkMidline(of rule: NSRange) throws -> CGFloat {
            let glyphs = layoutManager.glyphRange(forCharacterRange: rule, actualCharacterRange: nil)
            let font = try XCTUnwrap(storage.attribute(.font, at: rule.location, effectiveRange: nil) as? NSFont)
            var cgGlyphs = (glyphs.location..<NSMaxRange(glyphs)).map { layoutManager.cgGlyph(at: $0) }
            var boxes = [CGRect](repeating: .zero, count: cgGlyphs.count)
            _ = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &cgGlyphs, &boxes, cgGlyphs.count)
            let ink = boxes.dropFirst().reduce(try XCTUnwrap(boxes.first)) { $0.union($1) }
            XCTAssertGreaterThan(ink.height, 0, "a hyphen has ink")
            let baseline = lineTop(at: rule.location) + layoutManager.location(forGlyphAt: glyphs.location).y
            return baseline - ink.midY
        }

        /// The band rects for `range`, in container coordinates.
        func bandRects(in range: NSRange) throws -> [NSRect] {
            let container = try XCTUnwrap(textView.textContainer)
            return layoutManager.bandRects(in: range, in: container)
        }

        /// The typed rules read afresh from the whole storage, which the cached list must
        /// always equal.
        var rulesReadAfresh: [NSRange] { layoutManager.ruleRanges(in: whole) }
    }

    private func makeFixture() -> Fixture {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        return Fixture(controller: controller)
    }

    /// Three rules of three spellings with prose between them.
    private let threeRules = """
        # Sections

        The first section, on the text background.

        ---

        The second section, on the band.

        * * *

        The third section, on the text background again.

        ___

        The fourth section, on the band, to the end of the text.

        """

    // MARK: - ED-10: band ranges

    func testED10_noRulesMeansOneSectionAndNoBand() throws {
        let fixture = makeFixture()
        fixture.show("A paragraph.\n\nAnother paragraph, and no rule anywhere.\n")
        XCTAssertEqual(fixture.layoutManager.allRules, [])
        XCTAssertEqual(fixture.layoutManager.sectionStarts, [0])
        XCTAssertEqual(fixture.layoutManager.bandRanges(in: fixture.whole), [])
        XCTAssertEqual(try fixture.bandRects(in: fixture.whole), [])
    }

    func testED10_oneRuleBandsFromItsLineToTheEnd() throws {
        let fixture = makeFixture()
        fixture.show("Intro paragraph.\n\n---\n\nAfter the rule, to the end.\n")
        let rule = fixture.range(of: "---")
        XCTAssertEqual(fixture.layoutManager.allRules, [rule])
        XCTAssertEqual(fixture.layoutManager.sectionStarts, [0, rule.location])
        let band = NSRange(location: rule.location, length: fixture.storage.length - rule.location)
        XCTAssertEqual(
            fixture.layoutManager.bandRanges(in: fixture.whole), [band],
            "the second section starts at the rule's line (the break line is first in its section)")
    }

    func testED10_threeRulesBandEverySecondSection() throws {
        let fixture = makeFixture()
        fixture.show(threeRules)
        let dash = fixture.range(of: "---")
        let spaced = fixture.range(of: "* * *")
        let under = fixture.range(of: "___")
        XCTAssertEqual(fixture.layoutManager.allRules, [dash, spaced, under])
        XCTAssertEqual(fixture.layoutManager.sectionStarts, [0, dash.location, spaced.location, under.location])
        let second = NSRange(location: dash.location, length: spaced.location - dash.location)
        let fourth = NSRange(location: under.location, length: fixture.storage.length - under.location)
        XCTAssertEqual(
            fixture.layoutManager.bandRanges(in: fixture.whole), [second, fourth],
            "the second and fourth sections are filled; the first and third are not")

        // Only the bands that cross the asked range, whole.
        XCTAssertEqual(fixture.layoutManager.bandRanges(in: fixture.line(at: 0)), [])
        XCTAssertEqual(fixture.layoutManager.bandRanges(in: fixture.line(at: spaced.location)), [])
        XCTAssertEqual(fixture.layoutManager.bandRanges(in: NSRange(location: dash.location + 1, length: 1)), [second])
        XCTAssertEqual(fixture.layoutManager.bandRanges(in: fixture.line(at: fixture.storage.length - 1)), [fourth])
        XCTAssertEqual(fixture.layoutManager.bandRanges(in: NSRange(location: 0, length: 0)), [])
        XCTAssertEqual(fixture.layoutManager.bandRanges(in: fixture.whole).count, 2)
    }

    func testED10_aRuleAtDocumentStartOpensTheFirstUnfilledSection() throws {
        let fixture = makeFixture()
        fixture.show("***\n\nThe first section starts with its rule.\n\n---\n\nThe second section.\n")
        let star = fixture.range(of: "***")
        let dash = fixture.range(of: "---")
        XCTAssertEqual(star.location, 0)
        XCTAssertEqual(fixture.layoutManager.allRules, [star, dash])
        XCTAssertEqual(
            fixture.layoutManager.sectionStarts, [0, dash.location],
            "there is no empty section before a rule on line one: its line is the first line of the first section")
        XCTAssertEqual(
            fixture.layoutManager.bandRanges(in: fixture.whole),
            [NSRange(location: dash.location, length: fixture.storage.length - dash.location)],
            "so the first section stays on the text background and the second is banded")
    }

    // MARK: - ED-10: band geometry

    /// Three `---` rules, so every band edge sits on hyphens the test can measure.
    private let dashRules = """
        The first section, on the text background.

        ---

        The second section, on the band.

        ---

        The third section, on the text background again.

        ---

        The fourth section, on the band, to the end of the text.

        """

    func testED10_bandEdgeAtHyphenMidline() throws {
        for size: CGFloat in [EditorFontPreference.defaultSize, 9, 18, 30] {
            EditorFontPreference.setSize(size)
            let fixture = makeFixture()
            // Mid-document: the band runs from one rule's hyphen midline to the next's.
            fixture.show(dashRules)
            let font = try XCTUnwrap(
                fixture.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, "\(size)")
            XCTAssertEqual(font.pointSize, size, accuracy: 0.01, "the editor follows the size preference")
            let rules = (0..<3).map { fixture.range(of: "---", occurrence: $0) }
            XCTAssertEqual(fixture.layoutManager.allRules, rules)
            let rects = try fixture.bandRects(in: fixture.whole)
            XCTAssertEqual(rects.count, 2, "\(size)")
            let second = try XCTUnwrap(rects.first)
            let fourth = try XCTUnwrap(rects.last)
            for (index, rule) in rules.enumerated() {
                let midline = try fixture.inkMidline(of: rule)
                XCTAssertEqual(
                    fixture.layoutManager.hyphenMidline(of: rule), midline, accuracy: 0.01, "rule \(index), \(size)")
                XCTAssertGreaterThan(midline, fixture.lineTop(at: rule.location), "inside the rule's line")
                XCTAssertLessThan(midline, fixture.lineBottom(at: rule.location), "inside the rule's line")
            }
            XCTAssertEqual(second.minY, try fixture.inkMidline(of: rules[0]), accuracy: 0.01, "\(size)")
            XCTAssertEqual(second.maxY, try fixture.inkMidline(of: rules[1]), accuracy: 0.01, "\(size)")
            XCTAssertEqual(fourth.minY, try fixture.inkMidline(of: rules[2]), accuracy: 0.01, "\(size)")
            XCTAssertEqual(fourth.maxY, fixture.layoutManager.extraLineFragmentRect.maxY, accuracy: 0.01)

            // Drawn from a rule's line only: the half above the midline belongs to the section
            // before (the band ending there), the half below to the one after.
            let upper = try XCTUnwrap(try fixture.bandRects(in: fixture.line(at: rules[1].location)).first)
            XCTAssertEqual(upper.minY, fixture.lineTop(at: rules[1].location), accuracy: 0.01)
            XCTAssertEqual(upper.maxY, try fixture.inkMidline(of: rules[1]), accuracy: 0.01)
            XCTAssertEqual(try fixture.bandRects(in: fixture.line(at: rules[1].location)).count, 1)
            let lower = try XCTUnwrap(try fixture.bandRects(in: fixture.line(at: rules[2].location)).first)
            XCTAssertEqual(lower.minY, try fixture.inkMidline(of: rules[2]), accuracy: 0.01)
            XCTAssertEqual(lower.maxY, fixture.lineBottom(at: rules[2].location), accuracy: 0.01)

            // The bitmap: the row just above each opening midline is clear and the row just
            // below is filled; the other way round where a band closes.
            let whole = fixture.layoutManager.glyphRange(forCharacterRange: fixture.whole, actualCharacterRange: nil)
            let rep = try drawBackground(whole, with: fixture)
            for (index, opens) in [(0, true), (1, false), (2, true)] {
                let midline = try fixture.inkMidline(of: rules[index])
                let above = Int(midline.rounded(.down)) - 1
                let below = Int(midline.rounded(.up))
                for x in [0, rep.pixelsWide / 2, rep.pixelsWide - 1] {
                    XCTAssertEqual(isPainted(rep, x: x, row: above), !opens, "above rule \(index), x \(x), \(size)")
                    XCTAssertEqual(isPainted(rep, x: x, row: below), opens, "below rule \(index), x \(x), \(size)")
                }
            }
            fixture.controller.close()
        }
    }

    func testED10_bandEdgeAtHyphenMidlineNearTheDocumentStart() throws {
        let fixture = makeFixture()
        // A rule on line one opens the first, unfilled section: nothing is banded above the
        // next rule's midline, not even the half of line one below the first rule's.
        fixture.show("---\n\nThe first section starts with its rule.\n\n---\n\nThe second section.\n")
        let first = fixture.range(of: "---")
        let second = fixture.range(of: "---", occurrence: 1)
        XCTAssertEqual(first.location, 0)
        let rects = try fixture.bandRects(in: fixture.whole)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(try XCTUnwrap(rects.first).minY, try fixture.inkMidline(of: second), accuracy: 0.01)
        XCTAssertEqual(try fixture.bandRects(in: fixture.line(at: 0)), [])

        // A rule at the start of the text proper (after one empty line): its band opens at its
        // hyphens' midline, and the empty line and the rule's upper half stay clear.
        fixture.show("\n---\n\nBanded from the rule's midline.\n")
        let rule = fixture.range(of: "---")
        XCTAssertEqual(rule.location, 1)
        let band = try XCTUnwrap(try fixture.bandRects(in: fixture.whole).first)
        let midline = try fixture.inkMidline(of: rule)
        XCTAssertEqual(band.minY, midline, accuracy: 0.01)
        XCTAssertGreaterThan(band.minY, fixture.lineTop(at: rule.location))
        let whole = fixture.layoutManager.glyphRange(forCharacterRange: fixture.whole, actualCharacterRange: nil)
        let rep = try drawBackground(whole, with: fixture)
        XCTAssertFalse(isPainted(rep, x: 2, row: Int(midline.rounded(.down)) - 1))
        XCTAssertTrue(isPainted(rep, x: 2, row: Int(midline.rounded(.up))))
        XCTAssertFalse(isPainted(rep, x: 2, row: 0), "the empty first line is not banded")
    }

    func testED10_bandRunsFromTheRuleMidlineToTheNextRuleMidline() throws {
        let fixture = makeFixture()
        fixture.show(threeRules)
        let container = try XCTUnwrap(fixture.textView.textContainer)
        let dash = fixture.range(of: "---")
        let spaced = fixture.range(of: "* * *")
        let under = fixture.range(of: "___")
        let rects = try fixture.bandRects(in: fixture.whole)
        XCTAssertEqual(rects.count, 2)
        let second = try XCTUnwrap(rects.first)
        let fourth = try XCTUnwrap(rects.last)

        XCTAssertEqual(second.minY, try fixture.inkMidline(of: dash), accuracy: 0.01, "from the rule's midline")
        // A `* * *` or `___` rule's boundary is the midline of the hyphens drawn beside it.
        XCTAssertEqual(
            second.maxY, fixture.layoutManager.hyphenMidline(of: spaced), accuracy: 0.01, "to the next rule's")
        XCTAssertEqual(fourth.minY, fixture.layoutManager.hyphenMidline(of: under), accuracy: 0.01)
        for rule in [spaced, under] {
            let midline = fixture.layoutManager.hyphenMidline(of: rule)
            XCTAssertGreaterThan(midline, fixture.lineTop(at: rule.location))
            XCTAssertLessThan(midline, fixture.lineBottom(at: rule.location))
        }
        // The text ends with a line break, so the empty last line is part of the last section.
        let extra = fixture.layoutManager.extraLineFragmentRect
        XCTAssertGreaterThan(extra.height, 0, "a final line break leaves an empty last line")
        XCTAssertEqual(fourth.maxY, extra.maxY, accuracy: 0.01, "to the bottom of the text, empty last line included")
        XCTAssertGreaterThan(fourth.maxY, fixture.lineBottom(at: fixture.storage.length - 1))
        for rect in rects {
            XCTAssertEqual(rect.minX, 0, accuracy: 0.01)
            XCTAssertEqual(rect.width, container.size.width, accuracy: 0.01, "the container's width; drawing widens it")
        }
        // The two bands do not touch: the third section lies between them.
        XCTAssertLessThan(second.maxY, fourth.minY)
    }

    func testED10_bandRectsCoverTheDrawnLinesOnly() throws {
        let fixture = makeFixture()
        fixture.show(threeRules)
        let dash = fixture.range(of: "---")
        let spaced = fixture.range(of: "* * *")
        let secondProse = fixture.range(of: "The second section")
        let thirdProse = fixture.range(of: "The third section")

        // The first line only, as when the rest is scrolled out of view: no band is drawn.
        XCTAssertEqual(try fixture.bandRects(in: fixture.line(at: 0)), [])
        // A line in the middle of the band: the rect is clipped to that line, so no line
        // outside the drawn range is laid out or painted.
        let middle = fixture.line(at: secondProse.location)
        let clipped = try XCTUnwrap(try fixture.bandRects(in: middle).first)
        XCTAssertEqual(clipped.minY, fixture.lineTop(at: secondProse.location), accuracy: 0.01)
        XCTAssertEqual(clipped.maxY, fixture.lineBottom(at: secondProse.location), accuracy: 0.01)
        XCTAssertGreaterThan(clipped.minY, fixture.lineTop(at: dash.location), "not from the rule's line")
        // From the middle of the band into the third section: the band stops at the rule.
        let across = NSRange(location: secondProse.location, length: thirdProse.location - secondProse.location)
        let stopped = try XCTUnwrap(try fixture.bandRects(in: across).first)
        XCTAssertEqual(stopped.minY, fixture.lineTop(at: secondProse.location), accuracy: 0.01)
        XCTAssertEqual(stopped.maxY, fixture.layoutManager.hyphenMidline(of: spaced), accuracy: 0.01)
        XCTAssertEqual(try fixture.bandRects(in: across).count, 1, "the third section is not filled")
        XCTAssertEqual(try fixture.bandRects(in: NSRange(location: 0, length: 0)), [])
    }

    // MARK: - ED-10: drawing

    /// Draws the bands for `glyphs` through the layout manager's `drawBands`, as the text
    /// view's background pass does, into a transparent bitmap the size of the text container,
    /// flipped as the text view is, and returns the bitmap.
    private func drawBackground(_ glyphs: NSRange, with fixture: Fixture) throws -> NSBitmapImageRep {
        let container = try XCTUnwrap(fixture.textView.textContainer)
        let used = fixture.layoutManager.usedRect(for: container)
        let width = Int(container.size.width.rounded(.up))
        let height = Int(max(used.maxY, fixture.layoutManager.extraLineFragmentRect.maxY).rounded(.up)) + 1
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
        fixture.layoutManager.drawBands(forGlyphRange: glyphs, at: .zero, fromX: 0, toX: container.size.width)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Whether the pixel at `x`, on the row through the middle of the line holding
    /// `location`, is painted at all.
    private func isPainted(_ rep: NSBitmapImageRep, x: CGFloat, atLineOf location: Int, in fixture: Fixture) -> Bool {
        let y = Int(((fixture.lineTop(at: location) + fixture.lineBottom(at: location)) / 2).rounded(.down))
        return isPainted(rep, x: Int(x.rounded(.down)), row: y)
    }

    /// Whether the pixel at column `x`, row `row` (the flipped bitmap's, one per point) is
    /// painted at all.
    private func isPainted(_ rep: NSBitmapImageRep, x: Int, row: Int) -> Bool {
        guard x >= 0, x < rep.pixelsWide, row >= 0, row < rep.pixelsHigh else { return false }
        guard let color = rep.colorAt(x: x, y: row) else { return false }
        return color.alphaComponent > 0.005
    }

    func testED10_bandsArePaintedAcrossTheWidthOfFilledSectionsOnly() throws {
        let fixture = makeFixture()
        fixture.show(threeRules)
        let layoutManager = fixture.layoutManager
        let whole = layoutManager.glyphRange(forCharacterRange: fixture.whole, actualCharacterRange: nil)
        let rep = try drawBackground(whole, with: fixture)
        let width = CGFloat(rep.pixelsWide)
        let columns: [CGFloat] = [0, 1, width / 2, width - 2]
        let filled = [
            fixture.range(of: "The second section").location, fixture.range(of: "The fourth section").location,
        ]
        let clear = [
            0, fixture.range(of: "The first section").location, fixture.range(of: "The third section").location,
        ]
        // A rule's line is split at its hyphens' midline: above it the section before, below
        // it the rule's own section.
        for (rule, opens) in [("---", true), ("* * *", false), ("___", true)] {
            let midline = fixture.layoutManager.hyphenMidline(of: fixture.range(of: rule))
            for x in columns {
                let column = Int(x.rounded(.down))
                XCTAssertEqual(isPainted(rep, x: column, row: Int(midline.rounded(.down)) - 1), !opens, "\(rule) \(x)")
                XCTAssertEqual(isPainted(rep, x: column, row: Int(midline.rounded(.up))), opens, "\(rule) \(x)")
            }
        }
        for location in filled {
            for x in columns {
                XCTAssertTrue(isPainted(rep, x: x, atLineOf: location, in: fixture), "band at x \(x), \(location)")
            }
        }
        for location in clear {
            for x in columns {
                XCTAssertFalse(isPainted(rep, x: x, atLineOf: location, in: fixture), "clear at x \(x), \(location)")
            }
        }
        // The band's colour is the system fill, resolved for the bitmap's appearance: faint,
        // never opaque.
        let sample = try XCTUnwrap(
            rep.colorAt(
                x: 2,
                y: Int(
                    ((fixture.lineTop(at: filled[1]) + fixture.lineBottom(at: filled[1])) / 2).rounded(.down))))
        XCTAssertLessThan(sample.alphaComponent, 0.5, "a subtle fill")
        XCTAssertEqual(EditorLayoutManager.bandColor, .quaternarySystemFill)
    }

    func testED10_bandsArePaintedForTheDrawnGlyphsOnly() throws {
        let fixture = makeFixture()
        fixture.show(threeRules)
        let layoutManager = fixture.layoutManager
        let dash = fixture.range(of: "---").location
        let second = fixture.range(of: "The second section").location
        let fourth = fixture.range(of: "The fourth section").location

        // Only the first line drawn: nothing is painted anywhere.
        let firstLine = layoutManager.glyphRange(forCharacterRange: fixture.line(at: 0), actualCharacterRange: nil)
        let top = try drawBackground(firstLine, with: fixture)
        for location in [0, dash, second, fourth] {
            XCTAssertFalse(isPainted(top, x: 2, atLineOf: location, in: fixture), "\(location)")
        }
        // The second section's prose line only: its line is painted, the rule's line above it
        // and the fourth section below are not.
        let middle = layoutManager.glyphRange(forCharacterRange: fixture.line(at: second), actualCharacterRange: nil)
        let rep = try drawBackground(middle, with: fixture)
        XCTAssertTrue(isPainted(rep, x: 2, atLineOf: second, in: fixture))
        XCTAssertFalse(isPainted(rep, x: 2, atLineOf: dash, in: fixture))
        XCTAssertFalse(isPainted(rep, x: 2, atLineOf: fourth, in: fixture))
    }

    /// With a text view drawing the container, the layout manager's own clipped background
    /// pass leaves the bands to the view's pass: painting them in both would double the fill.
    func testED10_theLayoutManagerBackgroundPassLeavesTheBandsToTheViewsPass() throws {
        let fixture = makeFixture()
        fixture.show(threeRules)
        let container = try XCTUnwrap(fixture.textView.textContainer)
        XCTAssertNotNil(container.textView)
        let layoutManager = fixture.layoutManager
        let whole = layoutManager.glyphRange(forCharacterRange: fixture.whole, actualCharacterRange: nil)
        let used = layoutManager.usedRect(for: container)
        let width = Int(container.size.width.rounded(.up))
        let height = Int(max(used.maxY, layoutManager.extraLineFragmentRect.maxY).rounded(.up)) + 1
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
        layoutManager.drawBackground(forGlyphRange: whole, at: .zero)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let banded = fixture.range(of: "The second section").location
        XCTAssertFalse(
            isPainted(rep, x: 2, atLineOf: banded, in: fixture), "the view's background pass paints the band")
    }

    // MARK: - ED-10: the real view's draw pass

    /// Renders the real text view, as the window does, into a bitmap the size of its bounds
    /// through `cacheDisplay`, so every clip `NSTextView`'s own draw pass applies is in force.
    private func renderTextView(with fixture: Fixture) throws -> NSBitmapImageRep {
        let view = fixture.textView
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The pixel of `rep` (the whole view) at column `column` on the row through the middle
    /// of the line holding `location`, the view's coordinates scaled to the bitmap's.
    private func pixel(_ rep: NSBitmapImageRep, column: Int, atLineOf location: Int, in fixture: Fixture) throws
        -> NSColor
    {
        let view = fixture.textView
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        let middle =
            (fixture.lineTop(at: location) + fixture.lineBottom(at: location)) / 2 + view.textContainerInset.height
        let row = Int((middle * scale).rounded(.down))
        let color = try XCTUnwrap(rep.colorAt(x: column, y: row), "pixel \(column), \(row)")
        return try XCTUnwrap(color.usingColorSpace(.deviceRGB))
    }

    /// True when the two colours are the same to the bitmap's precision.
    private func same(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.004 && abs(a.greenComponent - b.greenComponent) < 0.004
            && abs(a.blueComponent - b.blueComponent) < 0.004
    }

    func testED10_theRenderedViewIsBandedFromItsFirstColumnToItsLast() throws {
        let fixture = makeFixture()
        fixture.show(threeRules)
        let view = fixture.textView
        XCTAssertEqual(view.textContainerInset.width, 8, "the margins the band must cover")
        XCTAssertEqual(view.bounds.minX, 0)
        let rep = try renderTextView(with: fixture)
        let first = 0
        let last = rep.pixelsWide - 1
        let middle = rep.pixelsWide / 2
        let banded = fixture.range(of: "The second section").location
        let unbanded = fixture.range(of: "The third section").location

        let bandedMiddle = try pixel(rep, column: middle, atLineOf: banded, in: fixture)
        let clearMiddle = try pixel(rep, column: middle, atLineOf: unbanded, in: fixture)
        XCTAssertFalse(same(bandedMiddle, clearMiddle), "the band shows against the text background")

        for column in [first, last] {
            let onBand = try pixel(rep, column: column, atLineOf: banded, in: fixture)
            XCTAssertTrue(same(onBand, bandedMiddle), "column \(column) of a banded line carries the band fill")
            XCTAssertFalse(same(onBand, clearMiddle), "column \(column) of a banded line is not the text background")
            let offBand = try pixel(rep, column: column, atLineOf: unbanded, in: fixture)
            XCTAssertTrue(same(offBand, clearMiddle), "column \(column) of an unbanded line is the text background")
        }
        // The rule's own line is banded below its hyphens' midline and not above, edge to edge.
        let midline = fixture.layoutManager.hyphenMidline(of: fixture.range(of: "___"))
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        let inset = view.textContainerInset.height
        let rowAbove = Int(((midline + inset) * scale).rounded(.down)) - 1
        let rowBelow = Int(((midline + inset) * scale).rounded(.up))
        for column in [first, last] {
            let above = try XCTUnwrap(rep.colorAt(x: column, y: rowAbove)?.usingColorSpace(.deviceRGB))
            let below = try XCTUnwrap(rep.colorAt(x: column, y: rowBelow)?.usingColorSpace(.deviceRGB))
            XCTAssertTrue(same(below, bandedMiddle), "below the midline, column \(column)")
            XCTAssertTrue(same(above, clearMiddle), "above the midline, column \(column)")
        }
    }

    // MARK: - ED-10, E-3: edits

    func testED10_ruleListAndBandsFollowEdits() throws {
        let fixture = makeFixture()
        fixture.show("A paragraph.\n\n\nMore prose.\n\n---\n\nThe last section.\n")
        let layoutManager = fixture.layoutManager
        let last = fixture.range(of: "---")
        XCTAssertEqual(layoutManager.allRules, [last], "read once, then kept current")
        XCTAssertEqual(layoutManager.bandRanges(in: fixture.whole).count, 1)

        // A rule typed hyphen by hyphen on the blank line: the third hyphen makes it a rule,
        // the rule after it moves along, and the sections after it swap sides.
        let blank = fixture.range(of: "\n\n\n").location + 2
        fixture.type("-", at: blank)
        fixture.type("-", at: blank + 1)
        XCTAssertEqual(layoutManager.allRules, fixture.rulesReadAfresh)
        XCTAssertEqual(layoutManager.allRules, [NSRange(location: last.location + 2, length: 3)], "not yet a rule")
        fixture.type("-", at: blank + 2)
        let typed = NSRange(location: blank, length: 3)
        let moved = NSRange(location: last.location + 3, length: 3)
        XCTAssertEqual(layoutManager.allRules, [typed, moved])
        XCTAssertEqual(layoutManager.allRules, fixture.rulesReadAfresh)
        XCTAssertEqual(layoutManager.sectionStarts, [0, typed.location, moved.location])
        XCTAssertEqual(
            layoutManager.bandRanges(in: fixture.whole),
            [NSRange(location: typed.location, length: moved.location - typed.location)],
            "the typed rule's section is banded and the last section, now third, is not")

        // Prose after the hyphens makes the line a paragraph again. The undo manager groups
        // by run-loop turn, so one passes first to close the hyphens' group.
        fixture.textView.breakUndoCoalescing()
        RunLoop.main.run(until: Date())
        fixture.type(" and text", at: typed.location + 3)
        XCTAssertEqual(layoutManager.allRules, fixture.rulesReadAfresh)
        XCTAssertEqual(layoutManager.allRules, [NSRange(location: moved.location + 9, length: 3)])
        XCTAssertEqual(layoutManager.bandRanges(in: fixture.whole).count, 1)

        // Undo brings the rule and its band back (E-7).
        fixture.textView.breakUndoCoalescing()
        fixture.textView.undoManager?.undo()
        XCTAssertEqual(layoutManager.allRules, fixture.rulesReadAfresh)
        XCTAssertEqual(layoutManager.allRules, [typed, moved])

        // Deleting the blank line before the last rule puts `---` directly under text: a
        // setext underline (ED-9), not a rule, so its band goes although its own line was
        // never edited.
        fixture.type("", at: moved.location - 1, replacing: 1)
        XCTAssertEqual(layoutManager.allRules, fixture.rulesReadAfresh)
        XCTAssertEqual(layoutManager.allRules, [typed])
        XCTAssertEqual(
            layoutManager.bandRanges(in: fixture.whole),
            [NSRange(location: typed.location, length: fixture.storage.length - typed.location)])

        // Replacing the whole text, as a load does, starts the list afresh.
        fixture.show(threeRules)
        XCTAssertEqual(layoutManager.allRules, fixture.rulesReadAfresh)
        XCTAssertEqual(layoutManager.allRules.count, 3)
        XCTAssertEqual(layoutManager.bandRanges(in: fixture.whole).count, 2)
    }

    func testED10_theTextIsUntouched() throws {
        let fixture = makeFixture()
        fixture.show(threeRules)
        XCTAssertEqual(fixture.textView.string, threeRules, "bands are drawn, never inserted (E-1)")
        XCTAssertEqual(fixture.storage.length, (threeRules as NSString).length)
        XCTAssertEqual(fixture.controller.editorController.text, threeRules)
    }

    // MARK: - V-1

    func testV1_editorSnapshotShowsSectionBands() throws {
        let fixture = makeFixture()
        fixture.show(
            """
            # Sections

            The first section sits on the text background. It runs from the top of the note to the line of the first rule.

            ---

            The second section is banded: a subtle system fill from the middle of the rule's hyphens to the middle of the next rule's, across the whole editor width, margins included.

            - A list item in the band
            - Another

            * * *

            The third section is back on the text background.

            ___

            The fourth section is banded to the bottom of the text.

            """)
        fixture.controller.mainView.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.layoutManager.allRules.count, 3)
        XCTAssertEqual(fixture.layoutManager.bandRanges(in: fixture.whole).count, 2)
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-bands")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }
}
