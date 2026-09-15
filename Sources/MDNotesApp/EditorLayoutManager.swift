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
/// hyphens in `extensionColor` (tertiary label colour, the marker colour of ED-2) are painted
/// from the end of the typed rule's last glyph to the trailing edge of its text container, in
/// the rule's own font and on its baseline, so the typed characters read as the start of a
/// rule that runs the width of the editor. The hyphens are not text: they are not in the
/// storage, so there is nothing there to select, copy or move the caret onto, and a click on
/// them lands the caret at the rule's end as a click past any line's end does. They are drawn
/// only for the glyph range the text view asks for, which is the visible rect, and vanish
/// with the mark when an edit makes the line no longer a rule (E-3 re-styles it).
///
/// The rules also divide the text into sections, which alternate backgrounds (ED-10): the
/// first section on the text background, the second on `bandColor`, and so on. A rule's line
/// is the first line of its section. Before the glyphs are drawn, every filled section that
/// crosses them is painted as a band from the top of its first line to the top of the next
/// section's first line (the bottom of the text for the last), across the full width of the
/// editor including its margins. Which sections are filled is a matter of counting the rules
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
    /// The rule extension's colour (ED-8): the marker colour, since the extension is the
    /// faded continuation of a marker.
    nonisolated public static let extensionColor: NSColor = .tertiaryLabelColor

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
        /// less the line fragment padding), as tall as the rule's last line fragment.
        public let rect: NSRect
        /// The y of the rule's baseline, which the hyphens sit on.
        public let baseline: CGFloat

        public init(rule: NSRange, rect: NSRect, baseline: CGFloat) {
            self.rule = rule
            self.rect = rect
            self.baseline = baseline
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
        guard let old = cachedRules else { return }
        let scan = textStorage.mutableString.lineRange(for: NSUnionRange(newCharRange, invalidatedCharRange))
        // The scanned lines' end, as it was before the edit: the text after it only moved.
        let scanEndBefore = NSMaxRange(scan) - delta
        let before = old.prefix { $0.location < scan.location }
        let after = old.drop { $0.location < scanEndBefore }
            .map { NSRange(location: $0.location + delta, length: $0.length) }
        let rescanned = ruleRanges(in: scan)
        cachedRules = Array(before) + rescanned + after
        if old.count - before.count - after.count != rescanned.count {
            // The storage is edited on the main thread only (it belongs to a view), so the
            // text views it lays out are reachable here.
            let views = textContainers.compactMap(\.textView)
            MainActor.assumeIsolated { for view in views { view.needsDisplay = true } }
        }
    }

    /// The extension of the typed rule at `rule` (a storage range), or nil when that range is
    /// not exactly a rule (the `.rule` run the styler marked), is not laid out in `container`,
    /// or its last line has no room after it. The rect starts where the rule's last glyph ends
    /// on the line that holds it (a rule long enough to wrap extends from its last line) and
    /// ends at the container's trailing edge.
    public func ruleExtension(for rule: NSRange, in container: NSTextContainer) -> RuleExtension? {
        guard ruleRanges(in: rule) == [rule] else { return nil }
        let glyphs = glyphRange(forCharacterRange: rule, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let last = NSMaxRange(glyphs) - 1
        guard textContainer(forGlyphAt: last, effectiveRange: nil) === container else { return nil }
        var fragmentGlyphs = NSRange()
        let fragment = lineFragmentRect(forGlyphAt: last, effectiveRange: &fragmentGlyphs)
        let tail = NSIntersectionRange(glyphs, fragmentGlyphs)
        guard tail.length > 0 else { return nil }
        let start = boundingRect(forGlyphRange: tail, in: container).maxX
        let end = fragment.maxX - container.lineFragmentPadding
        guard end > start else { return nil }
        let rect = NSRect(x: start, y: fragment.minY, width: end - start, height: fragment.height)
        return RuleExtension(rule: rule, rect: rect, baseline: fragment.minY + location(forGlyphAt: last).y)
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

    /// The rects, in `container`'s coordinates, of the bands that cross `characterRange`,
    /// clipped to the lines that hold `characterRange` so no line outside it is laid out. A
    /// band runs from the top of its section's first line to the top of the next section's
    /// first line, or to the bottom of the text (the empty last line after a final line break
    /// included) for the last section. Each rect spans the container's width; the drawing
    /// widens it to the editor's.
    public func bandRects(in characterRange: NSRange, in container: NSTextContainer) -> [NSRect] {
        guard let storage = textStorage else { return [] }
        let length = storage.length
        let drawn = NSIntersectionRange(characterRange, NSRange(location: 0, length: length))
        guard drawn.length > 0 else { return [] }
        let drawnEnd = NSMaxRange(drawn)
        return bandRanges(in: drawn).map { band in
            let top = lineFragmentRect(
                forGlyphAt: glyphIndexForCharacter(at: max(band.location, drawn.location)), effectiveRange: nil
            ).minY
            let bandEnd = NSMaxRange(band)
            let bottom: CGFloat
            if bandEnd < drawnEnd {
                // The next section's first line is drawn too: the band stops where it starts.
                bottom = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: bandEnd), effectiveRange: nil).minY
            } else {
                let lastLine = lineFragmentRect(
                    forGlyphAt: glyphIndexForCharacter(at: drawnEnd - 1), effectiveRange: nil)
                if bandEnd == length, drawnEnd == length, extraLineFragmentTextContainer === container {
                    bottom = max(lastLine.maxY, extraLineFragmentRect.maxY)
                } else {
                    bottom = lastLine.maxY
                }
            }
            return NSRect(x: 0, y: top, width: container.size.width, height: bottom - top)
        }
    }

    // MARK: - Drawing

    /// Paints the bands of the filled sections among `glyphsToShow` (ED-10), then the
    /// background as `NSLayoutManager` draws it (the selection and any background attribute
    /// go over the band). `glyphsToShow` is what the text view's dirty rect covers, so only
    /// the visible lines are looked at. Each band spans the text view's bounds, margins
    /// included; without a view it spans the container.
    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if glyphsToShow.length > 0, textStorage != nil,
            let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil)
        {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            // Drawing happens on the main thread, where the text view lives.
            let view = container.textView
            let containerSpan = (x: origin.x, width: container.size.width)
            let span: (x: CGFloat, width: CGFloat) = MainActor.assumeIsolated {
                view.map { (x: $0.bounds.minX, width: $0.bounds.width) } ?? containerSpan
            }
            Self.bandColor.setFill()
            for rect in bandRects(in: characters, in: container) {
                NSRect(x: span.x, y: rect.minY + origin.y, width: span.width, height: rect.height).fill(
                    using: .sourceOver)
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Draws the glyphs as `NSLayoutManager` does, then the extension of every rule among
    /// them (ED-8). `glyphsToShow` is what the text view's dirty rect covers, so nothing
    /// outside the visible rect is painted or even looked at.
    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let context = NSGraphicsContext.current else { return }
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
            Self.draw(extent, font: font, at: origin, in: context)
        }
    }

    /// Paints as many hyphens as fit `extent.rect`, in `font` and `extensionColor`, on the
    /// rule's baseline, clipped to the rect so the last one never crosses the trailing edge.
    /// Core Text draws them because it places text by baseline, which is what lines the
    /// hyphens up with the typed rule; the text view is flipped, so the text matrix is too.
    private static func draw(_ extent: RuleExtension, font: NSFont, at origin: NSPoint, in context: NSGraphicsContext) {
        let hyphenWidth = NSAttributedString(string: extensionCharacter, attributes: [.font: font]).size().width
        guard hyphenWidth > 0 else { return }
        let count = Int((extent.rect.width / hyphenWidth).rounded(.down))
        guard count > 0 else { return }
        let hyphens = NSAttributedString(
            string: String(repeating: extensionCharacter, count: count),
            attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
        let line = CTLineCreateWithAttributedString(hyphens)
        let cg = context.cgContext
        cg.saveGState()
        cg.clip(to: extent.rect.offsetBy(dx: origin.x, dy: origin.y))
        extensionColor.setFill()
        cg.textMatrix = context.isFlipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        cg.textPosition = CGPoint(x: extent.rect.minX + origin.x, y: extent.baseline + origin.y)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }
}
