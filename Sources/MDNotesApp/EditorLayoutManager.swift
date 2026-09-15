import AppKit
import Foundation

/// The editor's layout manager (ED-8, ADR-0019): TextKit 1's `NSLayoutManager` with the
/// drawing the halfway editor adds on top of the text. The text itself is never touched:
/// everything here is painted while the glyphs are drawn, over the visible rect only, so the
/// file, the storage, the selection, copy, undo and search stay exactly what the typed
/// characters are (E-1, E-2).
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

    public override init() {
        super.init()
        allowsNonContiguousLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

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
