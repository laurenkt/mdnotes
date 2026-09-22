import AppKit
import Foundation
import MDNotesCore

/// Syntax styling for the editor (E-2, ADR-0019): headings in the bold face of the editor font
/// scaled by level (ED-4), `[[wikilinks]]` in the link colour, `#tags` in theirs, inline or
/// fenced code in the system monospaced font (E-8) and their own colour, emphasis content with
/// the bold, italic or strikethrough trait (ED-3), and every markdown marker the scanner yields
/// (`#`, emphasis delimiters, `>`, link brackets and URLs, table pipes, setext underlines) in
/// tertiary label colour at the surrounding size, list markers and a rule's typed characters
/// in secondary label colour so bullets, numbers and rules stay legible (ED-2), list items
/// with a hanging indent so their wrapped lines align under the item text (ED-5), task
/// boxes in the monospaced font with a done item's content in secondary label colour (ED-6),
/// blockquote lines with a hanging indent under the quoted text and pipe-table lines in the
/// monospaced font with the separator row dimmed (ED-7), and a thematic break's typed
/// characters in the list-marker colour and marked `.rule` so `EditorLayoutManager` draws the extension to the
/// trailing edge after them (ED-8), and every link in a state of its own (ED-11). Only
/// `.font`, `.foregroundColor`, `.strikethroughStyle`, `.underlineStyle`, `.toolTip` and
/// `.paragraphStyle` are ever set: headings change weight and size, emphasis changes weight
/// or slant, code tokens, task boxes and table lines change family (ADR-0010), list items and
/// blockquotes change the paragraph's head indent, a missing link's target is underlined and
/// carries a tooltip, nothing else changes either. Nothing here reaches the file, whose
/// content is the text view's plain string (E-1).
///
/// A list item's paragraph gets a `headIndent` of the marker's width plus `nestingIndent` per
/// nesting level (ED-5): the marker (`- `, `1. `, with the spaces after it) is measured in
/// `baseFont`, and one nesting indent is two spaces in it, which is what the two leading spaces
/// per level the scanner counts (ED-1) take on the first line. The first line keeps a zero
/// indent, since its spaces and marker are drawn as typed, so a wrapped line starts exactly
/// where the item text does. The style goes on the whole paragraph, leading spaces and line
/// break included, because the layout manager reads a paragraph's style from its first
/// character. Ordered markers measure wider than bullets, so `10. ` items indent further than
/// `1. ` ones, each under its own text. Both widths follow the Cmd-plus size (E-8) and are
/// cached per marker string until the base font changes. Markers are dimmed like every other
/// (ED-2); the task box after one is ED-6's.
///
/// A task box `[ ]` or `[x]` is set in `codeFont`, the monospaced font at the body size, so a
/// space and an `x` take the same advance and the item text after either starts at the same
/// place (ED-6). The box keeps the text colour: its brackets are the one marker ED-2 leaves
/// undimmed, since the box is a control, not syntax. A ticked box puts `.doneItem` on its list
/// item's content, secondary label colour, before the content's own inline tokens are styled,
/// so a link or a tag in a done item keeps its colour and emphasis keeps its trait. Toggling
/// the box is an edit of one character, made by `EditorController.toggleTaskBox(at:)`, and is
/// styled like any other edit (E-3).
///
/// A blockquote line's paragraph hangs at the width of its prefix as typed (ED-7): the text
/// from the line start to where the quoted content begins (`> `, `> > `, or a bare `>`),
/// measured in `baseFont` like a list marker, so a wrapped line starts exactly where the
/// quoted text does and a nested quote, whose prefix is longer, hangs further. The `>`
/// characters are dimmed like every other marker (ED-2). A list item on a quoted line adds
/// its own indent to the quote's, so its wrapped lines align under the item text rather than
/// under the `>`. Prefix widths share `markerWidth`'s cache and follow the Cmd-plus size.
///
/// Pipe-table lines are set in `codeFont` over their whole trimmed range, pipes, cells and the
/// spaces between, so the columns line up as they do in the file (ED-7). Inline tokens in a
/// cell come after the row token and add their own trait or colour to the mono font. The
/// separator row (`|---|:-:|`) is set in `codeFont` and marker colour end to end: it is
/// syntax, not content, and its pipes are dimmed with the rest (ED-2).
///
/// A heading's content and markers are set at `headingScales[level]` times the base size, bold
/// (ED-4): 1.4, 1.25 and 1.1 for levels 1 to 3 and the base size from level 4 on, following
/// the Cmd-plus size because every heading font is derived from `baseFont` (E-8). A setext
/// heading's range spans its text line and its underline, so the underline is dimmed at the
/// heading's size (ED-9).
///
/// A token's style goes on its whole range and its markers are then recoloured, so a marker
/// keeps the weight and size of what surrounds it (a heading's `#` is bold, scaled and dimmed)
/// and carries the token's `tokenAttribute`. Emphasis is the exception: its trait goes on the
/// content only, added to whatever font each run there already has, so nested emphasis
/// composes (bold in italic is bold italic) and emphasis on a heading line keeps the heading's
/// weight and size. Tokens come enclosing first, so a code span inside emphasis is styled after
/// it and takes the code font and colour back, with no strikethrough: nothing inside code is
/// ever styled (ED-3). Code takes the size of what encloses it, so a code span in a heading is
/// monospaced at the heading's size (E-8, "at the same size"). Code markers (backticks, fence
/// lines) keep the code colour, a tag's `#` keeps the tag's colour (T-4), and a task box is
/// left to ED-6.
///
/// A wikilink is styled by what its target resolves to (ED-11, K-2): a target one note has, a
/// path to a note, or an embed (which names a file, never a note, K-1) is in link colour; a
/// target no note has keeps link colour and gets a dotted underline under the target text
/// (not the brackets, which are dimmed markers) and the tooltip `missingLinkToolTip` over the
/// whole link, since Cmd-click on it creates the note (K-3); a bare title several notes share
/// is ambiguous, in a warning tint. Which is which is the library's `LinkIndex`, read through
/// `linkIndex` every time links are styled, so a load or a keystroke sees the current
/// snapshot. A new snapshot can change a link's resolution without the text changing (a note
/// created, renamed or deleted), so `restyleLinks()` re-checks every link against the index
/// then and re-styles only those whose style changed, taking a former missing link's
/// underline and tooltip away or giving them to a link whose target has gone. A standard
/// link, an autolink and a bare URL are in link colour too, their brackets and URL dimmed
/// like every marker (ED-2); they never depend on the index. An image `![alt](url)` is not a
/// link and stays unstyled but for its markers.
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
/// flattened every weight and size.
///
/// A heading's size is part of the paragraph-scoped re-style like every other attribute
/// (ED-4, E-3): an edit to a heading line changes the fonts of its paragraph alone, so the
/// layout manager lays that paragraph out again and only moves what follows.
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

    /// The kinds of styling E-2, K-2, ED-3 and ED-11 apply.
    public enum TokenStyle: String, Sendable, CaseIterable {
        case heading
        /// ED-11: a wikilink whose target resolves (a unique title or a path), or an embed,
        /// which names a file rather than a note (K-1). Link colour.
        case wikilink
        /// ED-11: a wikilink whose target no note has. Link colour, a dotted underline under
        /// the target and the tooltip `missingLinkToolTip`, since Cmd-click creates it (K-3).
        case missingLink
        /// K-2: a wikilink whose bare title several notes share.
        case ambiguousLink
        /// ED-11: a standard link `[text](url)`, an autolink `<url>` or a bare URL, in link
        /// colour; the brackets and URL are dimmed markers (ED-2).
        case link
        case tag
        case inlineCode
        case fencedCode
        /// ED-3: the content of `**x**` or `__x__`, in the bold trait.
        case bold
        /// ED-3: the content of `*x*` or `_x_`, in the italic trait.
        case italic
        /// ED-3: the content of `~~x~~`, struck through.
        case strikethrough
        /// ED-5: a bullet, ordered or task list item, from its marker to the end of the line;
        /// its paragraph carries the hanging indent.
        case listItem
        /// ED-6: a task box `[ ]` or `[x]`, brackets included, in the monospaced font.
        case taskBox
        /// ED-6: the content of a ticked task item, in secondary label colour.
        case doneItem
        /// ED-7: a blockquote line, prefix included; its paragraph carries the hanging indent.
        case blockquote
        /// ED-7: a pipe-table row, pipes included, in the monospaced font.
        case tableRow
        /// ED-7: a pipe-table separator row, in the monospaced font and marker colour.
        case tableSeparator
        /// ED-8: a thematic break's typed characters, dimmed; `EditorLayoutManager` draws the
        /// extension to the trailing edge after every run carrying this.
        case rule

        /// The style a token's kind alone decides; a wikilink is `.wikilink` here and becomes
        /// `.missingLink` or `.ambiguousLink` only once its target has been resolved (ED-11,
        /// K-2); a standard link, autolink or bare URL is `.link` (ED-11); a task box is
        /// `.taskBox`, and `.doneItem` goes on a ticked one's item content structurally (ED-6).
        /// Nil for an image, which is not a link; its markers are dimmed all the same (ED-2).
        init?(_ kind: MarkdownScanner.Kind) {
            switch kind {
            case .heading: self = .heading
            case .wikilink: self = .wikilink
            case .tag: self = .tag
            case .inlineCode: self = .inlineCode
            case .fencedCode: self = .fencedCode
            case .emphasis(.bold): self = .bold
            case .emphasis(.italic): self = .italic
            case .emphasis(.strikethrough): self = .strikethrough
            case .link(_, isImage: false), .autolink, .bareURL: self = .link
            case .link(_, isImage: true): return nil
            case .listItem: self = .listItem
            case .taskBox: self = .taskBox
            case .blockquote: self = .blockquote
            case .tableRow: self = .tableRow
            case .tableSeparator: self = .tableSeparator
            case .thematicBreak: self = .rule
            }
        }

        /// The emphasis styles, whose attributes go on a token's content rather than its range
        /// and whose font trait is added to what is there (ED-3).
        var isEmphasis: Bool {
            switch self {
            case .bold, .italic, .strikethrough: true
            case .heading, .wikilink, .missingLink, .ambiguousLink, .link, .tag, .inlineCode, .fencedCode, .listItem,
                .taskBox, .doneItem, .blockquote, .tableRow, .tableSeparator, .rule:
                false
            }
        }

        /// The wikilink states ED-11 and K-2 tell apart by resolving the target, which
        /// `restyleLinks()` moves a link between when the index changes under the text.
        var isWikilink: Bool {
            switch self {
            case .wikilink, .missingLink, .ambiguousLink: true
            case .heading, .link, .tag, .inlineCode, .fencedCode, .bold, .italic, .strikethrough, .listItem, .taskBox,
                .doneItem, .blockquote, .tableRow, .tableSeparator, .rule:
                false
            }
        }
    }

    /// ED-2: whether a token's markers are dimmed. Every markdown marker is, except those of
    /// code, which keep the code colour with the rest of the token, a tag's `#`, which keeps
    /// the tag's colour (T-4), and a task box's brackets, whose look ED-6 decides.
    static func dimsMarkers(_ kind: MarkdownScanner.Kind) -> Bool {
        switch kind {
        case .inlineCode, .fencedCode, .tag, .taskBox: false
        case .heading, .wikilink, .emphasis, .link, .autolink, .bareURL, .listItem, .blockquote, .tableRow,
            .tableSeparator, .thematicBreak:
            true
        }
    }

    /// ED-2: the colour a token's markers are set in when `dimsMarkers` says they are: the
    /// list-marker colour for a list item's marker and a rule's typed characters, the marker
    /// colour for every other construct's.
    static func markerColor(for kind: MarkdownScanner.Kind) -> NSColor {
        switch kind {
        case .listItem, .thematicBreak: listMarkerColor
        case .heading, .wikilink, .emphasis, .link, .autolink, .bareURL, .blockquote, .tableRow, .tableSeparator,
            .inlineCode, .fencedCode, .tag, .taskBox:
            markerColor
        }
    }

    public let textView: NSTextView

    /// The font unstyled text is set in (E-8). Setting a different one re-styles the whole text.
    public var baseFont: NSFont {
        didSet {
            guard baseFont != oldValue else { return }
            headingFonts = Self.headingFonts(for: baseFont)
            codeFont = EditorFontPreference.codeFont(ofSize: baseFont.pointSize)
            nestingIndent = Self.width(of: Self.nestingIndentText, in: baseFont)
            markerWidths.removeAll()
            hangingParagraphStyles.removeAll()
            restyleAll()
        }
    }

    /// The colour unstyled text is set in.
    public let baseColor: NSColor = .textColor

    /// The warning tint an ambiguous link is set in (K-2).
    public static let ambiguousLinkColor: NSColor = .systemOrange

    /// ED-11: the tooltip a wikilink whose target no note has shows, over its whole range.
    nonisolated public static let missingLinkToolTip = "Cmd-click to create"

    /// ED-11: the underline under a missing wikilink's target: a single dotted line, in the
    /// text's own colour (link colour).
    nonisolated public static let missingLinkUnderline: NSUnderlineStyle = [.single, .patternDot]

    /// The colour markdown markers are set in (ED-2), and of a rule's drawn extension
    /// (ED-8, `EditorLayoutManager.extensionColor`); list markers and rules use
    /// `listMarkerColor` instead.
    nonisolated public static let markerColor: NSColor = .tertiaryLabelColor

    /// ED-2 (ADR-0021): the colour list markers (`-`, `*`, `+`, `<n>.`, a task item's `- `
    /// included) and a thematic break's typed characters are set in, so they stay legible.
    nonisolated public static let listMarkerColor: NSColor = .secondaryLabelColor

    /// The colour a ticked task item's content is set in (ED-6).
    public static let doneItemColor: NSColor = .secondaryLabelColor

    /// K-2: the link index wikilink targets are resolved against, read whenever links are
    /// styled. `EditorController` points it at the snapshot of the library the shown note
    /// belongs to; until then nothing resolves and every link is styled as a plain wikilink.
    public var linkIndex: @MainActor () -> LinkIndex = { .empty }

    /// ED-4: how many times the base size a heading of level 1, 2, 3 and 4 or more is set at.
    /// `headingScale(forLevel:)` reads it.
    nonisolated public static let headingScales: [CGFloat] = [1.4, 1.25, 1.1, 1.0]

    /// ED-4: the factor a heading of `level` (1 to 6) scales the base size by; levels past the
    /// last entry of `headingScales` share its value, and a level below 1 reads as 1.
    nonisolated public static func headingScale(forLevel level: Int) -> CGFloat {
        let index = min(max(level, 1), headingScales.count) - 1
        return headingScales[index]
    }

    /// The bold face of `baseFont` at each heading level's size (ED-4), indexed by level minus
    /// one; `headingFont(forLevel:)` reads it.
    private var headingFonts: [NSFont]

    /// The font a heading of `level` is set in (ED-4): `baseFont`'s bold face at
    /// `headingScale(forLevel:)` times its size, or the scaled `baseFont` itself when the family
    /// has no bold face.
    public func headingFont(forLevel level: Int) -> NSFont {
        let index = min(max(level, 1), headingFonts.count) - 1
        return headingFonts[index]
    }

    /// The system monospaced font at `baseFont`'s size, for inline and fenced code (E-8).
    public private(set) var codeFont: NSFont

    /// ED-5: the text one nesting indent is the width of: the two leading spaces per level the
    /// scanner counts (ED-1).
    nonisolated public static let nestingIndentText = "  "

    /// ED-5: the width of one nesting level, `nestingIndentText` in `baseFont`.
    public private(set) var nestingIndent: CGFloat

    /// ED-5, ED-7: the width in `baseFont` of each list marker and blockquote prefix seen since
    /// the base font last changed.
    private var markerWidths: [String: CGFloat] = [:]

    /// ED-5, ED-7: the paragraph style for each head indent seen since the base font last
    /// changed.
    private var hangingParagraphStyles: [CGFloat: NSParagraphStyle] = [:]

    /// Guards against re-entering while attributes are being applied.
    private var isRestyling = false

    public init(textView: NSTextView, baseFont: NSFont) {
        self.textView = textView
        self.baseFont = baseFont
        headingFonts = Self.headingFonts(for: baseFont)
        codeFont = EditorFontPreference.codeFont(ofSize: baseFont.pointSize)
        nestingIndent = Self.width(of: Self.nestingIndentText, in: baseFont)
    }

    /// One bold font per entry of `headingScales`, each `base` at that multiple of its size.
    private static func headingFonts(for base: NSFont) -> [NSFont] {
        headingScales.map { bold(base.withSize(base.pointSize * $0)) }
    }

    /// The width `text` takes set in `font`, as the layout manager will set it.
    private static func width(of text: String, in font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    /// ED-5, ED-7: the width of `marker` (a list marker with the spaces after it, `- ` or
    /// `12. `, or a blockquote prefix as typed, `> ` or `> > `) in `baseFont`, which is what it
    /// takes on the line's first line.
    public func markerWidth(_ marker: String) -> CGFloat {
        if let width = markerWidths[marker] { return width }
        let width = Self.width(of: marker, in: baseFont)
        markerWidths[marker] = width
        return width
    }

    /// ED-5: the head indent of a list item at nesting `level` whose marker is `marker`: the
    /// marker's width plus one `nestingIndent` per level, so a wrapped line starts where the
    /// item text does.
    public func listHeadIndent(level: Int, marker: String) -> CGFloat {
        markerWidth(marker) + CGFloat(max(level, 0)) * nestingIndent
    }

    /// ED-7: the head indent of a blockquote line whose prefix, from the line start to the
    /// quoted content, is `prefix` (`> `, `> > `, `>`): its width in `baseFont`, so a wrapped
    /// line starts where the quoted text does and a nested quote hangs further.
    public func blockquoteHeadIndent(prefix: String) -> CGFloat {
        markerWidth(prefix)
    }

    /// The paragraph style hanging every line but the first at `headIndent` (ED-5, ED-7).
    private func hangingParagraphStyle(headIndent: CGFloat) -> NSParagraphStyle {
        if let style = hangingParagraphStyles[headIndent] { return style }
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(.default)
        style.firstLineHeadIndent = 0
        style.headIndent = headIndent
        hangingParagraphStyles[headIndent] = style
        return style
    }

    // MARK: - Styles

    /// The attributes `style` adds on top of the base: the monospaced font and a colour for code
    /// (E-8), the monospaced font alone for a task box and a colour alone for a done item's
    /// content (ED-6), the monospaced font for a table row and that plus the marker colour for
    /// a separator row (ED-7), a colour for links and tags, the tooltip too for a missing link
    /// (ED-11), a strikethrough for `~~x~~`, and the marker. Fonts that depend on what is
    /// already there are not here: a heading's font depends on its level and is set by
    /// `apply(_:to:of:to:)` from `headingFont(forLevel:)`, and the bold and italic traits of
    /// emphasis are added to the fonts already in place, run by run, by
    /// `addTrait(_:fallback:in:to:)`. Nor are paragraph styles: a list item's and a
    /// blockquote's hanging indents depend on their marker and prefix (ED-5, ED-7). Nor is a
    /// missing link's underline, which goes under its target alone, not its brackets (ED-11).
    public func attributes(for style: TokenStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [Self.tokenAttribute: style.rawValue]
        switch style {
        case .heading, .bold, .italic, .listItem, .blockquote, .rule: break
        case .wikilink, .link: attributes[.foregroundColor] = NSColor.linkColor
        case .missingLink:
            attributes[.foregroundColor] = NSColor.linkColor
            attributes[.toolTip] = Self.missingLinkToolTip
        case .ambiguousLink: attributes[.foregroundColor] = Self.ambiguousLinkColor
        case .tag: attributes[.foregroundColor] = NSColor.systemPurple
        case .inlineCode, .fencedCode:
            attributes[.font] = codeFont
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .strikethrough: attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case .taskBox, .tableRow: attributes[.font] = codeFont
        case .tableSeparator:
            attributes[.font] = codeFont
            attributes[.foregroundColor] = Self.markerColor
        case .doneItem: attributes[.foregroundColor] = Self.doneItemColor
        }
        return attributes
    }

    private static func bold(_ font: NSFont) -> NSFont {
        adding(.bold, fallback: .boldFontMask, to: font)
    }

    /// `font` with `trait` added, at the same size, or `font` itself when its family has no
    /// such face and the font manager cannot find one either.
    private static func adding(
        _ trait: NSFontDescriptor.SymbolicTraits, fallback: NSFontTraitMask, to font: NSFont
    ) -> NSFont {
        guard !font.fontDescriptor.symbolicTraits.contains(trait) else { return font }
        let traits = font.fontDescriptor.symbolicTraits.union(trait)
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        guard let added = NSFont(descriptor: descriptor, size: font.pointSize),
            added.fontDescriptor.symbolicTraits.contains(trait)
        else {
            return NSFontManager.shared.convert(font, toHaveTrait: fallback)
        }
        return added
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

    /// ED-11, K-2: the snapshot changed, so a link's target may have appeared or gone, or its
    /// title become ambiguous or unique again. Every wikilink in the text is resolved against
    /// `linkIndex` again and only the links whose style differs from what they carry are
    /// re-styled, in one attributes-only pass; the text and every other run are untouched.
    /// Nothing happens when no link changed.
    public func restyleLinks() {
        guard let storage = textView.textStorage, !isRestyling else { return }
        let text = EditorText(storage: storage)
        let whole = NSRange(location: 0, length: text.units.count)
        let index = linkIndex()
        var changes: [(token: MarkdownScanner.Token, style: TokenStyle)] = []
        for token in MarkdownScanner.scan(text.units, in: whole) {
            guard case .wikilink(let target, _, let isEmbed) = token.kind else { continue }
            let style = linkStyle(target: target, isEmbed: isEmbed, in: text, index: index)
            let range = text.storageRange(forFileRange: token.range)
            let current = storage.attribute(Self.tokenAttribute, at: range.location, effectiveRange: nil)
            if current as? String != style.rawValue { changes.append((token, style)) }
        }
        guard !changes.isEmpty else { return }
        isRestyling = true
        defer { isRestyling = false }
        storage.beginEditing()
        for change in changes {
            apply(change.style, to: change.token, of: text, to: storage)
        }
        storage.endEditing()
    }

    /// The style of a wikilink token (ED-11, K-2): an embed links to a non-note file and is
    /// never missing or ambiguous; any other target is missing when no note has it and
    /// ambiguous when the index says several share it. `target` is a range of file indices
    /// into `text`.
    private func linkStyle(target: NSRange, isEmbed: Bool, in text: EditorText, index: LinkIndex) -> TokenStyle {
        guard !isEmbed else { return .wikilink }
        switch index.resolve(text.string(inFileRange: target)) {
        case .unique: return .wikilink
        case .ambiguous: return .ambiguousLink
        case .unresolved: return .missingLink
        }
    }

    /// Resets `range`, a storage range, to the base font and colour with no strikethrough,
    /// underline or tooltip, then applies `tokens`, whose ranges are file indices into `text`
    /// and are mapped back to the storage. Tokens come enclosing first, so what a token
    /// encloses is styled after it: a heading line's links and tags take its weight and their
    /// colour, emphasis inside emphasis composes, and code inside emphasis takes the code style
    /// back (ED-3). Wikilinks are resolved against `linkIndex` as they are applied (ED-11,
    /// K-2). A token with no style of its own still has its markers dimmed (ED-2). A ticked
    /// task box follows its list item, and its item's content takes `.doneItem` right after
    /// the box, before the content's inline tokens (ED-6). A blockquote token covers its whole
    /// line and comes before the line's other tokens, so a list item on that line adds the
    /// quote's indent to its own (ED-7).
    private func apply(
        _ tokens: [MarkdownScanner.Token], in range: NSRange, of text: EditorText, to storage: NSTextStorage
    ) {
        isRestyling = true
        defer { isRestyling = false }
        storage.removeAttribute(Self.tokenAttribute, range: range)
        storage.removeAttribute(.strikethroughStyle, range: range)
        storage.removeAttribute(.underlineStyle, range: range)
        storage.removeAttribute(.toolTip, range: range)
        storage.removeAttribute(.paragraphStyle, range: range)
        storage.addAttributes([.font: baseFont, .foregroundColor: baseColor], range: range)
        let index = linkIndex()
        var listItem: MarkdownScanner.Token?
        var quote: (line: NSRange, indent: CGFloat)?
        for token in tokens {
            let style: TokenStyle?
            if case .wikilink(let target, _, let isEmbed) = token.kind {
                style = linkStyle(target: target, isEmbed: isEmbed, in: text, index: index)
            } else {
                style = TokenStyle(token.kind)
            }
            if case .blockquote = token.kind {
                quote = (token.range, blockquoteHeadIndent(prefix: Self.prefix(of: token, in: text)))
            } else if let current = quote, !NSLocationInRange(token.range.location, current.line) {
                quote = nil
            }
            apply(style, to: token, of: text, to: storage, quoteIndent: quote?.indent ?? 0)
            if case .listItem = token.kind {
                listItem = token
            } else if case .taskBox(isDone: true) = token.kind, let item = listItem {
                storage.addAttributes(
                    attributes(for: .doneItem), range: text.storageRange(forFileRange: item.content))
            }
        }
    }

    /// ED-7: a blockquote token's prefix as typed, from its line start to its content.
    private static func prefix(of token: MarkdownScanner.Token, in text: EditorText) -> String {
        text.string(
            inFileRange: NSRange(location: token.range.location, length: token.content.location - token.range.location))
    }

    /// Styles one token: `style`'s attributes on its range, or on its content alone for
    /// emphasis, whose trait is added to the fonts already there; a heading takes the bold font
    /// of its level (ED-4); code takes the code font at the size of what encloses it and drops
    /// any strikethrough an enclosing token left (ED-3); a list item puts the hanging indent on
    /// its whole paragraph, `quoteIndent` further along on a quoted line (ED-5, ED-7); a task
    /// box takes the monospaced font from its attributes (ED-6); a blockquote puts its own
    /// hanging indent on its paragraph and a table line takes the monospaced font from its
    /// attributes (ED-7); a missing wikilink takes the dotted underline under its target, and
    /// any other wikilink state drops the underline and tooltip a `restyleLinks()` pass may
    /// find left from that state (ED-11); then the markers are recoloured (ED-2), so they carry
    /// the token's attribute and font and the marker colour. Ranges are file indices into
    /// `text`, mapped to the storage here.
    private func apply(
        _ style: TokenStyle?, to token: MarkdownScanner.Token, of text: EditorText, to storage: NSTextStorage,
        quoteIndent: CGFloat = 0
    ) {
        if let style {
            let range = text.storageRange(forFileRange: style.isEmphasis ? token.content : token.range)
            let enclosingSize = enclosingFontSize(at: range, in: storage)
            if style.isWikilink {
                storage.removeAttribute(.underlineStyle, range: range)
                storage.removeAttribute(.toolTip, range: range)
            }
            storage.addAttributes(attributes(for: style), range: range)
            switch style {
            case .heading:
                if case .heading(let level) = token.kind {
                    storage.addAttribute(.font, value: headingFont(forLevel: level), range: range)
                }
            case .missingLink:
                storage.addAttribute(
                    .underlineStyle, value: Self.missingLinkUnderline.rawValue,
                    range: text.storageRange(forFileRange: token.content))
            case .bold: addTrait(.bold, fallback: .boldFontMask, in: range, to: storage)
            case .italic: addTrait(.italic, fallback: .italicFontMask, in: range, to: storage)
            case .inlineCode, .fencedCode:
                storage.removeAttribute(.strikethroughStyle, range: range)
                if enclosingSize != baseFont.pointSize {
                    storage.addAttribute(
                        .font, value: EditorFontPreference.codeFont(ofSize: enclosingSize), range: range)
                }
            case .listItem:
                if case .listItem(let level, _) = token.kind, let marker = token.markers.first {
                    let indent = quoteIndent + listHeadIndent(level: level, marker: text.string(inFileRange: marker))
                    storage.addAttribute(
                        .paragraphStyle, value: hangingParagraphStyle(headIndent: indent),
                        range: storage.mutableString.paragraphRange(for: range))
                }
            case .blockquote:
                storage.addAttribute(
                    .paragraphStyle, value: hangingParagraphStyle(headIndent: quoteIndent),
                    range: storage.mutableString.paragraphRange(for: range))
            case .wikilink, .ambiguousLink, .link, .tag, .strikethrough, .taskBox, .doneItem, .tableRow,
                .tableSeparator, .rule:
                break
            }
        }
        guard Self.dimsMarkers(token.kind) else { return }
        let color = Self.markerColor(for: token.kind)
        for marker in token.markers {
            storage.addAttribute(
                .foregroundColor, value: color, range: text.storageRange(forFileRange: marker))
        }
    }

    /// The point size of the font already at the start of `range` (a storage range), which is
    /// the font of whatever encloses the token about to be styled there: the heading's on a
    /// heading line, else the base font's. The base size for an empty range.
    private func enclosingFontSize(at range: NSRange, in storage: NSTextStorage) -> CGFloat {
        guard range.length > 0, range.location < storage.length,
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        else { return baseFont.pointSize }
        return font.pointSize
    }

    /// Adds `trait` to the font of every run in `range` (a storage range), keeping each run's
    /// size, so bold inside italic is bold italic and emphasis on a heading keeps its weight.
    private func addTrait(
        _ trait: NSFontDescriptor.SymbolicTraits, fallback: NSFontTraitMask, in range: NSRange,
        to storage: NSTextStorage
    ) {
        var changes: [(range: NSRange, font: NSFont)] = []
        storage.enumerateAttribute(.font, in: range, options: []) { value, run, _ in
            let font = value as? NSFont ?? baseFont
            changes.append((run, Self.adding(trait, fallback: fallback, to: font)))
        }
        for change in changes {
            storage.addAttribute(.font, value: change.font, range: change.range)
        }
    }
}
