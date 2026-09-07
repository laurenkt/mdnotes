import AppKit
import Foundation
import MDNotesCore

/// Light syntax styling for the editor (E-2): ATX headings in the bold face of the editor font,
/// `[[wikilinks]]` in the link colour, `#tags` and inline or fenced code in their own colours.
/// Only `.font` (same family and size, another weight) and `.foregroundColor` are ever set, so
/// the text and its layout metrics are untouched beyond weight and colour; nothing here reaches
/// the file, whose content is the text view's plain string (E-1).
///
/// Re-styling after an edit is scoped (E-3): once the storage has processed an edit to its
/// characters, the delegate hands the edited range over, `MarkdownScanner.paragraphRange(in:
/// editedRange:)` widens it to the blank-line delimited paragraphs and fenced blocks it
/// touches, and only that range has its attributes reset and re-applied from a scan of that
/// range, in one nested attributes-only pass. It runs after processing, not during it,
/// because attributes changed during the character edit's pass widen that edit's range and
/// the text view then puts the insertion point at the end of the widened range.
///
/// Every styled run also carries `tokenAttribute`, naming its `TokenStyle`. That is how the one
/// case the paragraph scope cannot see from the new text alone is caught: an edit that turned a
/// fence line into something else leaves the block it opened styled as code below the
/// paragraph. When the paragraph still carries fenced-code styling that no fenced block in the
/// new text accounts for, the re-style runs to the end of the text instead.
///
/// The base font is the editor font preference (E-8); `MainView` reports a change through
/// `baseFont`, which re-styles the whole text, since setting the text view's font has just
/// flattened every weight.
@MainActor
public final class EditorStyler {
    /// Attribute carried by every styled run; its value is a `TokenStyle` raw value. Lets the
    /// styler, and tests, tell what a range was styled as without re-scanning.
    nonisolated public static let tokenAttribute = NSAttributedString.Key("MDNotesToken")

    /// The kinds of styling E-2 applies.
    public enum TokenStyle: String, Sendable, CaseIterable {
        case heading
        case wikilink
        case tag
        case inlineCode
        case fencedCode

        init(_ kind: MarkdownScanner.Kind) {
            switch kind {
            case .heading: self = .heading
            case .wikilink: self = .wikilink
            case .tag: self = .tag
            case .inlineCode: self = .inlineCode
            case .fencedCode: self = .fencedCode
            }
        }
    }

    public let textView: NSTextView

    /// The font unstyled text is set in (E-8). Setting a different one re-styles the whole text.
    public var baseFont: NSFont {
        didSet {
            guard baseFont != oldValue else { return }
            headingFont = Self.bold(baseFont)
            restyleAll()
        }
    }

    /// The colour unstyled text is set in.
    public let baseColor: NSColor = .textColor

    /// The bold face of `baseFont` at the same size, or `baseFont` itself when the family has
    /// no bold face.
    public private(set) var headingFont: NSFont

    /// Guards against re-entering while attributes are being applied.
    private var isRestyling = false

    public init(textView: NSTextView, baseFont: NSFont) {
        self.textView = textView
        self.baseFont = baseFont
        headingFont = Self.bold(baseFont)
    }

    // MARK: - Styles

    /// The attributes `style` adds on top of the base: a weight for headings, a colour for the
    /// rest, and the marker.
    public func attributes(for style: TokenStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [Self.tokenAttribute: style.rawValue]
        switch style {
        case .heading: attributes[.font] = headingFont
        case .wikilink: attributes[.foregroundColor] = NSColor.linkColor
        case .tag: attributes[.foregroundColor] = NSColor.systemPurple
        case .inlineCode, .fencedCode: attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        return attributes
    }

    private static func bold(_ font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.bold)
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        guard let bold = NSFont(descriptor: descriptor, size: font.pointSize),
            bold.fontDescriptor.symbolicTraits.contains(.bold)
        else {
            return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        return bold
    }

    // MARK: - Re-styling

    /// Re-styles the whole text from one full scan: after a base font change, or whenever the
    /// attributes may be out of step with the text.
    public func restyleAll() {
        guard let storage = textView.textStorage, !isRestyling else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let tokens = MarkdownScanner.scan(Self.units(of: storage), in: whole)
        storage.beginEditing()
        apply(tokens, in: whole, to: storage)
        storage.endEditing()
    }

    /// The storage's text as UTF-16 units, copied out in one call. A `String` bridged from
    /// the storage iterates its units one message at a time, which on a 1 MB note costs more
    /// than the whole PF-3 budget; the bulk copy is a fraction of a millisecond.
    static func units(of storage: NSTextStorage) -> [UInt16] {
        let length = storage.length
        let backing = storage.mutableString
        return [UInt16](unsafeUninitializedCapacity: length) { buffer, initialized in
            if let base = buffer.baseAddress, length > 0 {
                backing.getCharacters(base, range: NSRange(location: 0, length: length))
            }
            initialized = length
        }
    }

    /// E-3: called by the text storage delegate once an edit to the characters has been
    /// processed, with the range of the new text that changed. Re-styles the paragraphs around
    /// it, and no more, unless stale fenced-code styling shows a fence line was undone, in
    /// which case the re-style runs from those paragraphs to the end. The attribute changes
    /// are one nested editing pass of their own.
    public func restyleAfterEdit(in editedRange: NSRange) {
        guard let storage = textView.textStorage, !isRestyling else { return }
        let units = Self.units(of: storage)
        var range = MarkdownScanner.paragraphRange(in: units, editedRange: editedRange)
        var tokens = MarkdownScanner.scan(units, in: range)
        if hasStaleFencedStyling(storage, in: range, inserted: editedRange, fenced: tokens) {
            range.length = units.count - range.location
            tokens = MarkdownScanner.scan(units, in: range)
        }
        storage.beginEditing()
        apply(tokens, in: range, to: storage)
        storage.endEditing()
    }

    /// Whether `range` still carries fenced-code styling that none of the fenced blocks in
    /// `tokens` covers, other than on the text just inserted (which only carries whatever the
    /// typing attributes were). Such styling belongs to a block that an edit has unfenced,
    /// and the block's remainder below the paragraph must be re-styled too.
    private func hasStaleFencedStyling(
        _ storage: NSTextStorage, in range: NSRange, inserted: NSRange, fenced tokens: [MarkdownScanner.Token]
    ) -> Bool {
        let fenced = tokens.filter { $0.kind == .fencedCode }.map(\.range)
        var stale = false
        storage.enumerateAttribute(Self.tokenAttribute, in: range, options: []) { value, run, stop in
            guard value as? String == TokenStyle.fencedCode.rawValue else { return }
            if Self.range(inserted, contains: run) { return }
            if fenced.contains(where: { Self.range($0, contains: run) }) { return }
            stale = true
            stop.pointee = true
        }
        return stale
    }

    private static func range(_ outer: NSRange, contains inner: NSRange) -> Bool {
        inner.location >= outer.location && inner.location + inner.length <= outer.location + outer.length
    }

    /// Resets `range` to the base font and colour, then applies `tokens`. A heading line's
    /// links and tags are applied after the heading, so they take its weight and their colour.
    private func apply(_ tokens: [MarkdownScanner.Token], in range: NSRange, to storage: NSTextStorage) {
        isRestyling = true
        defer { isRestyling = false }
        storage.removeAttribute(Self.tokenAttribute, range: range)
        storage.addAttributes([.font: baseFont, .foregroundColor: baseColor], range: range)
        for token in tokens {
            storage.addAttributes(attributes(for: TokenStyle(token.kind)), range: token.range)
        }
    }
}
