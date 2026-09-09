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
/// What is stripped is every marker `MarkdownScanner` reports (ADR-0019 makes its tokens the
/// one source of markdown structure; the snippet never reads syntax itself):
/// - heading markers: the `#` run of an ATX heading or a setext underline (`## Title` shows as
///   `Title`);
/// - wikilinks: `[[Target]]` shows as `Target`, `[[Target|label]]` as `label`;
/// - embeds: `![[image.png]]` contributes nothing;
/// - code fences: the opening fence line, info string included, and the closing fence line
///   are dropped; the code between them is kept as written;
/// - emphasis markers: `**bold**` shows as `bold`, `~~gone~~` as `gone`; under CommonMark's
///   flanking rules `snake_case`, `2 * 3` and a lone `**` keep their characters;
/// - link syntax: `[text](url)` shows as `text`, `![alt](url)` as `alt`, `<url>` as `url`;
/// - list markers and task boxes (`- [x] done` shows as `done`), blockquote prefixes, table
///   pipes, and separator rows and thematic breaks whole.
/// Inline code keeps its backticks, tags their `#`. Nothing is stripped inside code.
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

    /// Unit ranges dropped entirely: the scanner's markers and its syntax-only tokens, put in
    /// order and merged by `collectSkips`.
    private var skips: [Range<Int>] = []

    init(units: [UInt16]) {
        self.units = units
        kept.reserveCapacity(units.count)
    }

    /// The snippet: the kept units cut to `BodySnippet.maxCharacters` and decoded. The walk
    /// stops two units past the cut, enough to see whether the cut would split a character.
    /// Nothing here walks graphemes: over 20k bodies that alone costs a fifth of PF-4.
    mutating func run() -> String {
        collectSkips()
        var pendingSpace = false
        var skip = 0
        var i = 0
        let stopAt = BodySnippet.maxCharacters + 2
        while i < units.count, kept.count < stopAt {
            if skip < skips.count, skips[skip].lowerBound == i {
                i = skips[skip].upperBound
                skip += 1
                continue
            }
            let u = units[i]
            i += 1
            if U.isWhitespace(u) {
                pendingSpace = !kept.isEmpty
                continue
            }
            if pendingSpace {
                kept.append(U.space)
                pendingSpace = false
            }
            kept.append(u)
        }
        return Transcoding.string(from: kept[..<Cut.position(in: kept, at: BodySnippet.maxCharacters)])
    }

    /// Turns the scanner's tokens into the ranges to drop. Tokens arrive in location order with
    /// an enclosing token first, so its closing marker lands after the markers of what it
    /// encloses (`**a *b* c**`, `[**x**](u)`); a sort, only when that happened, puts the ranges
    /// back in order, and a merge folds any overlap so the walk takes them one after another.
    private mutating func collectSkips() {
        let tokens = MarkdownScanner.scan(units, in: NSRange(location: 0, length: units.count))
        var sorted = true
        for token in tokens {
            switch token.kind {
            case .wikilink(let target, let label, let isEmbed):
                // The brackets, and with a `|` the target and the bar too, so the label shows.
                if isEmbed {
                    append(token.range, &sorted)
                } else {
                    let shown = label ?? target
                    let start = token.range.location
                    let end = start + token.range.length
                    append(start..<shown.location, &sorted)
                    append((shown.location + shown.length)..<end, &sorted)
                }
            case .taskBox, .tableSeparator, .thematicBreak:
                // A reader sees a control or a rule, not text: the whole token goes.
                append(token.range, &sorted)
            case .heading, .fencedCode, .emphasis, .link, .autolink, .listItem, .blockquote, .tableRow:
                for marker in token.markers { append(marker, &sorted) }
            case .tag, .inlineCode, .bareURL:
                break
            }
        }
        guard !skips.isEmpty else { return }
        if !sorted { skips.sort { $0.lowerBound < $1.lowerBound } }
        var last = 0
        for index in 1..<skips.count {
            if skips[index].lowerBound <= skips[last].upperBound {
                skips[last] = skips[last].lowerBound..<max(skips[last].upperBound, skips[index].upperBound)
            } else {
                last += 1
                skips[last] = skips[index]
            }
        }
        skips.removeSubrange((last + 1)...)
    }

    private mutating func append(_ range: NSRange, _ sorted: inout Bool) {
        append(range.location..<(range.location + range.length), &sorted)
    }

    private mutating func append(_ range: Range<Int>, _ sorted: inout Bool) {
        guard !range.isEmpty else { return }
        if let previous = skips.last, previous.lowerBound > range.lowerBound { sorted = false }
        skips.append(range)
    }
}

private enum U {
    static let space: UInt16 = 0x20
    static let zeroWidthJoiner: UInt16 = 0x200D

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
