import Foundation

/// One left-to-right pass over markdown text producing the ranges the editor styles (E-2) and
/// the link and tag indexes read (K-1, T-1): ATX headings, `[[wikilinks]]` and `![[embeds]]`,
/// `#tags`, inline code spans and fenced code blocks. Nothing else is recognised; there is no
/// tree, no inline emphasis, no lists. Ranges are UTF-16 offsets into the text (`NSRange`), the
/// coordinate system of `NSTextStorage`, so the editor applies them without conversion.
///
/// The pass is line-oriented. A fence line (three backticks or `~~~`, at most three spaces indented)
/// opens a fenced block that runs to the matching closing fence or the end of the text; nothing
/// inside is a heading, link, tag or code span. Outside fences each line is scanned for a
/// heading (`#` to `######` at line start followed by a space, a tab or the end of the line),
/// then left to right for code spans, links and tags, each of which is confined to its line.
/// A code span, once opened by a backtick run and closed by a run of the same length, hides
/// whatever it contains (T-1); an unclosed run is literal text.
///
/// `paragraphRange(in:editedRange:)` is the re-styling scope for E-3: the blank-line delimited
/// paragraph(s) around an edit, widened to any fenced block they touch, and to the end of the
/// text when an edited line is itself shaped like a fence so that a change in fence state
/// propagates. `scan(_:in:)` over that range reproduces exactly the tokens a full scan yields
/// there, because no token crosses a paragraph boundary except a fenced block and the range
/// already covers those whole.
public enum MarkdownScanner {
    /// What a token is, with the sub-ranges a consumer needs beyond the token's own range.
    public enum Kind: Equatable, Sendable {
        /// An ATX heading of `level` 1 to 6. The token range is the line without its terminator.
        case heading(level: Int)
        /// `[[target]]`, `[[target|label]]`, or with a leading `!` an embed (K-1). `target` and
        /// `label` are trimmed of whitespace; `label` is nil when there is no `|`.
        case wikilink(target: NSRange, label: NSRange?, isEmbed: Bool)
        /// `#name` (T-1). The token range includes the `#`; `name` is the range after it.
        case tag(name: NSRange)
        /// A backtick-delimited code span including its delimiters.
        case inlineCode
        /// A fenced code block from the start of the opening fence line to the end of the
        /// closing fence line (terminator included) or the end of the scanned text.
        case fencedCode
    }

    /// A recognised token and where it is.
    public struct Token: Equatable, Sendable {
        public let kind: Kind
        public let range: NSRange

        public init(kind: Kind, range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    // MARK: Scanning

    /// Every token in `text`, in order of appearance.
    public static func scan(_ text: String) -> [Token] {
        scan(text, in: NSRange(location: 0, length: text.utf16.count))
    }

    /// The tokens within `range` of `text`, in document coordinates. `range` must start at a
    /// line start that is outside any fenced block, which `paragraphRange(in:editedRange:)`
    /// guarantees; a fenced block left open inside the range ends at the range's end.
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
    /// text, or an empty range at a deletion) changed. It covers whole lines from the start of
    /// the paragraph containing the edit's first line to the end of the paragraph containing
    /// its last, where paragraphs are separated by blank lines; is widened to cover every fenced
    /// block it intersects; and runs to the end of the text when an edited line is shaped like
    /// a fence (three or more backticks or tildes after at most three spaces), since such a line
    /// may have opened or closed a block that changes everything below it. The reverse, an edit
    /// that turned a fence line into something else, is invisible here: the caller widens to the
    /// end of the text itself when the text it replaced carried fenced-code styling.
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

        // A fence-like line among the edited lines: state below may have changed.
        var fenceLike = false
        var cursor = start
        while cursor < end {
            let next = Lines.nextLineStart(after: cursor, in: units)
            if Fences.looksLikeFence(lineStart: cursor, in: units) {
                fenceLike = true
                break
            }
            cursor = next
        }

        // Widen to blank-line delimited paragraphs. A blank edited line is a separator and
        // joins nothing.
        if !Lines.isBlank(lineStart: start, in: units) {
            while start > 0 {
                let previous = Lines.lineStart(containing: start - 1, in: units)
                if Lines.isBlank(lineStart: previous, in: units) { break }
                start = previous
            }
        }
        if !Lines.isBlank(lineStart: Lines.lineStart(containing: max(end - 1, start), in: units), in: units) {
            while end < total, !Lines.isBlank(lineStart: end, in: units) {
                end = Lines.nextLineStart(after: end, in: units)
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
    static let hash: UInt16 = 0x23
    static let backtick: UInt16 = 0x60
    static let tilde: UInt16 = 0x7E
    static let bang: UInt16 = 0x21
    static let openBracket: UInt16 = 0x5B
    static let closeBracket: UInt16 = 0x5D
    static let pipe: UInt16 = 0x7C

    static func isTerminator(_ u: UInt16) -> Bool { u == newline || u == carriageReturn }

    /// Unicode whitespace for a single UTF-16 unit. Surrogates are never whitespace.
    static func isWhitespace(_ u: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(u)) else { return false }
        return scalar.properties.isWhitespace
    }

    /// T-1: `[A-Za-z0-9_/-]`.
    static func isTagCharacter(_ u: UInt16) -> Bool {
        switch u {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2F, 0x2D: true
        default: false
        }
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
            if units[i] != U.space, units[i] != U.tab { return false }
            i += 1
        }
        return true
    }

    /// Offset after up to three leading spaces.
    static func afterIndent(lineStart: Int, in units: [UInt16]) -> Int {
        var i = lineStart
        while i < units.count, i - lineStart < 3, units[i] == U.space { i += 1 }
        return i
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
            if units[i] != U.space, units[i] != U.tab { return false }
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
                let blockEnd = endOfBlock(opening: opening, afterOpeningLine: next, in: units)
                blocks.append(NSRange(location: lineStart, length: blockEnd - lineStart))
                lineStart = blockEnd
            } else {
                lineStart = next
            }
        }
        return blocks
    }

    /// The offset just past the closing fence line (terminator included) of a block whose
    /// content begins at `start`, or the count when the block is never closed.
    static func endOfBlock(opening: Marker, afterOpeningLine start: Int, in units: [UInt16]) -> Int {
        var lineStart = start
        while lineStart < units.count {
            let (_, next) = Lines.lineEnd(from: lineStart, in: units)
            if closes(opening, lineStart: lineStart, in: units) { return next }
            lineStart = next
        }
        return units.count
    }
}

/// The single pass over one range of text.
private struct Pass {
    let units: [UInt16]
    let base: Int
    var tokens: [Token] = []

    typealias Token = MarkdownScanner.Token

    init(units: [UInt16], base: Int) {
        self.units = units
        self.base = base
    }

    private func range(_ start: Int, _ end: Int) -> NSRange {
        NSRange(location: base + start, length: end - start)
    }

    mutating func run() {
        var lineStart = 0
        while lineStart < units.count {
            let (contentEnd, next) = Lines.lineEnd(from: lineStart, in: units)
            if let opening = Fences.marker(lineStart: lineStart, in: units) {
                let blockEnd = Fences.endOfBlock(opening: opening, afterOpeningLine: next, in: units)
                tokens.append(Token(kind: .fencedCode, range: range(lineStart, blockEnd)))
                lineStart = blockEnd
                continue
            }
            scanLine(lineStart: lineStart, contentEnd: contentEnd)
            lineStart = next
        }
    }

    private mutating func scanLine(lineStart: Int, contentEnd: Int) {
        if let level = headingLevel(lineStart: lineStart, contentEnd: contentEnd) {
            let hashStart = Lines.afterIndent(lineStart: lineStart, in: units)
            tokens.append(Token(kind: .heading(level: level), range: range(hashStart, contentEnd)))
        }
        var i = lineStart
        while i < contentEnd {
            let u = units[i]
            if u == U.backtick {
                i = scanCodeSpan(at: i, contentEnd: contentEnd)
            } else if u == U.openBracket || (u == U.bang && i + 1 < contentEnd && units[i + 1] == U.openBracket) {
                i = scanWikilink(at: i, contentEnd: contentEnd)
            } else if u == U.hash {
                i = scanTag(at: i, lineStart: lineStart, contentEnd: contentEnd)
            } else {
                i += 1
            }
        }
    }

    /// The level of the ATX heading on this line, or nil when the line is not one.
    private func headingLevel(lineStart: Int, contentEnd: Int) -> Int? {
        var i = Lines.afterIndent(lineStart: lineStart, in: units)
        var level = 0
        while i < contentEnd, units[i] == U.hash {
            level += 1
            i += 1
        }
        guard (1...6).contains(level) else { return nil }
        guard i == contentEnd || units[i] == U.space || units[i] == U.tab else { return nil }
        return level
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
                tokens.append(Token(kind: .inlineCode, range: range(start, runEnd)))
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
            Token(kind: .wikilink(target: target, label: label, isEmbed: isEmbed), range: range(start, close)))
        return close
    }

    /// Scans a `#` at `start`. A tag needs a line start or whitespace before it and at least one
    /// tag character after (T-1). Returns the offset to continue from.
    private mutating func scanTag(at start: Int, lineStart: Int, contentEnd: Int) -> Int {
        guard start == lineStart || U.isWhitespace(units[start - 1]) else { return start + 1 }
        var i = start + 1
        while i < contentEnd, U.isTagCharacter(units[i]) { i += 1 }
        guard i > start + 1 else { return start + 1 }
        tokens.append(Token(kind: .tag(name: range(start + 1, i)), range: range(start, i)))
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
}
