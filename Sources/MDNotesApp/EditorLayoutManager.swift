import AppKit
import Foundation

/// The editor's layout manager (ED-8, ED-10, ADR-0019): TextKit 1's `NSLayoutManager` with
/// the drawing the halfway editor adds on top of the text. The text itself is never touched:
/// everything here is painted while the glyphs and their background are drawn, over the
/// visible rect only, so the file, the storage, the selection, copy, undo and search stay
/// exactly what the typed characters are (E-1, E-2).
///
/// A thematic break is typed as `---`, `* * *` or `___` (ED-8) and the styler marks those
/// characters with `EditorStyler.TokenStyle.rule`. When a line carrying that mark is drawn,
/// hyphens in `extensionColor` (quaternary label colour, fainter than the typed rule's
/// secondary, ED-2) are painted from the editor view's leading edge to the typed rule's first
/// glyph and from its last glyph to the view's trailing edge, margins included, in the rule's
/// own font and on its baseline, so the typed characters read as part of a rule that runs the
/// width of the editor. `EditorTextView` asks `drawRuleExtensions` for them from its own
/// background pass, as it does the bands, because `NSTextView` clips the layout manager's
/// glyph pass to the text container and the hyphens must reach past the `textContainerInset`
/// to the view's edges. The hyphens are not text: they are not in the
/// storage, so there is nothing there to select, copy or move the caret onto, and a click on
/// them lands the caret at the rule's end as a click past any line's end does. They are drawn
/// only for the glyph range the text view asks for, which is the visible rect, and vanish
/// with the mark when an edit makes the line no longer a rule (E-3 re-styles it).
///
/// The rules also divide the text into sections, which alternate backgrounds (ED-10): the
/// first section on the text background, the second on `bandColor`, and so on. A rule's line
/// is the first line of its section. Before the glyphs are drawn, every filled section that
/// crosses them is painted as a band from the vertical centre of its rule's drawn hyphens to
/// the centre of the next rule's (the bottom of the text for the last, which `EditorTextView`
/// continues to its own bottom, ADR-0022), across the full width of the editor including its
/// margins: `EditorTextView` asks `drawBands` for them from its own
/// background pass, because `NSTextView` clips the layout manager's background pass to the
/// text container and the band must reach past the `textContainerInset` to the view's edges.
/// Which sections are filled is a matter of counting the rules
/// before them, so the layout manager keeps every rule of the storage in a list that each
/// edit updates for the lines it touched (reading the whole storage's attribute runs on every
/// keystroke would not fit a 1 MB note's redraw budget, PF-3), and an edit that adds or
/// removes a rule redraws the view, since the sections after it change sides.
///
/// Layout is non-contiguous: a keystroke near the top of a large note invalidates the layout
/// below it, and the text view then needs the document's height, which contiguous layout
/// would compute by laying out every line to the end before the redraw (PF-3). Estimated
/// heights and background layout are how `NSTextView` handles large documents under TextKit 1.
public final class EditorLayoutManager: NSLayoutManager {
    /// The rule extension's colour (ED-8, ADR-0021): quaternary label colour, so the typed
    /// rule (secondary, ED-2) reads darker than the faded hyphens that continue it.
    nonisolated public static let extensionColor: NSColor = .quaternaryLabelColor

    /// The character the extension is made of.
    nonisolated public static let extensionCharacter = "-"

    /// The band fill (ED-10): the faintest of the system fills, a few per cent of the label
    /// colour over the text background, resolving with the appearance. A semantic colour, as
    /// every colour in the window is (W-6, E-8).
    nonisolated public static let bandColor: NSColor = .quaternarySystemFill

    /// Where a typed rule's extension is painted, in its text container's coordinates.
    public struct RuleExtension: Equatable, Sendable {
        /// The typed rule, as storage characters.
        public let rule: NSRange
        /// From the end of the rule's last glyph to the container's trailing edge (its width
        /// less the line fragment padding), as tall as the rule's last line fragment. The
        /// drawing widens it to the view's trailing edge.
        public let rect: NSRect
        /// The y of the rule's baseline, which the hyphens sit on.
        public let baseline: CGFloat
        /// From the container's leading edge to the start of the rule's first glyph, as tall
        /// as the rule's first line fragment. The drawing widens it to the view's leading edge.
        public let leading: NSRect
        /// The y of the baseline of the rule's first line (the same as `baseline` unless the
        /// rule wraps).
        public let leadingBaseline: CGFloat

        public init(
            rule: NSRange, rect: NSRect, baseline: CGFloat, leading: NSRect = .zero, leadingBaseline: CGFloat = 0
        ) {
            self.rule = rule
            self.rect = rect
            self.baseline = baseline
            self.leading = leading
            self.leadingBaseline = leadingBaseline
        }
    }

    /// Every typed rule in the storage, in text order, or nil before anyone has asked. Once
    /// made it is kept current by `processEditing`, which re-reads only the edited lines.
    private var cachedRules: [NSRange]?

    public override init() {
        super.init()
        allowsNonContiguousLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Rules (ED-8)

    /// The typed rules (storage ranges carrying the `.rule` token style) that intersect
    /// `characterRange`, in text order. Reads the attribute over that range only.
    public func ruleRanges(in characterRange: NSRange) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        let range = NSIntersectionRange(characterRange, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return [] }
        var rules: [NSRange] = []
        storage.enumerateAttribute(EditorStyler.tokenAttribute, in: range, options: []) { value, run, _ in
            guard value as? String == EditorStyler.TokenStyle.rule.rawValue else { return }
            // A run may be clipped by `range`; the rule is the whole run the attribute covers.
            var whole = NSRange()
            _ = storage.attribute(EditorStyler.tokenAttribute, at: run.location, effectiveRange: &whole)
            if rules.last != whole { rules.append(whole) }
        }
        return rules
    }

    /// Every typed rule in the storage, in text order (ED-10). Read from the whole storage the
    /// first time, then kept in step with every edit by `processEditing`.
    public var allRules: [NSRange] {
        if let cachedRules { return cachedRules }
        let rules = ruleRanges(in: NSRange(location: 0, length: textStorage?.length ?? 0))
        cachedRules = rules
        return rules
    }

    /// Keeps `allRules` current: the rules before the edited lines stay, those after move by
    /// the change in length, and the edited lines (the edit and everything attribute fixing
    /// and the styler's re-style touched, widened to whole lines) are read again. When those
    /// lines gained or lost a rule, every section after them changes sides, which the edit's
    /// own invalidation does not redraw, so the whole view is marked for display; that costs
    /// a redraw of the visible rect, no layout.
    public override func processEditing(
        for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions, range newCharRange: NSRange,
        changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange
    ) {
        super.processEditing(
            for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta,
            invalidatedRange: invalidatedCharRange)
        // The storage is edited on the main thread only (it belongs to a view), so the text
        // views it lays out are reachable here.
        let views = textContainers.compactMap(\.textView)
        if let old = cachedRules {
            let scan = textStorage.mutableString.lineRange(for: NSUnionRange(newCharRange, invalidatedCharRange))
            // The scanned lines' end, as it was before the edit: the text after it only moved.
            let scanEndBefore = NSMaxRange(scan) - delta
            let before = old.prefix { $0.location < scan.location }
            let after = old.drop { $0.location < scanEndBefore }
                .map { NSRange(location: $0.location + delta, length: $0.length) }
            let rescanned = ruleRanges(in: scan)
            cachedRules = Array(before) + rescanned + after
            if old.count - before.count - after.count != rescanned.count {
                MainActor.assumeIsolated { for view in views { view.needsDisplay = true } }
            }
        }
        // Whether the last section is filled may have changed, and with it the colour of the
        // scroll view's clip view under the text (ADR-0022).
        MainActor.assumeIsolated {
            for case let view as EditorTextView in views { view.updateFinalBandBackground() }
        }
    }

    /// The extension of the typed rule at `rule` (a storage range), or nil when that range is
    /// not exactly a rule (the `.rule` run the styler marked) or is not laid out in
    /// `container`. The trailing rect starts where the rule's last glyph ends on the line that
    /// holds it (a rule long enough to wrap extends from its last line) and ends at the
    /// container's trailing edge (empty when the line is full); the leading rect runs from the
    /// container's leading edge to where the rule's first glyph starts.
    public func ruleExtension(for rule: NSRange, in container: NSTextContainer) -> RuleExtension? {
        guard ruleRanges(in: rule) == [rule] else { return nil }
        let glyphs = glyphRange(forCharacterRange: rule, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let last = NSMaxRange(glyphs) - 1
        guard textContainer(forGlyphAt: last, effectiveRange: nil) === container,
            textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) === container
        else { return nil }
        var fragmentGlyphs = NSRange()
        let fragment = lineFragmentRect(forGlyphAt: last, effectiveRange: &fragmentGlyphs)
        let tail = NSIntersectionRange(glyphs, fragmentGlyphs)
        guard tail.length > 0 else { return nil }
        let start = boundingRect(forGlyphRange: tail, in: container).maxX
        let end = max(start, fragment.maxX - container.lineFragmentPadding)
        let rect = NSRect(x: start, y: fragment.minY, width: end - start, height: fragment.height)
        let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let firstGlyph = location(forGlyphAt: glyphs.location)
        let leading = NSRect(x: 0, y: first.minY, width: max(0, first.minX + firstGlyph.x), height: first.height)
        return RuleExtension(
            rule: rule, rect: rect, baseline: fragment.minY + location(forGlyphAt: last).y, leading: leading,
            leadingBaseline: first.minY + firstGlyph.y)
    }

    // MARK: - Sections (ED-10)

    /// Where each section starts: character 0, then the first character of every rule's line,
    /// since a break line is the first line of its section. A rule on the document's first
    /// line starts the first section rather than a second one: the sections are the runs of
    /// lines the rules divide the text into, and the first line is always in the first of
    /// them, which is the one on the text background.
    public var sectionStarts: [Int] {
        guard let storage = textStorage else { return [] }
        let string = storage.mutableString
        var starts = [0]
        for rule in allRules {
            let line = string.lineRange(for: rule).location
            if line > starts[starts.count - 1] { starts.append(line) }
        }
        return starts
    }

    /// Whether the last section is filled (ED-10, ADR-0022): the sections alternate from an
    /// unfilled first, so it is when there is an even number of them, which is one more than
    /// the rules, less one when a rule is on the first line (it opens the first section).
    public var lastSectionIsFilled: Bool {
        let rules = allRules
        guard let first = rules.first, let storage = textStorage else { return false }
        let openers = storage.mutableString.lineRange(for: first).location == 0 ? rules.count - 1 : rules.count
        return openers % 2 == 1
    }

    /// The bottom of the text in `container`'s coordinates: the bottom of the last line
    /// fragment, or of the empty last line after a final line break when the container holds
    /// it. The last band ends here (ED-10), and when the last section is filled the text view
    /// fills on from here to its own bottom (ADR-0022). Lays out the end of the text; zero for
    /// an empty text.
    public func textBottom(in container: NSTextContainer) -> CGFloat {
        let length = textStorage?.length ?? 0
        guard length > 0 else { return 0 }
        let lastLine = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
        guard extraLineFragmentTextContainer === container else { return lastLine.maxY }
        return max(lastLine.maxY, extraLineFragmentRect.maxY)
    }

    /// The character ranges of the filled sections (every second one, the first unfilled)
    /// that intersect `characterRange`, whole, in text order. A section runs from its first
    /// character to the next section's first character, or the end of the storage.
    public func bandRanges(in characterRange: NSRange) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        let starts = sectionStarts
        var bands: [NSRange] = []
        for index in stride(from: 1, to: starts.count, by: 2) {
            let end = index + 1 < starts.count ? starts[index + 1] : storage.length
            let band = NSRange(location: starts[index], length: end - starts[index])
            if NSIntersectionRange(band, characterRange).length > 0 { bands.append(band) }
        }
        return bands
    }

    /// The rects, in `container`'s coordinates, of the bands that cross the lines holding
    /// `characterRange`, clipped to those lines so no line outside them is laid out. A band
    /// runs from the vertical centre of its rule's drawn hyphens (`hyphenMidline(of:)`) to the
    /// centre of the next rule's, or to the bottom of the text (the empty last line after a
    /// final line break included) for the last section, so the upper half of a rule's line
    /// belongs to the section before it. A band whose rule line is not drawn starts at the top
    /// of the first drawn line; one whose next rule line is not drawn stops at the bottom of
    /// the last. Each rect spans the container's width; the drawing widens it to the editor's.
    public func bandRects(in characterRange: NSRange, in container: NSTextContainer) -> [NSRect] {
        guard let storage = textStorage else { return [] }
        let length = storage.length
        let drawn = NSIntersectionRange(characterRange, NSRange(location: 0, length: length))
        guard drawn.length > 0 else { return [] }
        let drawnEnd = NSMaxRange(drawn)
        let string = storage.mutableString
        // A band that ends where the first drawn line starts still reaches down to the middle
        // of that line, its next rule's, so the character before the line is asked for too.
        let firstLine = string.lineRange(for: NSRange(location: drawn.location, length: 0)).location
        let asked = NSRange(location: max(0, firstLine - 1), length: drawnEnd - max(0, firstLine - 1))
        let drawnTop = lineFragmentRect(
            forGlyphAt: glyphIndexForCharacter(at: drawn.location), effectiveRange: nil
        ).minY
        return bandRanges(in: asked).compactMap { band in
            let ruleLineEnd = NSMaxRange(string.lineRange(for: NSRange(location: band.location, length: 0)))
            let top: CGFloat
            if drawn.location < ruleLineEnd, let rule = rule(onLineStartingAt: band.location) {
                top = hyphenMidline(of: rule)
            } else {
                top = drawnTop
            }
            let bandEnd = NSMaxRange(band)
            let bottom: CGFloat
            if bandEnd < drawnEnd, let next = rule(onLineStartingAt: bandEnd) {
                // The next section's rule line is drawn too: the band stops at its midline.
                bottom = hyphenMidline(of: next)
            } else if bandEnd == length, drawnEnd == length {
                bottom = textBottom(in: container)
            } else {
                bottom =
                    lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: drawnEnd - 1), effectiveRange: nil).maxY
            }
            guard bottom > top else { return nil }
            return NSRect(x: 0, y: top, width: container.size.width, height: bottom - top)
        }
    }

    /// The typed rule on the line that starts at `lineStart` (a section start), found by a
    /// binary search of `allRules`: the first rule at or after the line's start is on it.
    private func rule(onLineStartingAt lineStart: Int) -> NSRange? {
        let rules = allRules
        var low = 0
        var high = rules.count
        while low < high {
            let mid = (low + high) / 2
            if rules[mid].location < lineStart { low = mid + 1 } else { high = mid }
        }
        return low < rules.count ? rules[low] : nil
    }

    /// The y, in container coordinates, of the vertical centre of the hyphens drawn for
    /// `rule` (ED-10, ADR-0021): the middle of a hyphen's ink in the rule's font, on the
    /// baseline of the rule's first line, which is where the typed `---` and the extension's
    /// hyphens sit. A `* * *` or `___` rule has the same midline as a `---` would, since its
    /// extension is hyphens too.
    public func hyphenMidline(of rule: NSRange) -> CGFloat {
        let glyph = glyphIndexForCharacter(at: rule.location)
        let baseline = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + location(forGlyphAt: glyph).y
        let font =
            textStorage?.attribute(.font, at: rule.location, effectiveRange: nil) as? NSFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return baseline - Self.hyphenInkMiddle(in: font)
    }

    /// How far above the baseline the middle of `font`'s hyphen ink lies.
    private static func hyphenInkMiddle(in font: NSFont) -> CGFloat {
        var character = UniChar(0x2D)
        var glyph = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return font.xHeight / 2 }
        return font.boundingRect(forCGGlyph: glyph).midY
    }

    // MARK: - Drawing

    /// Paints the bands of the filled sections among `glyphsToShow` (ED-10) in `bandColor`,
    /// each from `minX` to `maxX` horizontally (the editor's edges, margins included) and over
    /// its lines vertically, the container's origin at `origin`. `glyphsToShow` is what the
    /// text view's dirty rect covers, so only the visible lines are looked at. `EditorTextView`
    /// calls this from its own background pass: `NSTextView` clips the layout manager's
    /// `drawBackground` to the text container, which would stop the band at the
    /// `textContainerInset`, but paints its view background unclipped, so the bands go over
    /// that background, before the text's own background and the selection.
    public func drawBands(
        forGlyphRange glyphsToShow: NSRange, at origin: NSPoint, fromX minX: CGFloat, toX maxX: CGFloat
    ) {
        guard glyphsToShow.length > 0, textStorage != nil, maxX > minX,
            let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil)
        else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        Self.bandColor.setFill()
        for rect in bandRects(in: characters, in: container) {
            NSRect(x: minX, y: rect.minY + origin.y, width: maxX - minX, height: rect.height).fill(using: .sourceOver)
        }
    }

    /// The background as `NSLayoutManager` draws it, with the bands (ED-10) first when the
    /// container is drawn by no text view (a bare layout manager drawing into a bitmap), each
    /// spanning the container. With a text view the bands are its background pass's, through
    /// `drawBands`, since this pass is clipped to the container and the bands must reach the
    /// view's edges; painting them here too would double the fill.
    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if glyphsToShow.length > 0, textStorage != nil,
            let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil),
            container.textView == nil
        {
            drawBands(forGlyphRange: glyphsToShow, at: origin, fromX: origin.x, toX: origin.x + container.size.width)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Paints the extension of every rule among `glyphsToShow` (ED-8): hyphens from `minX` to
    /// the rule's first glyph and from its last glyph to `maxX` (the editor's edges, margins
    /// included), the container's origin at `origin`. `glyphsToShow` is what the text view's
    /// dirty rect covers, so nothing outside the visible rect is painted or even looked at.
    /// `EditorTextView` calls this from its own background pass, which is unclipped, since
    /// `NSTextView` clips the layout manager's glyph pass to the text container.
    public func drawRuleExtensions(
        forGlyphRange glyphsToShow: NSRange, at origin: NSPoint, fromX minX: CGFloat, toX maxX: CGFloat
    ) {
        guard glyphsToShow.length > 0, maxX > minX, let storage = textStorage,
            let context = NSGraphicsContext.current
        else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for rule in ruleRanges(in: characters) {
            guard rule.location < storage.length,
                let container = textContainer(
                    forGlyphAt: glyphIndexForCharacter(at: rule.location), effectiveRange: nil),
                let extent = ruleExtension(for: rule, in: container)
            else { continue }
            let font =
                storage.attribute(.font, at: rule.location, effectiveRange: nil) as? NSFont
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let trailingStart = extent.rect.minX + origin.x
            let trailing = NSRect(
                x: trailingStart, y: extent.rect.minY + origin.y, width: maxX - trailingStart,
                height: extent.rect.height)
            Self.drawHyphens(in: trailing, baseline: extent.baseline + origin.y, from: .start, font: font, in: context)
            let leading = NSRect(
                x: minX, y: extent.leading.minY + origin.y, width: extent.leading.maxX + origin.x - minX,
                height: extent.leading.height)
            Self.drawHyphens(
                in: leading, baseline: extent.leadingBaseline + origin.y, from: .end, font: font, in: context)
        }
    }

    /// Draws the glyphs as `NSLayoutManager` does, then, when no text view draws the container
    /// (a bare layout manager drawing into a bitmap), the rule extensions (ED-8) across the
    /// container. With a text view they are its background pass's, through
    /// `drawRuleExtensions`, since this pass is clipped to the container and the hyphens must
    /// reach the view's edges; painting them here too would draw them twice.
    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard glyphsToShow.length > 0, textStorage != nil,
            let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil),
            container.textView == nil
        else { return }
        drawRuleExtensions(
            forGlyphRange: glyphsToShow, at: origin, fromX: origin.x,
            toX: origin.x + container.size.width - container.lineFragmentPadding)
    }

    /// Which end of a rect the hyphens are laid from: the trailing extension starts at the
    /// rule's end and the leading one ends at the rule's start, so both keep the typed
    /// characters' rhythm.
    private enum Anchor { case start, end }

    /// Paints as many whole hyphens as fit `rect`, in `font` and `extensionColor`, on
    /// `baseline`, laid from `anchor` and clipped to the rect so none crosses its edges. Core
    /// Text draws them because it places text by baseline, which is what lines the hyphens up
    /// with the typed rule; the text view is flipped, so the text matrix is too.
    private static func drawHyphens(
        in rect: NSRect, baseline: CGFloat, from anchor: Anchor, font: NSFont, in context: NSGraphicsContext
    ) {
        guard rect.width > 0 else { return }
        let hyphenWidth = NSAttributedString(string: extensionCharacter, attributes: [.font: font]).size().width
        guard hyphenWidth > 0 else { return }
        let count = Int((rect.width / hyphenWidth).rounded(.down))
        guard count > 0 else { return }
        let hyphens = NSAttributedString(
            string: String(repeating: extensionCharacter, count: count),
            attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
        let line = CTLineCreateWithAttributedString(hyphens)
        let x = anchor == .start ? rect.minX : rect.maxX - CGFloat(count) * hyphenWidth
        let cg = context.cgContext
        cg.saveGState()
        cg.clip(to: rect)
        extensionColor.setFill()
        cg.textMatrix = context.isFlipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        cg.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }
}
