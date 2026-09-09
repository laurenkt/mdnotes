import Foundation

/// One left-to-right pass over markdown text producing the ranges the editor styles (E-2,
/// ED-1) and the link and tag indexes read (K-1, T-1). Ranges are UTF-16 offsets into the
/// text (`NSRange`), the coordinate system of `NSTextStorage`, so the editor applies them
/// without conversion. There is no tree: every construct is a `Token` with the ranges of its
/// markers and of its content, and a token inside another (emphasis in a heading, a tag in a
/// list item, bold inside italic) is simply a second token whose range lies within the first.
/// Tokens come in order of location, an enclosing token before what it encloses.
///
/// The pass is line-oriented. A fence line (three backticks or `~~~`, at most three spaces
/// indented) opens a fenced block that runs to the matching closing fence or the end of the
/// text; nothing inside is any other token. Outside fences each line is read for its block
/// shape and then, left to right, for inline constructs, each confined to its line:
///
/// - blocks: a blockquote prefix (`>` repeated for nesting, ED-1) ahead of everything else; a
///   setext underline (`=` or `-`) directly under a paragraph line (ED-9); a thematic break
///   (`---`, `***`, `___`, spaces allowed) that starts the text or follows a blank line
///   (ED-8); an ATX heading (`#` to `######` then a space, a tab or the line end); a list item
///   (`- `, `* `, `+ `, `<n>. `, nesting by two leading spaces per level, a task box `[ ]` or
///   `[x]` after the marker); a pipe-table header row when the next line is a separator row,
///   the separator itself, and the rows following it until a blank line or a line without a
///   pipe;
/// - inline, on whatever of the line those leave: code spans (a backtick run closed by a run
///   of the same length hides what it contains; an unclosed run is literal, T-1), wikilinks and
///   embeds (K-1), standard links `[text](url)` and images `![alt](url)`, autolinks `<url>`,
///   bare `http(s)://` URLs, tags (T-1), and emphasis: `**`/`__` bold, `*`/`_` italic, `~~`
///   strikethrough, matched by CommonMark's flanking rules, so underscores inside a word
///   (`snake_case`) never open or close and `2 * 3` is arithmetic. A backslash before ASCII
///   punctuation escapes it.
///
/// `paragraphRange(in:editedRange:)` is the re-styling scope for E-3: the blank-line delimited
/// paragraph(s) around an edit, widened to any fenced block they touch, to the neighbouring
/// paragraphs when an edited line is blank, and to the end of the text when an edited line is
/// itself shaped like a fence so that a change in fence state propagates. `scan(_:in:)` over
/// that range reproduces exactly the tokens a full scan yields there, because no token crosses
/// a paragraph boundary except a fenced block and the range already covers those whole.
public enum MarkdownScanner {
    /// The trait an emphasis token gives its content (ED-3).
    public enum Emphasis: Equatable, Sendable {
        case bold
        case italic
        case strikethrough
    }

    /// What a token is, with the sub-ranges a consumer needs beyond its markers and content.
    public enum Kind: Equatable, Sendable {
        /// A heading of `level` 1 to 6: ATX (the token range is the line without its terminator,
        /// the marker its `#` run) or setext (the range spans the text line and its underline,
        /// the marker the underline, ED-9).
        case heading(level: Int)
        /// `[[target]]`, `[[target|label]]`, or with a leading `!` an embed (K-1). `target` and
        /// `label` are trimmed of whitespace; `label` is nil when there is no `|`. The markers
        /// are the brackets; the content is what is between them.
        case wikilink(target: NSRange, label: NSRange?, isEmbed: Bool)
        /// `#name` (T-1). The token range includes the `#`; `name` is the range after it.
        case tag(name: NSRange)
        /// A backtick-delimited code span including its delimiters, which are its markers.
        case inlineCode
        /// A fenced code block from the start of the opening fence line to the end of the
        /// closing fence line (terminator included) or the end of the scanned text. The markers
        /// are the fence lines; the content is the lines between them.
        case fencedCode
        /// Bold, italic or strikethrough: the markers are the opening and closing delimiter
        /// runs, the content what they enclose. Nested emphasis yields nested tokens.
        case emphasis(Emphasis)
        /// `[text](url)`, or with a leading `!` an image `![alt](url)`. The markers are the
        /// opening bracket (with the `!`) and `](url)` with any title; the content is the text.
        case link(url: NSRange, isImage: Bool)
        /// `<url>` with a scheme. The markers are the angle brackets; `url` is the content.
        case autolink(url: NSRange)
        /// A bare `http://` or `https://` URL. No markers; `url` is the whole token.
        case bareURL(url: NSRange)
        /// A list item at nesting `level` (two leading spaces each, ED-1), bullet or ordered.
        /// The marker is `- ` or `1. ` with the spaces after it; the content is the item text
        /// after any task box; the range runs from the marker to the end of the line.
        case listItem(level: Int, ordered: Bool)
        /// A task box `[ ]` or `[x]` after a list marker (ED-6). The markers are the brackets;
        /// the content is the character between them.
        case taskBox(isDone: Bool)
        /// A line with `level` blockquote prefixes. The markers are the `>` characters; the
        /// content is the line after the last prefix; the range is the whole line.
        case blockquote(level: Int)
        /// A pipe-table row: the markers are the unescaped pipes; the content is the line.
        case tableRow
        /// A pipe-table separator row (`|---|:--:|`): markers the pipes, content the line.
        case tableSeparator
        /// A thematic break (ED-8): the marker is the whole token; the content is empty.
        case thematicBreak
    }

    /// A recognised token and where it is: its whole `range`, the `markers` that spell it out
    /// (ED-2) and the `content` between them (ED-3), all in document coordinates.
    public struct Token: Equatable, Sendable {
        public let kind: Kind
        public let range: NSRange
        public let markers: [NSRange]
        public let content: NSRange

        /// `content` defaults to the whole range, `markers` to none.
        public init(kind: Kind, range: NSRange, markers: [NSRange] = [], content: NSRange? = nil) {
            self.kind = kind
            self.range = range
            self.markers = markers
            self.content = content ?? range
        }
    }

    /// T-1: whether a UTF-16 unit is one of `[A-Za-z0-9_/-]`, the characters a tag's name is
    /// made of. The `#` completion (T-3) uses it to see where the tag being typed ends.
    public static func isTagCharacter(_ unit: UInt16) -> Bool {
        U.isTagCharacter(unit)
    }

    // MARK: Scanning

    /// Every token in `text`, in order of appearance.
    public static func scan(_ text: String) -> [Token] {
        scan(text, in: NSRange(location: 0, length: text.utf16.count))
    }

    /// The tokens within `range` of `text`, in document coordinates. `range` must start at a
    /// line start that is outside any fenced block and is the start of the text or follows a
    /// blank line, which `paragraphRange(in:editedRange:)` guarantees; a fenced block left open
    /// inside the range ends at the range's end.
    public static func scan(_ text: String, in range: NSRange) -> [Token] {
        let utf16 = text.utf16
        let total = utf16.count
        let location = min(max(range.location, 0), total)
        let end = min(max(location + range.length, location), total)
        let units = Array(
            utf16[utf16.index(utf16.startIndex, offsetBy: location)..<utf16.index(utf16.startIndex, offsetBy: end)])
        var scanner = Pass(units: units, base: location)
        scanner.run()
        return scanner.tokens
    }

    /// `scan(_:in:)` over text already held as UTF-16 units. The editor's text lives in an
    /// `NSTextStorage`, whose units copy out in bulk; iterating them through a bridged `String`
    /// costs more per keystroke than PF-3 allows on a 1 MB note.
    public static func scan(_ units: [UInt16], in range: NSRange) -> [Token] {
        let total = units.count
        let location = min(max(range.location, 0), total)
        let end = min(max(location + range.length, location), total)
        var scanner = Pass(units: Array(units[location..<end]), base: location)
        scanner.run()
        return scanner.tokens
    }

    // MARK: Paragraph scope (E-3)

    /// The range of `text` to re-scan after `editedRange` (a range in the new text: the inserted
    /// text, or an empty range where text was removed). The result starts at a line start, ends
    /// at a line start or the end of the text, and is never smaller than the edit. It covers
    /// the paragraph containing the edit's first line to the end of the paragraph containing
    /// its last, where paragraphs are separated by blank lines; when an edited line is blank it
    /// covers the paragraphs on either side too, since a blank line's presence is what splits
    /// or joins them and decides a thematic break (ED-8) or setext heading (ED-9) next to it;
    /// is widened to cover every fenced block it intersects; and runs to the end of the text
    /// when an edited line is shaped like a fence (three or more backticks or tildes after at
    /// most three spaces), since such a line may have opened or closed a block that changes
    /// everything below it. The reverse, an edit that turned a fence line into something else,
    /// is invisible here: the caller widens to the end of the text itself when the text it
    /// replaced carried fenced-code styling.
    public static func paragraphRange(in text: String, editedRange: NSRange) -> NSRange {
        paragraphRange(in: Array(text.utf16), editedRange: editedRange)
    }

    /// `paragraphRange(in:editedRange:)` over text already held as UTF-16 units; see
    /// `scan(_:in:)` on units for why the editor takes this route.
    public static func paragraphRange(in units: [UInt16], editedRange: NSRange) -> NSRange {
        let total = units.count
        let editStart = min(max(editedRange.location, 0), total)
        let editEnd = min(max(editStart + editedRange.length, editStart), total)

        var start = Lines.lineStart(containing: editStart, in: units)
        var end = Lines.nextLineStart(after: editEnd, in: units)

        // A fence-like line among the edited lines: state below may have changed. A blank one:
        // the paragraphs either side are joined or split.
        var fenceLike = false
        var touchesBlank = false
        var cursor = start
        while cursor < end {
            let next = Lines.nextLineStart(after: cursor, in: units)
            if Fences.looksLikeFence(lineStart: cursor, in: units) { fenceLike = true }
            if Lines.isBlank(lineStart: cursor, in: units) { touchesBlank = true }
            cursor = next
        }

        // Widen to blank-line delimited paragraphs. A blank edited line is a separator and
        // joins nothing by itself.
        if !Lines.isBlank(lineStart: start, in: units) {
            start = Lines.paragraphStart(from: start, in: units)
        }
        if !Lines.isBlank(lineStart: Lines.lineStart(containing: max(end - 1, start), in: units), in: units) {
            end = Lines.paragraphEnd(from: end, in: units)
        }

        // A blank line among the edited lines: cover the paragraph before and the one after.
        if touchesBlank {
            if start > 0 {
                let before = Lines.lineStart(containing: start - 1, in: units)
                if !Lines.isBlank(lineStart: before, in: units) {
                    start = Lines.paragraphStart(from: before, in: units)
                }
            }
            if end < total, !Lines.isBlank(lineStart: end, in: units) {
                end = Lines.paragraphEnd(from: end, in: units)
            }
        }

        // Widen to every fenced block the paragraph intersects.
        for block in Fences.blocks(in: units) where block.location < end && start < block.location + block.length {
            start = min(start, block.location)
            end = max(end, block.location + block.length)
        }

        if fenceLike { end = total }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Implementation

private enum U {
    static let newline: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let tab: UInt16 = 0x09
    static let bang: UInt16 = 0x21
    static let quote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let apostrophe: UInt16 = 0x27
    static let openParen: UInt16 = 0x28
    static let closeParen: UInt16 = 0x29
    static let asterisk: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let comma: UInt16 = 0x2C
    static let dash: UInt16 = 0x2D
    static let period: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let colon: UInt16 = 0x3A
    static let semicolon: UInt16 = 0x3B
    static let lessThan: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let greaterThan: UInt16 = 0x3E
    static let question: UInt16 = 0x3F
    static let upperH: UInt16 = 0x48
    static let upperX: UInt16 = 0x58
    static let openBracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let closeBracket: UInt16 = 0x5D
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let lowerH: UInt16 = 0x68
    static let lowerX: UInt16 = 0x78
    static let pipe: UInt16 = 0x7C
    static let tilde: UInt16 = 0x7E

    static func isTerminator(_ u: UInt16) -> Bool { u == newline || u == carriageReturn }

    static func isSpaceOrTab(_ u: UInt16) -> Bool { u == space || u == tab }

    static func isDigit(_ u: UInt16) -> Bool { (0x30...0x39).contains(u) }

    static func isASCIILetter(_ u: UInt16) -> Bool { (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) }

    /// Unicode whitespace for a single UTF-16 unit. Surrogates are never whitespace.
    static func isWhitespace(_ u: UInt16) -> Bool {
        if u < 0x80 { return u == space || (0x09...0x0D).contains(u) }
        guard let scalar = Unicode.Scalar(UInt32(u)) else { return false }
        return scalar.properties.isWhitespace
    }

    /// ASCII punctuation, the characters a backslash escapes.
    static func isASCIIPunctuation(_ u: UInt16) -> Bool {
        switch u {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: true
        default: false
        }
    }

    /// Unicode punctuation or symbol for a single UTF-16 unit, CommonMark's notion of
    /// punctuation for flanking. Surrogates count as letters.
    static func isPunctuation(_ u: UInt16) -> Bool {
        if u < 0x80 { return isASCIIPunctuation(u) }
        guard let scalar = Unicode.Scalar(UInt32(u)) else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
            .initialPunctuation, .finalPunctuation, .otherPunctuation,
            .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// T-1: `[A-Za-z0-9_/-]`.
    static func isTagCharacter(_ u: UInt16) -> Bool {
        switch u {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2F, 0x2D: true
        default: false
        }
    }

    /// A character an autolink's scheme is made of after its first letter.
    static func isSchemeCharacter(_ u: UInt16) -> Bool {
        isASCIILetter(u) || isDigit(u) || u == plus || u == period || u == dash
    }
}

private enum Lines {
    /// Offset of the first unit of the line containing `offset` (`offset` may equal the count).
    static func lineStart(containing offset: Int, in units: [UInt16]) -> Int {
        var i = offset
        while i > 0, !U.isTerminator(units[i - 1]) { i -= 1 }
        return i
    }

    /// The end of the content of the line starting at `lineStart` and the start of the next
    /// line, treating `\r\n` as one terminator.
    static func lineEnd(from lineStart: Int, in units: [UInt16]) -> (contentEnd: Int, nextLineStart: Int) {
        var i = lineStart
        let total = units.count
        while i < total, !U.isTerminator(units[i]) { i += 1 }
        guard i < total else { return (i, i) }
        if units[i] == U.carriageReturn, i + 1 < total, units[i + 1] == U.newline { return (i, i + 2) }
        return (i, i + 1)
    }

    /// Start of the line after the one containing `offset`; the count when it is the last.
    static func nextLineStart(after offset: Int, in units: [UInt16]) -> Int {
        lineEnd(from: lineStart(containing: offset, in: units), in: units).nextLineStart
    }

    /// Whether the line starting at `lineStart` holds only spaces and tabs.
    static func isBlank(lineStart: Int, in units: [UInt16]) -> Bool {
        var i = lineStart
        while i < units.count, !U.isTerminator(units[i]) {
            if !U.isSpaceOrTab(units[i]) { return false }
            i += 1
        }
        return true
    }

    /// Whether `span` holds only spaces and tabs.
    static func isBlank(_ span: Range<Int>, in units: [UInt16]) -> Bool {
        span.allSatisfy { U.isSpaceOrTab(units[$0]) }
    }

    /// The start of the blank-line delimited paragraph containing the non-blank line at
    /// `lineStart`.
    static func paragraphStart(from lineStart: Int, in units: [UInt16]) -> Int {
        var start = lineStart
        while start > 0 {
            let previous = Lines.lineStart(containing: start - 1, in: units)
            if isBlank(lineStart: previous, in: units) { break }
            start = previous
        }
        return start
    }

    /// The end (a line start or the count) of the paragraph whose lines continue at `lineStart`.
    static func paragraphEnd(from lineStart: Int, in units: [UInt16]) -> Int {
        var end = lineStart
        while end < units.count, !isBlank(lineStart: end, in: units) {
            end = nextLineStart(after: end, in: units)
        }
        return end
    }

    /// Offset after up to three leading spaces.
    static func afterIndent(lineStart: Int, in units: [UInt16]) -> Int {
        var i = lineStart
        while i < units.count, i - lineStart < 3, units[i] == U.space { i += 1 }
        return i
    }

    /// Offset after up to three leading spaces, staying within `span`.
    static func afterIndent(_ span: Range<Int>, in units: [UInt16]) -> Int {
        var i = span.lowerBound
        while i < span.upperBound, i - span.lowerBound < 3, units[i] == U.space { i += 1 }
        return i
    }

    /// `span` without leading and trailing spaces and tabs; empty at its end when nothing is left.
    static func trimmed(_ span: Range<Int>, in units: [UInt16]) -> Range<Int> {
        var s = span.lowerBound
        var e = span.upperBound
        while s < e, U.isSpaceOrTab(units[s]) { s += 1 }
        while e > s, U.isSpaceOrTab(units[e - 1]) { e -= 1 }
        return s..<e
    }
}

private enum Fences {
    struct Marker {
        let character: UInt16
        let length: Int
    }

    /// The fence marker opening at `lineStart`, if the line is a fence line: at most three
    /// spaces, then three or more of one of `` ` `` or `~`. A backtick fence's info string may
    /// not contain a backtick.
    static func marker(lineStart: Int, in units: [UInt16]) -> Marker? {
        var i = Lines.afterIndent(lineStart: lineStart, in: units)
        guard i < units.count, units[i] == U.backtick || units[i] == U.tilde else { return nil }
        let character = units[i]
        var length = 0
        while i < units.count, units[i] == character {
            length += 1
            i += 1
        }
        guard length >= 3 else { return nil }
        if character == U.backtick {
            while i < units.count, !U.isTerminator(units[i]) {
                if units[i] == U.backtick { return nil }
                i += 1
            }
        }
        return Marker(character: character, length: length)
    }

    /// Whether the line at `lineStart` closes a block opened with `opening`: same character, at
    /// least as long, nothing but spaces and tabs after.
    static func closes(_ opening: Marker, lineStart: Int, in units: [UInt16]) -> Bool {
        var i = Lines.afterIndent(lineStart: lineStart, in: units)
        var length = 0
        while i < units.count, units[i] == opening.character {
            length += 1
            i += 1
        }
        guard length >= opening.length else { return false }
        while i < units.count, !U.isTerminator(units[i]) {
            if !U.isSpaceOrTab(units[i]) { return false }
            i += 1
        }
        return true
    }

    /// Whether the line at `lineStart` is shaped like a fence, opening or closing: three or more
    /// of one fence character after at most three spaces, whatever follows. Used to decide
    /// whether an edit may have changed fence state below it.
    static func looksLikeFence(lineStart: Int, in units: [UInt16]) -> Bool {
        var i = Lines.afterIndent(lineStart: lineStart, in: units)
        guard i < units.count, units[i] == U.backtick || units[i] == U.tilde else { return false }
        let character = units[i]
        var length = 0
        while i < units.count, units[i] == character {
            length += 1
            i += 1
        }
        return length >= 3
    }

    /// Every fenced block in `units`, as ranges of whole lines. An unclosed block runs to the end.
    static func blocks(in units: [UInt16]) -> [NSRange] {
        var blocks: [NSRange] = []
        var lineStart = 0
        let total = units.count
        while lineStart < total {
            let (_, next) = Lines.lineEnd(from: lineStart, in: units)
            if let opening = marker(lineStart: lineStart, in: units) {
                let block = endOfBlock(opening: opening, afterOpeningLine: next, in: units)
                blocks.append(NSRange(location: lineStart, length: block.end - lineStart))
                lineStart = block.end
            } else {
                lineStart = next
            }
        }
        return blocks
    }

    /// The offset just past the closing fence line (terminator included) of a block whose
    /// content begins at `start`, with that line's start, or the count and nil when the block
    /// is never closed.
    static func endOfBlock(opening: Marker, afterOpeningLine start: Int, in units: [UInt16]) -> (
        end: Int, closingLineStart: Int?
    ) {
        var lineStart = start
        while lineStart < units.count {
            let (_, next) = Lines.lineEnd(from: lineStart, in: units)
            if closes(opening, lineStart: lineStart, in: units) { return (next, lineStart) }
            lineStart = next
        }
        return (units.count, nil)
    }
}

/// The block shapes of one line's body (the line after its blockquote prefix).
private enum Blocks {
    /// The blockquote prefix of the line: how many `>` there are, where each is, and where the
    /// body after them starts. Each `>` may have up to three spaces before it and one after.
    static func quotePrefix(lineStart: Int, contentEnd: Int, in units: [UInt16]) -> (
        level: Int, markers: [Int], bodyStart: Int
    ) {
        var i = lineStart
        var markers: [Int] = []
        while true {
            let j = Lines.afterIndent(i..<contentEnd, in: units)
            guard j < contentEnd, units[j] == U.greaterThan else { break }
            markers.append(j)
            i = j + 1
            if i < contentEnd, U.isSpaceOrTab(units[i]) { i += 1 }
        }
        return (markers.count, markers, i)
    }

    /// The setext heading level `body` is an underline for: all `=` (1) or all `-` (2) after
    /// at most three spaces, trailing spaces allowed (ED-9).
    static func setextLevel(_ body: Range<Int>, in units: [UInt16]) -> Int? {
        let start = Lines.afterIndent(body, in: units)
        let run = Lines.trimmed(start..<body.upperBound, in: units)
        guard !run.isEmpty else { return nil }
        let character = units[run.lowerBound]
        guard character == U.equals || character == U.dash else { return nil }
        guard run.allSatisfy({ units[$0] == character }) else { return nil }
        return character == U.equals ? 1 : 2
    }

    /// Whether `body` is a thematic break: three or more of one of `-`, `*` or `_` after at
    /// most three spaces, with spaces and tabs allowed between and after (ED-8).
    static func isThematicBreak(_ body: Range<Int>, in units: [UInt16]) -> Bool {
        let start = Lines.afterIndent(body, in: units)
        guard start < body.upperBound else { return false }
        let character = units[start]
        guard character == U.dash || character == U.asterisk || character == U.underscore else { return false }
        var count = 0
        for i in start..<body.upperBound {
            if units[i] == character {
                count += 1
            } else if !U.isSpaceOrTab(units[i]) {
                return false
            }
        }
        return count >= 3
    }

    struct ATXHeading {
        let level: Int
        let hashes: Range<Int>
        let content: Range<Int>
    }

    /// The ATX heading `body` is, if it is one: `#` to `######` after at most three spaces,
    /// followed by a space, a tab or the line end.
    static func atxHeading(_ body: Range<Int>, in units: [UInt16]) -> ATXHeading? {
        let start = Lines.afterIndent(body, in: units)
        var i = start
        while i < body.upperBound, units[i] == U.hash { i += 1 }
        let level = i - start
        guard (1...6).contains(level) else { return nil }
        guard i == body.upperBound || U.isSpaceOrTab(units[i]) else { return nil }
        let hashes = start..<i
        while i < body.upperBound, U.isSpaceOrTab(units[i]) { i += 1 }
        return ATXHeading(level: level, hashes: hashes, content: Lines.trimmed(i..<body.upperBound, in: units))
    }

    struct ListItem {
        let level: Int
        let ordered: Bool
        /// The marker with the spaces after it.
        let marker: Range<Int>
        /// A task box `[ ]` or `[x]` right after the marker, and whether it is ticked.
        let task: (box: Range<Int>, isDone: Bool)?
        /// After the marker and any task box.
        let content: Range<Int>
    }

    /// The list item `body` is, if it is one: two leading spaces per nesting level, then `-`,
    /// `*`, `+` or one to nine digits and `.`, then a space or tab (ED-1).
    static func listItem(_ body: Range<Int>, in units: [UInt16]) -> ListItem? {
        var i = body.lowerBound
        while i < body.upperBound, units[i] == U.space { i += 1 }
        let level = (i - body.lowerBound) / 2
        let markerStart = i
        let ordered: Bool
        if i < body.upperBound, units[i] == U.dash || units[i] == U.asterisk || units[i] == U.plus {
            ordered = false
            i += 1
        } else {
            var digits = 0
            while i < body.upperBound, U.isDigit(units[i]), digits < 9 {
                digits += 1
                i += 1
            }
            guard digits > 0, i < body.upperBound, units[i] == U.period else { return nil }
            ordered = true
            i += 1
        }
        guard i < body.upperBound, U.isSpaceOrTab(units[i]) else { return nil }
        while i < body.upperBound, U.isSpaceOrTab(units[i]) { i += 1 }
        let marker = markerStart..<i
        var task: (box: Range<Int>, isDone: Bool)?
        if i + 3 <= body.upperBound, units[i] == U.openBracket, units[i + 2] == U.closeBracket,
            i + 3 == body.upperBound || U.isSpaceOrTab(units[i + 3])
        {
            let inside = units[i + 1]
            if inside == U.space {
                task = (i..<i + 3, false)
            } else if inside == U.lowerX || inside == U.upperX {
                task = (i..<i + 3, true)
            }
        }
        if task != nil {
            i += 3
            while i < body.upperBound, U.isSpaceOrTab(units[i]) { i += 1 }
        }
        return ListItem(level: level, ordered: ordered, marker: marker, task: task, content: i..<body.upperBound)
    }

    /// Whether `body` is a pipe-table separator row: cells of one or more `-` with an optional
    /// `:` at either end, separated by pipes, with at least one pipe (ED-1).
    static func isTableSeparator(_ body: Range<Int>, in units: [UInt16]) -> Bool {
        let row = Lines.trimmed(body, in: units)
        var i = row.lowerBound
        let end = row.upperBound
        var pipes = 0
        var cells = 0
        if i < end, units[i] == U.pipe {
            pipes += 1
            i += 1
        }
        while true {
            while i < end, U.isSpaceOrTab(units[i]) { i += 1 }
            if i == end { break }
            if units[i] == U.colon { i += 1 }
            var dashes = 0
            while i < end, units[i] == U.dash {
                dashes += 1
                i += 1
            }
            guard dashes > 0 else { return false }
            if i < end, units[i] == U.colon { i += 1 }
            while i < end, U.isSpaceOrTab(units[i]) { i += 1 }
            cells += 1
            if i == end { break }
            guard units[i] == U.pipe else { return false }
            pipes += 1
            i += 1
        }
        return pipes >= 1 && cells >= 1
    }

    /// The offsets of the unescaped pipes in `body`.
    static func pipes(in body: Range<Int>, of units: [UInt16]) -> [Int] {
        body.filter { units[$0] == U.pipe && ($0 == body.lowerBound || units[$0 - 1] != U.backslash) }
    }
}

/// The single pass over one range of text.
private struct Pass {
    let units: [UInt16]
    let base: Int
    var tokens: [Token] = []

    typealias Token = MarkdownScanner.Token

    /// What the line before the one being scanned was, for ED-8 and ED-9.
    private enum Previous {
        /// The start of the text, or a blank line (a quote line with nothing after its prefix
        /// counts).
        case boundary
        /// A paragraph line at `quoteLevel` whose body is `body`.
        case paragraph(quoteLevel: Int, body: Range<Int>)
        /// Any other line.
        case other
    }
    private var previous: Previous = .boundary

    /// Where a pipe table is, once a header row has been seen.
    private enum Table {
        /// The next line is the separator row (checked when the header row was scanned).
        case separatorNext(quoteLevel: Int)
        /// Lines with a pipe at this level are rows.
        case rows(quoteLevel: Int)
    }
    private var table: Table?

    init(units: [UInt16], base: Int) {
        self.units = units
        self.base = base
    }

    private func range(_ start: Int, _ end: Int) -> NSRange {
        NSRange(location: base + start, length: end - start)
    }

    private func range(_ span: Range<Int>) -> NSRange {
        range(span.lowerBound, span.upperBound)
    }

    mutating func run() {
        var lineStart = 0
        while lineStart < units.count {
            let (contentEnd, next) = Lines.lineEnd(from: lineStart, in: units)
            if let opening = Fences.marker(lineStart: lineStart, in: units) {
                let block = Fences.endOfBlock(opening: opening, afterOpeningLine: next, in: units)
                var markers = [range(lineStart, contentEnd)]
                var content = range(next, block.end)
                if let closing = block.closingLineStart {
                    markers.append(range(closing, Lines.lineEnd(from: closing, in: units).contentEnd))
                    content = range(next, closing)
                }
                tokens.append(
                    Token(kind: .fencedCode, range: range(lineStart, block.end), markers: markers, content: content))
                previous = .other
                table = nil
                lineStart = block.end
                continue
            }
            scanLine(lineStart: lineStart, contentEnd: contentEnd, nextLineStart: next)
            lineStart = next
        }
        sortTokens()
    }

    /// Tokens in order of location, an enclosing token before the ones inside it. Nested
    /// emphasis and a setext heading are found after what they contain, so the pass may have
    /// appended out of order.
    private mutating func sortTokens() {
        func ordered(_ a: Token, _ b: Token) -> Bool {
            a.range.location < b.range.location
                || (a.range.location == b.range.location && a.range.length >= b.range.length)
        }
        guard !zip(tokens, tokens.dropFirst()).allSatisfy({ ordered($0, $1) }) else { return }
        tokens = tokens.enumerated()
            .sorted { a, b in
                if a.element.range.location != b.element.range.location {
                    return a.element.range.location < b.element.range.location
                }
                if a.element.range.length != b.element.range.length {
                    return a.element.range.length > b.element.range.length
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: Blocks

    private mutating func scanLine(lineStart: Int, contentEnd: Int, nextLineStart: Int) {
        let prefix = Blocks.quotePrefix(lineStart: lineStart, contentEnd: contentEnd, in: units)
        let body = prefix.bodyStart..<contentEnd
        if prefix.level > 0 {
            tokens.append(
                Token(
                    kind: .blockquote(level: prefix.level), range: range(lineStart, contentEnd),
                    markers: prefix.markers.map { range($0, $0 + 1) }, content: range(body)))
        }
        if Lines.isBlank(body, in: units) {
            previous = .boundary
            table = nil
            return
        }

        // ED-9: an underline directly under a paragraph line at the same quote level.
        if case .paragraph(let level, let paragraphBody) = previous, level == prefix.level,
            let headingLevel = Blocks.setextLevel(body, in: units)
        {
            let underline = Lines.trimmed(body, in: units)
            tokens.append(
                Token(
                    kind: .heading(level: headingLevel), range: range(paragraphBody.lowerBound, contentEnd),
                    markers: [range(underline)], content: range(Lines.trimmed(paragraphBody, in: units))))
            previous = .other
            table = nil
            return
        }

        // The separator row announced by the header row above it.
        if case .separatorNext(let level) = table, level == prefix.level {
            let row = Lines.trimmed(body, in: units)
            tokens.append(
                Token(
                    kind: .tableSeparator, range: range(row),
                    markers: Blocks.pipes(in: row, of: units).map { range($0, $0 + 1) }, content: range(row)))
            table = .rows(quoteLevel: level)
            previous = .other
            return
        }

        // ED-8: a break starts the text or follows a blank line.
        if case .boundary = previous, Blocks.isThematicBreak(body, in: units) {
            let rule = Lines.trimmed(body, in: units)
            tokens.append(
                Token(
                    kind: .thematicBreak, range: range(rule), markers: [range(rule)],
                    content: range(rule.upperBound, rule.upperBound)))
            previous = .other
            table = nil
            return
        }

        if let heading = Blocks.atxHeading(body, in: units) {
            tokens.append(
                Token(
                    kind: .heading(level: heading.level), range: range(heading.hashes.lowerBound, contentEnd),
                    markers: [range(heading.hashes)], content: range(heading.content)))
            scanInline(heading.content)
            previous = .other
            table = nil
            return
        }

        if let item = Blocks.listItem(body, in: units) {
            tokens.append(
                Token(
                    kind: .listItem(level: item.level, ordered: item.ordered),
                    range: range(item.marker.lowerBound, contentEnd), markers: [range(item.marker)],
                    content: range(item.content)))
            if let task = item.task {
                tokens.append(
                    Token(
                        kind: .taskBox(isDone: task.isDone), range: range(task.box),
                        markers: [
                            range(task.box.lowerBound, task.box.lowerBound + 1),
                            range(task.box.upperBound - 1, task.box.upperBound),
                        ],
                        content: range(task.box.lowerBound + 1, task.box.upperBound - 1)))
            }
            scanInline(item.content)
            previous = .other
            table = nil
            return
        }

        // A row of the table above, while lines keep a pipe.
        if case .rows(let level) = table, level == prefix.level, !Blocks.pipes(in: body, of: units).isEmpty {
            appendTableRow(body)
            previous = .other
            return
        }
        table = nil

        // A header row: the next line, at the same quote level, is a separator row.
        if nextLineStart < units.count {
            let nextEnd = Lines.lineEnd(from: nextLineStart, in: units).contentEnd
            let nextPrefix = Blocks.quotePrefix(lineStart: nextLineStart, contentEnd: nextEnd, in: units)
            if nextPrefix.level == prefix.level, Blocks.isTableSeparator(nextPrefix.bodyStart..<nextEnd, in: units) {
                appendTableRow(body)
                table = .separatorNext(quoteLevel: prefix.level)
                previous = .other
                return
            }
        }

        scanInline(body)
        previous = .paragraph(quoteLevel: prefix.level, body: body)
    }

    private mutating func appendTableRow(_ body: Range<Int>) {
        let row = Lines.trimmed(body, in: units)
        tokens.append(
            Token(
                kind: .tableRow, range: range(row), markers: Blocks.pipes(in: row, of: units).map { range($0, $0 + 1) },
                content: range(row)))
        scanInline(row)
    }

    // MARK: Inline

    /// Scans `span` (part of one line) left to right for inline tokens. Emphasis delimiters
    /// are collected as they are met and matched once the span is done, so a link's text has
    /// its own matching and never shares a delimiter with the text around it.
    private mutating func scanInline(_ span: Range<Int>) {
        var delimiters: [Delimiter] = []
        var i = span.lowerBound
        let end = span.upperBound
        while i < end {
            let u = units[i]
            switch u {
            case U.backslash:
                i += i + 1 < end && U.isASCIIPunctuation(units[i + 1]) ? 2 : 1
            case U.backtick:
                i = scanCodeSpan(at: i, contentEnd: end)
            case U.openBracket, U.bang:
                let afterWikilink = scanWikilink(at: i, contentEnd: end)
                if afterWikilink > i + 1 {
                    i = afterWikilink
                } else if let afterLink = scanLink(at: i, contentEnd: end) {
                    i = afterLink
                } else {
                    i += 1
                }
            case U.hash:
                i = scanTag(at: i, contentEnd: end)
            case U.lessThan:
                i = scanAutolink(at: i, contentEnd: end)
            case U.lowerH, U.upperH:
                i = scanBareURL(at: i, contentEnd: end)
            case U.asterisk, U.underscore, U.tilde:
                i = scanDelimiterRun(at: i, contentEnd: end, into: &delimiters)
            default:
                i += 1
            }
        }
        matchEmphasis(&delimiters)
    }

    /// Scans a backtick run at `start`. A run closed by one of the same length on this line is a
    /// code span; otherwise the run is literal. Returns the offset to continue from.
    private mutating func scanCodeSpan(at start: Int, contentEnd: Int) -> Int {
        var i = start
        while i < contentEnd, units[i] == U.backtick { i += 1 }
        let length = i - start
        var cursor = i
        while cursor < contentEnd {
            guard units[cursor] == U.backtick else {
                cursor += 1
                continue
            }
            var runEnd = cursor
            while runEnd < contentEnd, units[runEnd] == U.backtick { runEnd += 1 }
            if runEnd - cursor == length {
                tokens.append(
                    Token(
                        kind: .inlineCode, range: range(start, runEnd),
                        markers: [range(start, i), range(cursor, runEnd)], content: range(i, cursor)))
                return runEnd
            }
            cursor = runEnd
        }
        return i
    }

    /// Scans a `[[` (or `![[`) at `start`. Returns the offset to continue from: past the link
    /// when one closes on this line, otherwise one unit on.
    private mutating func scanWikilink(at start: Int, contentEnd: Int) -> Int {
        let isEmbed = units[start] == U.bang
        let open = isEmbed ? start + 1 : start
        guard open + 1 < contentEnd, units[open] == U.openBracket, units[open + 1] == U.openBracket else {
            return start + 1
        }
        let contentStart = open + 2
        var i = contentStart
        var pipe: Int?
        while i < contentEnd {
            let u = units[i]
            if u == U.closeBracket {
                guard i + 1 < contentEnd, units[i + 1] == U.closeBracket else { return start + 1 }
                break
            }
            if u == U.openBracket { return start + 1 }
            if u == U.pipe, pipe == nil { pipe = i }
            i += 1
        }
        guard i < contentEnd else { return start + 1 }
        let close = i + 2
        let targetEnd = pipe ?? i
        guard let target = trimmed(contentStart, targetEnd) else { return start + 1 }
        let label = pipe.flatMap { trimmed($0 + 1, i) }
        tokens.append(
            Token(
                kind: .wikilink(target: target, label: label, isEmbed: isEmbed), range: range(start, close),
                markers: [range(start, contentStart), range(i, close)], content: range(contentStart, i)))
        return close
    }

    /// Scans a `[` (or `![`) at `start` for a standard link `[text](url "title")` or image.
    /// Returns the offset past it, or nil when there is none here.
    private mutating func scanLink(at start: Int, contentEnd: Int) -> Int? {
        let isImage = units[start] == U.bang
        let open = isImage ? start + 1 : start
        guard open < contentEnd, units[open] == U.openBracket else { return nil }

        // The text: brackets inside must balance.
        var depth = 0
        var close: Int?
        var j = open + 1
        while j < contentEnd {
            let u = units[j]
            if u == U.backslash {
                j += 2
                continue
            }
            if u == U.openBracket {
                depth += 1
            } else if u == U.closeBracket {
                if depth == 0 {
                    close = j
                    break
                }
                depth -= 1
            }
            j += 1
        }
        guard let close, close + 1 < contentEnd, units[close + 1] == U.openParen else { return nil }

        // The destination: `<...>` or a run without whitespace whose parentheses balance.
        var k = close + 2
        while k < contentEnd, U.isSpaceOrTab(units[k]) { k += 1 }
        let url: Range<Int>
        if k < contentEnd, units[k] == U.lessThan {
            var m = k + 1
            while m < contentEnd, units[m] != U.greaterThan {
                if units[m] == U.lessThan { return nil }
                m += 1
            }
            guard m < contentEnd else { return nil }
            url = (k + 1)..<m
            k = m + 1
        } else {
            var m = k
            var parens = 0
            while m < contentEnd {
                let u = units[m]
                if U.isWhitespace(u) || u < 0x20 { break }
                if u == U.backslash {
                    m += 2
                    continue
                }
                if u == U.openParen {
                    parens += 1
                } else if u == U.closeParen {
                    if parens == 0 { break }
                    parens -= 1
                }
                m += 1
            }
            m = min(m, contentEnd)
            url = k..<m
            k = m
        }

        // An optional title in quotes or parentheses.
        var afterURL = k
        while afterURL < contentEnd, U.isSpaceOrTab(units[afterURL]) { afterURL += 1 }
        if afterURL > k, afterURL < contentEnd,
            units[afterURL] == U.quote || units[afterURL] == U.apostrophe || units[afterURL] == U.openParen
        {
            let closer = units[afterURL] == U.openParen ? U.closeParen : units[afterURL]
            var m = afterURL + 1
            while m < contentEnd, units[m] != closer {
                if units[m] == U.backslash { m += 1 }
                m += 1
            }
            guard m < contentEnd else { return nil }
            k = m + 1
            while k < contentEnd, U.isSpaceOrTab(units[k]) { k += 1 }
        } else {
            k = afterURL
        }
        guard k < contentEnd, units[k] == U.closeParen else { return nil }

        let end = k + 1
        tokens.append(
            Token(
                kind: .link(url: range(url), isImage: isImage), range: range(start, end),
                markers: [range(start, open + 1), range(close, end)], content: range(open + 1, close)))
        scanInline((open + 1)..<close)
        return end
    }

    /// Scans a `<` at `start` for an autolink `<scheme:...>`. Returns the offset to continue
    /// from: past the autolink, or one unit on.
    private mutating func scanAutolink(at start: Int, contentEnd: Int) -> Int {
        var i = start + 1
        guard i < contentEnd, U.isASCIILetter(units[i]) else { return start + 1 }
        i += 1
        while i < contentEnd, U.isSchemeCharacter(units[i]) { i += 1 }
        let schemeLength = i - start - 1
        guard (2...32).contains(schemeLength), i < contentEnd, units[i] == U.colon else { return start + 1 }
        i += 1
        while i < contentEnd, units[i] != U.greaterThan {
            let u = units[i]
            if U.isWhitespace(u) || u == U.lessThan || u < 0x20 { return start + 1 }
            i += 1
        }
        guard i < contentEnd else { return start + 1 }
        tokens.append(
            Token(
                kind: .autolink(url: range(start + 1, i)), range: range(start, i + 1),
                markers: [range(start, start + 1), range(i, i + 1)], content: range(start + 1, i)))
        return i + 1
    }

    /// Scans an `h` at `start` for a bare `http://` or `https://` URL: at the start of a line,
    /// after whitespace or after one of `*`, `_`, `~`, `(`; running to whitespace or `<`, with
    /// trailing punctuation and an unbalanced closing parenthesis left out. Returns the offset
    /// to continue from.
    private mutating func scanBareURL(at start: Int, contentEnd: Int) -> Int {
        if start > 0 {
            let before = units[start - 1]
            guard
                U.isWhitespace(before) || before == U.asterisk || before == U.underscore || before == U.tilde
                    || before == U.openParen
            else { return start + 1 }
        }
        var i = start
        guard matches("http", at: &i, contentEnd: contentEnd) else { return start + 1 }
        if i < contentEnd, units[i] == 0x73 || units[i] == 0x53 { i += 1 }
        guard matches("://", at: &i, contentEnd: contentEnd) else { return start + 1 }
        let pathStart = i
        var end = i
        while end < contentEnd, !U.isWhitespace(units[end]), units[end] != U.lessThan { end += 1 }
        while end > pathStart {
            let last = units[end - 1]
            switch last {
            case U.question, U.bang, U.period, U.comma, U.colon, U.semicolon, U.asterisk, U.underscore, U.tilde,
                U.apostrophe, U.quote:
                end -= 1
                continue
            case U.closeParen:
                let opens = (start..<end).filter { units[$0] == U.openParen }.count
                let closes = (start..<end).filter { units[$0] == U.closeParen }.count
                if closes > opens {
                    end -= 1
                    continue
                }
            default:
                break
            }
            break
        }
        guard end > pathStart else { return start + 1 }
        tokens.append(Token(kind: .bareURL(url: range(start, end)), range: range(start, end)))
        return end
    }

    /// Whether `literal` (ASCII, matched case-insensitively) is at `i`; advances `i` past it.
    private func matches(_ literal: String, at i: inout Int, contentEnd: Int) -> Bool {
        var j = i
        for unit in literal.utf16 {
            guard j < contentEnd else { return false }
            let u = units[j]
            let folded = U.isASCIILetter(u) ? u | 0x20 : u
            guard folded == unit else { return false }
            j += 1
        }
        i = j
        return true
    }

    /// Scans a `#` at `start`. A tag needs a line start or whitespace before it and at least one
    /// tag character after (T-1). Returns the offset to continue from.
    private mutating func scanTag(at start: Int, contentEnd: Int) -> Int {
        guard start == 0 || U.isWhitespace(units[start - 1]) else { return start + 1 }
        var i = start + 1
        while i < contentEnd, U.isTagCharacter(units[i]) { i += 1 }
        guard i > start + 1 else { return start + 1 }
        tokens.append(
            Token(
                kind: .tag(name: range(start + 1, i)), range: range(start, i), markers: [range(start, start + 1)],
                content: range(start + 1, i)))
        return i
    }

    /// `[start, end)` without leading and trailing whitespace; nil when nothing is left.
    private func trimmed(_ start: Int, _ end: Int) -> NSRange? {
        var s = start
        var e = end
        while s < e, U.isWhitespace(units[s]) { s += 1 }
        while e > s, U.isWhitespace(units[e - 1]) { e -= 1 }
        return s < e ? range(s, e) : nil
    }

    // MARK: Emphasis

    /// A run of `*`, `_` or `~` and what CommonMark's flanking rules let it do.
    private struct Delimiter {
        let character: UInt16
        let start: Int
        let length: Int
        let canOpen: Bool
        let canClose: Bool
        /// Units used up as a closer, from the front of the run.
        var usedAtFront = 0
        /// Units used up as an opener, from the back of the run.
        var usedAtBack = 0
        /// False once the run can no longer take part: used up, or inside a matched pair.
        var active = true

        var remaining: Int { length - usedAtFront - usedAtBack }
    }

    /// Records the delimiter run at `start` and returns the offset after it. A `~` run counts
    /// only when it is exactly two long.
    private func scanDelimiterRun(at start: Int, contentEnd: Int, into delimiters: inout [Delimiter]) -> Int {
        let character = units[start]
        var end = start
        while end < contentEnd, units[end] == character { end += 1 }
        let length = end - start
        if character == U.tilde, length != 2 { return end }

        let before = start > 0 ? units[start - 1] : U.space
        let after = end < units.count ? units[end] : U.space
        let leftFlanking =
            !U.isWhitespace(after) && (!U.isPunctuation(after) || U.isWhitespace(before) || U.isPunctuation(before))
        let rightFlanking =
            !U.isWhitespace(before) && (!U.isPunctuation(before) || U.isWhitespace(after) || U.isPunctuation(after))
        let canOpen: Bool
        let canClose: Bool
        if character == U.underscore {
            canOpen = leftFlanking && (!rightFlanking || U.isPunctuation(before))
            canClose = rightFlanking && (!leftFlanking || U.isPunctuation(after))
        } else {
            canOpen = leftFlanking
            canClose = rightFlanking
        }
        guard canOpen || canClose else { return end }
        delimiters.append(
            Delimiter(character: character, start: start, length: length, canOpen: canOpen, canClose: canClose))
        return end
    }

    /// CommonMark's delimiter matching: each closer takes the nearest opener of its character
    /// before it, two units each for bold (or strikethrough) when both runs have two or more,
    /// one for italic, and the delimiters between them are out of play. The "multiple of 3"
    /// rule keeps `*foo**bar*` from pairing the wrong runs.
    private mutating func matchEmphasis(_ delimiters: inout [Delimiter]) {
        guard delimiters.count >= 2 else { return }
        for closerIndex in 1..<delimiters.count where delimiters[closerIndex].canClose {
            var openerIndex = closerIndex - 1
            while delimiters[closerIndex].remaining > 0, openerIndex >= 0 {
                let opener = delimiters[openerIndex]
                let closer = delimiters[closerIndex]
                guard opener.active, opener.canOpen, opener.remaining > 0, opener.character == closer.character,
                    !oddMatch(opener, closer)
                else {
                    openerIndex -= 1
                    continue
                }
                let use = closer.character == U.tilde || (opener.remaining >= 2 && closer.remaining >= 2) ? 2 : 1
                let openerEnd = opener.start + opener.length - opener.usedAtBack
                let openerMarker = (openerEnd - use)..<openerEnd
                let closerStart = closer.start + closer.usedAtFront
                let closerMarker = closerStart..<(closerStart + use)
                let emphasis: MarkdownScanner.Emphasis =
                    closer.character == U.tilde ? .strikethrough : use == 2 ? .bold : .italic
                tokens.append(
                    Token(
                        kind: .emphasis(emphasis), range: range(openerMarker.lowerBound, closerMarker.upperBound),
                        markers: [range(openerMarker), range(closerMarker)],
                        content: range(openerMarker.upperBound, closerMarker.lowerBound)))
                delimiters[openerIndex].usedAtBack += use
                delimiters[closerIndex].usedAtFront += use
                for between in (openerIndex + 1)..<closerIndex { delimiters[between].active = false }
                if delimiters[openerIndex].remaining == 0 { delimiters[openerIndex].active = false }
            }
            if delimiters[closerIndex].remaining == 0 { delimiters[closerIndex].active = false }
        }
    }

    /// CommonMark's rule of three: when either run could both open and close, the two may
    /// pair only if their lengths do not sum to a multiple of three, unless both are.
    private func oddMatch(_ opener: Delimiter, _ closer: Delimiter) -> Bool {
        (opener.canClose || closer.canOpen) && (opener.length + closer.length) % 3 == 0
            && !(opener.length % 3 == 0 && closer.length % 3 == 0)
    }
}
