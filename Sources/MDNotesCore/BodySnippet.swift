import Foundation

/// The single-line body snippet a list row shows next to the title and date (S-6).
///
/// A snippet is the start of the note as plain text, flattened onto one line: markdown syntax
/// is stripped, every run of whitespace, newlines included, becomes a single space, and the
/// result is trimmed and cut to `maxCharacters`. Case and punctuation are the file's own; the
/// snippet is for display, not search, so it is never folded. Only the first `scanCharacters`
/// UTF-16 units of a body are examined, so a 1 MB note costs the same as a short one (PF-4),
/// and all of this happens once, when the index is built; a query never touches it (PF-2).
///
/// What is stripped, using `MarkdownScanner`'s tokens for everything it recognises:
/// - heading markers: the `#` run opening an ATX heading (`## Title` shows as `Title`);
/// - wikilinks: `[[Target]]` shows as `Target`, `[[Target|label]]` as `label`;
/// - embeds: `![[image.png]]` contributes nothing;
/// - code fences: the opening fence line, info string included, and the closing fence line
///   are dropped; the code between them is kept as written;
/// - emphasis markers: `*`, `**`, `_` and `__` runs that could open or close emphasis under
///   CommonMark's flanking rules (`**bold**` shows as `bold`), so `snake_case`, `2 * 3` and a
///   `* bullet` keep their characters. Nothing is stripped inside inline code or fenced code.
public enum BodySnippet {
    /// Longest snippet produced, in UTF-16 units, so at most that many characters; the cut never
    /// splits a character. Wider than any row can show, so truncation is the row's decision, not
    /// the index's.
    public static let maxCharacters = 200

    /// How far into a body to look, in UTF-16 units, before giving up.
    public static let scanCharacters = 2048

    /// The snippet for `body`. Empty when the body is empty, all whitespace, or nothing but
    /// stripped syntax.
    public static func make(from body: String) -> String {
        var stripper = Stripper(units: Transcoding.utf16Prefix(of: body, maxUnits: scanCharacters))
        return stripper.run()
    }
}

// MARK: - Implementation

private enum Transcoding {
    /// The first `maxUnits` UTF-16 units of `text`, never ending inside a surrogate pair.
    /// Decoded from the UTF-8 view by hand: a native string's `utf16` view transcodes on every
    /// access, which over 20k bodies is a visible share of the build (PF-4).
    static func utf16Prefix(of text: String, maxUnits: Int) -> [UInt16] {
        var units: [UInt16] = []
        units.reserveCapacity(min(text.utf8.count, maxUnits))
        var scalar: UInt32 = 0
        var continuation = 0
        for byte in text.utf8 {
            if units.count >= maxUnits { break }
            if byte < 0x80 {
                units.append(UInt16(byte))
            } else if byte & 0xC0 == 0x80 {
                scalar = (scalar << 6) | UInt32(byte & 0x3F)
                continuation -= 1
                if continuation == 0 {
                    if scalar >= 0x10000 {
                        guard units.count + 2 <= maxUnits else { break }
                        let v = scalar - 0x10000
                        units.append(UInt16(0xD800 + (v >> 10)))
                        units.append(UInt16(0xDC00 + (v & 0x3FF)))
                    } else {
                        units.append(UInt16(scalar))
                    }
                }
            } else if byte & 0xE0 == 0xC0 {
                scalar = UInt32(byte & 0x1F)
                continuation = 1
            } else if byte & 0xF0 == 0xE0 {
                scalar = UInt32(byte & 0x0F)
                continuation = 2
            } else {
                scalar = UInt32(byte & 0x07)
                continuation = 3
            }
        }
        return units
    }

    /// The string spelled by `units`, transcoded to UTF-8 by hand: `String(decoding:as:
    /// UTF16.self)` over an array slice takes the stdlib's generic parser, which over 20k
    /// bodies costs more than everything else here together. A lone surrogate, which the
    /// walk never produces, becomes U+FFFD.
    static func string(from units: ArraySlice<UInt16>) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(units.count)
        var i = units.startIndex
        while i < units.endIndex {
            let u = units[i]
            i += 1
            var scalar = UInt32(u)
            if UTF16.isLeadSurrogate(u) {
                if i < units.endIndex, UTF16.isTrailSurrogate(units[i]) {
                    scalar = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(units[i]) - 0xDC00)
                    i += 1
                } else {
                    scalar = 0xFFFD
                }
            } else if UTF16.isTrailSurrogate(u) {
                scalar = 0xFFFD
            }
            switch scalar {
            case 0..<0x80:
                bytes.append(UInt8(scalar))
            case 0x80..<0x800:
                bytes.append(UInt8(0xC0 | (scalar >> 6)))
                bytes.append(UInt8(0x80 | (scalar & 0x3F)))
            case 0x800..<0x10000:
                bytes.append(UInt8(0xE0 | (scalar >> 12)))
                bytes.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
                bytes.append(UInt8(0x80 | (scalar & 0x3F)))
            default:
                bytes.append(UInt8(0xF0 | (scalar >> 18)))
                bytes.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
                bytes.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
                bytes.append(UInt8(0x80 | (scalar & 0x3F)))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// One pass over the scanned units, keeping the text a reader would see.
private struct Stripper {
    let units: [UInt16]
    var kept: [UInt16] = []

    /// Unit ranges dropped entirely, in order, non-overlapping.
    private var skips: [Range<Int>] = []
    /// Unit ranges (code) inside which emphasis markers are literal, in order.
    private var literal: [Range<Int>] = []

    init(units: [UInt16]) {
        self.units = units
        kept.reserveCapacity(units.count)
    }

    /// The snippet: the kept units cut to `BodySnippet.maxCharacters` and decoded. The walk
    /// stops two units past the cut, enough to see whether the cut would split a character.
    /// Nothing here walks graphemes: over 20k bodies that alone costs a fifth of PF-4.
    mutating func run() -> String {
        collectEdits()
        var pendingSpace = false
        var skip = 0
        var lit = 0
        var i = 0
        let stopAt = BodySnippet.maxCharacters + 2
        while i < units.count, kept.count < stopAt {
            if skip < skips.count, skips[skip].lowerBound == i {
                i = skips[skip].upperBound
                skip += 1
                continue
            }
            while lit < literal.count, literal[lit].upperBound <= i { lit += 1 }
            let inCode = lit < literal.count && literal[lit].contains(i)
            let u = units[i]
            if !inCode, u == U.asterisk || u == U.underscore {
                var end = i + 1
                while end < units.count, units[end] == u { end += 1 }
                if !Emphasis.isDelimiterRun(u, i..<end, in: units) {
                    if pendingSpace {
                        kept.append(U.space)
                        pendingSpace = false
                    }
                    kept.append(contentsOf: units[i..<end])
                }
                i = end
                continue
            }
            if U.isWhitespace(u) {
                pendingSpace = !kept.isEmpty
                i += 1
                continue
            }
            if pendingSpace {
                kept.append(U.space)
                pendingSpace = false
            }
            kept.append(u)
            i += 1
        }
        return Transcoding.string(from: kept[..<Cut.position(in: kept, at: BodySnippet.maxCharacters)])
    }

    /// Turns the scanner's tokens into skip and literal ranges.
    private mutating func collectEdits() {
        let tokens = MarkdownScanner.scan(units, in: NSRange(location: 0, length: units.count))
        for token in tokens {
            let start = token.range.location
            let end = start + token.range.length
            switch token.kind {
            case .heading:
                // The `#` run of an ATX heading, or the underline of a setext one (ED-9).
                for marker in token.markers {
                    skips.append(marker.location..<(marker.location + marker.length))
                }
            case .wikilink(let target, let label, let isEmbed):
                if isEmbed {
                    skips.append(start..<end)
                } else {
                    let shown = label ?? target
                    skips.append(start..<shown.location)
                    skips.append((shown.location + shown.length)..<end)
                }
            case .inlineCode:
                literal.append(start..<end)
            case .fencedCode:
                let openingEnd = Lines.nextLineStart(after: start, in: units, limit: end)
                skips.append(start..<openingEnd)
                let closingStart = Lines.lastLineStart(before: end, in: units, floor: openingEnd)
                if closingStart >= openingEnd, Fences.isClosingLine(closingStart, end, in: units) {
                    literal.append(openingEnd..<closingStart)
                    skips.append(closingStart..<end)
                } else {
                    literal.append(openingEnd..<end)
                }
            case .tag, .emphasis, .link, .autolink, .bareURL, .listItem, .taskBox, .blockquote, .tableRow,
                .tableSeparator, .thematicBreak:
                break
            }
        }
    }
}

private enum U {
    static let space: UInt16 = 0x20
    static let tab: UInt16 = 0x09
    static let newline: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let hash: UInt16 = 0x23
    static let asterisk: UInt16 = 0x2A
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let tilde: UInt16 = 0x7E
    static let zeroWidthJoiner: UInt16 = 0x200D

    static func isTerminator(_ u: UInt16) -> Bool { u == newline || u == carriageReturn }

    /// Unicode `White_Space` for a single UTF-16 unit, spelled out because the property lookup
    /// per unit over 20k bodies is a visible share of the build (PF-4). Surrogates are never
    /// whitespace.
    static func isWhitespace(_ u: UInt16) -> Bool {
        if u < 0x80 { return u == space || (0x09...0x0D).contains(u) }
        switch u {
        case 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// Unicode punctuation or symbol for a single UTF-16 unit, CommonMark's notion of
    /// punctuation for flanking. Surrogates are treated as letters.
    static func isPunctuation(_ u: UInt16) -> Bool {
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
}

private enum Cut {
    /// The largest offset at or before `limit` that does not split a character: never inside a
    /// surrogate pair, before a combining mark, format character (ZWJ, variation selector) or
    /// emoji modifier, or after a ZWJ. Regional-indicator pairs and conjoining jamo are not
    /// handled; a snippet is display text a row truncates long before this point.
    static func position(in units: [UInt16], at limit: Int) -> Int {
        guard units.count > limit else { return units.count }
        var cut = limit
        while cut > 0 {
            if UTF16.isTrailSurrogate(units[cut]) {
                cut -= 1
                continue
            }
            if units[cut - 1] == U.zeroWidthJoiner || extends(at: cut, in: units) {
                cut -= 1
                continue
            }
            break
        }
        return cut
    }

    /// Whether the scalar starting at `offset` continues the character before it.
    private static func extends(at offset: Int, in units: [UInt16]) -> Bool {
        let scalar: Unicode.Scalar?
        if UTF16.isLeadSurrogate(units[offset]) {
            guard offset + 1 < units.count, UTF16.isTrailSurrogate(units[offset + 1]) else { return false }
            scalar = UTF16.decode(UTF16.EncodedScalar([units[offset], units[offset + 1]]))
        } else {
            scalar = Unicode.Scalar(UInt32(units[offset]))
        }
        guard let scalar else { return false }
        if (0x1F3FB...0x1F3FF).contains(scalar.value) { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: return true
        default: return false
        }
    }
}

private enum Lines {
    /// Start of the line after the one starting at `lineStart`, capped at `limit`; `\r\n` is
    /// one terminator.
    static func nextLineStart(after lineStart: Int, in units: [UInt16], limit: Int) -> Int {
        var i = lineStart
        while i < limit, !U.isTerminator(units[i]) { i += 1 }
        guard i < limit else { return limit }
        if units[i] == U.carriageReturn, i + 1 < limit, units[i + 1] == U.newline { return i + 2 }
        return i + 1
    }

    /// Start of the last line whose content ends at or before `end` (ignoring a terminator
    /// that `end` itself follows), never below `floor`.
    static func lastLineStart(before end: Int, in units: [UInt16], floor: Int) -> Int {
        var i = end
        if i > floor, units[i - 1] == U.newline { i -= 1 }
        if i > floor, units[i - 1] == U.carriageReturn { i -= 1 }
        while i > floor, !U.isTerminator(units[i - 1]) { i -= 1 }
        return i
    }
}

private enum Fences {
    /// Whether `[lineStart, end)` is a closing fence line: at most three spaces, three or more
    /// of one fence character, then only spaces and tabs and a terminator.
    static func isClosingLine(_ lineStart: Int, _ end: Int, in units: [UInt16]) -> Bool {
        var i = lineStart
        while i < end, i - lineStart < 3, units[i] == U.space { i += 1 }
        guard i < end, units[i] == U.backtick || units[i] == U.tilde else { return false }
        let character = units[i]
        var length = 0
        while i < end, units[i] == character {
            length += 1
            i += 1
        }
        guard length >= 3 else { return false }
        while i < end, !U.isTerminator(units[i]) {
            if units[i] != U.space, units[i] != U.tab { return false }
            i += 1
        }
        return true
    }
}

private enum Emphasis {
    /// CommonMark's flanking rules: whether the run of `character` at `run` could open or close
    /// emphasis, in which case a reader never sees it.
    static func isDelimiterRun(_ character: UInt16, _ run: Range<Int>, in units: [UInt16]) -> Bool {
        let before = run.lowerBound > 0 ? units[run.lowerBound - 1] : nil
        let after = run.upperBound < units.count ? units[run.upperBound] : nil
        let beforeWhitespace = before.map(U.isWhitespace) ?? true
        let afterWhitespace = after.map(U.isWhitespace) ?? true
        let beforePunctuation = before.map(U.isPunctuation) ?? false
        let afterPunctuation = after.map(U.isPunctuation) ?? false

        let leftFlanking =
            !afterWhitespace && (!afterPunctuation || beforeWhitespace || beforePunctuation)
        let rightFlanking =
            !beforeWhitespace && (!beforePunctuation || afterWhitespace || afterPunctuation)

        if character == U.asterisk { return leftFlanking || rightFlanking }
        let canOpen = leftFlanking && (!rightFlanking || beforePunctuation)
        let canClose = rightFlanking && (!leftFlanking || afterPunctuation)
        return canOpen || canClose
    }
}
