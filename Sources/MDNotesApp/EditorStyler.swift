import AppKit
import Foundation
import MDNotesCore

/// Light syntax styling for the editor (E-2): ATX headings in the bold face of the editor font,
/// `[[wikilinks]]` in the link colour, `#tags` in theirs, and inline or fenced code in the
/// system monospaced font (E-8) and their own colour. Only `.font` and `.foregroundColor` are
/// ever set, and the font keeps the base size everywhere: headings change weight, code tokens
/// change family (the one exception E-2 allows, ADR-0010), nothing else changes either.
/// Nothing here reaches the file, whose content is the text view's plain string (E-1).
///
/// A wikilink whose bare title several notes share is styled as ambiguous instead (K-2), in a
/// warning tint. Which links those are is the library's `LinkIndex`, read through `linkIndex`
/// every time links are styled, so a load or a keystroke sees the current snapshot. A new
/// snapshot can change a link's resolution without the text changing (a note created, renamed
/// or deleted), so `restyleLinks()` re-checks every link against the index then and re-styles
/// only those whose style changed.
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
///
/// The storage may show display-only thumbnail attachments that are not in the file (E-9).
/// Every scan here is of `EditorText`, the file's text with those left out, and every token
/// range it yields is mapped back to storage coordinates before an attribute is set, so an
/// attachment line neither shifts nor splits what the scanner sees. A paragraph range that
/// covers an attachment line resets that line's font and colour with the rest, which changes
/// nothing visible; the run's own marker attribute is never touched.
@MainActor
public final class EditorStyler {
    /// Attribute carried by every styled run; its value is a `TokenStyle` raw value. Lets the
    /// styler, and tests, tell what a range was styled as without re-scanning.
    nonisolated public static let tokenAttribute = NSAttributedString.Key("MDNotesToken")

    /// The kinds of styling E-2 and K-2 apply.
    public enum TokenStyle: String, Sendable, CaseIterable {
        case heading
        /// A wikilink or embed that is not ambiguous: unique, unresolved, by path, or an embed.
        case wikilink
        /// K-2: a wikilink whose bare title several notes share.
        case ambiguousLink
        case tag
        case inlineCode
        case fencedCode

        /// The style a token's kind alone decides; a wikilink is `.wikilink` here and becomes
        /// `.ambiguousLink` only once its target has been resolved (K-2).
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
            codeFont = EditorFontPreference.codeFont(ofSize: baseFont.pointSize)
            restyleAll()
        }
    }

    /// The colour unstyled text is set in.
    public let baseColor: NSColor = .textColor

    /// The warning tint an ambiguous link is set in (K-2).
    public static let ambiguousLinkColor: NSColor = .systemOrange

    /// K-2: the link index wikilink targets are resolved against, read whenever links are
    /// styled. `EditorController` points it at the snapshot of the library the shown note
    /// belongs to; until then nothing resolves and every link is styled as a plain wikilink.
    public var linkIndex: @MainActor () -> LinkIndex = { .empty }

    /// The bold face of `baseFont` at the same size, or `baseFont` itself when the family has
    /// no bold face.
    public private(set) var headingFont: NSFont

    /// The system monospaced font at `baseFont`'s size, for inline and fenced code (E-8).
    public private(set) var codeFont: NSFont

    /// Guards against re-entering while attributes are being applied.
    private var isRestyling = false

    public init(textView: NSTextView, baseFont: NSFont) {
        self.textView = textView
        self.baseFont = baseFont
        headingFont = Self.bold(baseFont)
        codeFont = EditorFontPreference.codeFont(ofSize: baseFont.pointSize)
    }

    // MARK: - Styles

    /// The attributes `style` adds on top of the base: a weight for headings, the monospaced
    /// font and a colour for code (E-8), a colour for the rest, and the marker.
    public func attributes(for style: TokenStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [Self.tokenAttribute: style.rawValue]
        switch style {
        case .heading: attributes[.font] = headingFont
        case .wikilink: attributes[.foregroundColor] = NSColor.linkColor
        case .ambiguousLink: attributes[.foregroundColor] = Self.ambiguousLinkColor
        case .tag: attributes[.foregroundColor] = NSColor.systemPurple
        case .inlineCode, .fencedCode:
            attributes[.font] = codeFont
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
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
        let text = EditorText(storage: storage)
        let whole = NSRange(location: 0, length: text.units.count)
        let tokens = MarkdownScanner.scan(text.units, in: whole)
        storage.beginEditing()
        apply(tokens, in: NSRange(location: 0, length: storage.length), of: text, to: storage)
        storage.endEditing()
    }

    /// E-3: called by the text storage delegate once an edit to the characters has been
    /// processed, with the range of the new text that changed. Re-styles the paragraphs around
    /// it, and no more, unless stale fenced-code styling shows a fence line was undone, in
    /// which case the re-style runs from those paragraphs to the end. The attribute changes
    /// are one nested editing pass of their own.
    public func restyleAfterEdit(in editedRange: NSRange) {
        guard let storage = textView.textStorage, !isRestyling else { return }
        let text = EditorText(storage: storage)
        let edited = text.fileRange(forStorageRange: editedRange)
        var range = MarkdownScanner.paragraphRange(in: text.units, editedRange: edited)
        var tokens = MarkdownScanner.scan(text.units, in: range)
        if hasStaleFencedStyling(storage, in: range, inserted: editedRange, fenced: tokens, of: text) {
            range.length = text.units.count - range.location
            tokens = MarkdownScanner.scan(text.units, in: range)
        }
        storage.beginEditing()
        apply(tokens, in: text.storageRange(forFileRange: range), of: text, to: storage)
        storage.endEditing()
    }

    /// Whether `range` (file indices) still carries fenced-code styling that none of the
    /// fenced blocks in `tokens` covers, other than on the text just inserted (`inserted`, a
    /// storage range, which only carries whatever the typing attributes were). Such styling
    /// belongs to a block that an edit has unfenced, and the block's remainder below the
    /// paragraph must be re-styled too.
    private func hasStaleFencedStyling(
        _ storage: NSTextStorage, in range: NSRange, inserted: NSRange, fenced tokens: [MarkdownScanner.Token],
        of text: EditorText
    ) -> Bool {
        let fenced = tokens.filter { $0.kind == .fencedCode }.map { text.storageRange(forFileRange: $0.range) }
        var stale = false
        let storageRange = text.storageRange(forFileRange: range)
        storage.enumerateAttribute(Self.tokenAttribute, in: storageRange, options: []) { value, run, stop in
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

    /// K-2: the snapshot changed, so a link may now be ambiguous that was not, or the other
    /// way round. Every link in the text is resolved against `linkIndex` again and only the
    /// links whose style differs from what they carry are re-styled, in one attributes-only
    /// pass; the text and every other run are untouched. Nothing happens when no link changed.
    public func restyleLinks() {
        guard let storage = textView.textStorage, !isRestyling else { return }
        let text = EditorText(storage: storage)
        let whole = NSRange(location: 0, length: text.units.count)
        let index = linkIndex()
        var changes: [(range: NSRange, style: TokenStyle)] = []
        for token in MarkdownScanner.scan(text.units, in: whole) {
            guard case .wikilink(let target, _, let isEmbed) = token.kind else { continue }
            let style = linkStyle(target: target, isEmbed: isEmbed, in: text, index: index)
            let range = text.storageRange(forFileRange: token.range)
            let current = storage.attribute(Self.tokenAttribute, at: range.location, effectiveRange: nil)
            if current as? String != style.rawValue { changes.append((range, style)) }
        }
        guard !changes.isEmpty else { return }
        isRestyling = true
        defer { isRestyling = false }
        storage.beginEditing()
        for change in changes {
            storage.addAttributes(attributes(for: change.style), range: change.range)
        }
        storage.endEditing()
    }

    /// The style of a link token (K-2): an embed links to a non-note file and is never
    /// ambiguous; any other target is ambiguous when the index says several notes share it.
    /// `target` is a range of file indices into `text`.
    private func linkStyle(target: NSRange, isEmbed: Bool, in text: EditorText, index: LinkIndex) -> TokenStyle {
        guard !isEmbed else { return .wikilink }
        return index.resolve(text.string(inFileRange: target)).isAmbiguous ? .ambiguousLink : .wikilink
    }

    /// Resets `range`, a storage range, to the base font and colour, then applies `tokens`,
    /// whose ranges are file indices into `text` and are mapped back to the storage. A heading
    /// line's links and tags are applied after the heading, so they take its weight and their
    /// colour. Links are resolved against `linkIndex` as they are applied (K-2).
    private func apply(
        _ tokens: [MarkdownScanner.Token], in range: NSRange, of text: EditorText, to storage: NSTextStorage
    ) {
        isRestyling = true
        defer { isRestyling = false }
        storage.removeAttribute(Self.tokenAttribute, range: range)
        storage.addAttributes([.font: baseFont, .foregroundColor: baseColor], range: range)
        let index = linkIndex()
        for token in tokens {
            let style: TokenStyle
            if case .wikilink(let target, _, let isEmbed) = token.kind {
                style = linkStyle(target: target, isEmbed: isEmbed, in: text, index: index)
            } else {
                style = TokenStyle(token.kind)
            }
            storage.addAttributes(attributes(for: style), range: text.storageRange(forFileRange: token.range))
        }
    }
}
