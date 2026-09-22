import Foundation

/// The editor's selection transforms (ED-16): Quote and Code Block, each acting on every whole
/// line a selection touches and each a toggle. Pure text work over the file's UTF-16 units, so
/// the editor only has to apply the result as one edit.
///
/// The lines a selection touches run from the line holding its first character to the line
/// holding its last: a selection that ends just after a line terminator (a triple-click, or a
/// drag to the start of the next line) does not touch the line after it. An empty selection
/// touches the caret's line. Lines end at `\n`, `\r` or `\r\n`, as `MarkdownScanner` reads them.
///
/// The result is a list of small replacements rather than one over the whole span, so text
/// that is not part of the transform is never replaced: the editor keeps what it shows beside
/// the file's text (display-only thumbnails, E-9) where it is.
public enum SelectionTransform {
    /// One replacement, in file indices of the text before the transform.
    public struct Edit: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String

        public init(range: NSRange, replacement: String) {
            self.range = range
            self.replacement = replacement
        }
    }

    /// A transform: its replacements, ascending and disjoint, and the selection afterwards in
    /// file indices of the text after them, covering the transformed lines from the first one's
    /// start to the last one's end (terminator excluded).
    public struct Result: Equatable, Sendable {
        public let edits: [Edit]
        public let selection: NSRange

        public init(edits: [Edit], selection: NSRange) {
            self.edits = edits
            self.selection = selection
        }
    }

    /// The prefix Quote adds and removes.
    public static let quotePrefix = "> "

    /// The fence line Code Block adds, without its terminator.
    public static let fence = "```"

    /// Quote: `> ` before every touched line, or, when every touched non-blank line already
    /// starts with `> ` (and there is at least one), one `> ` taken off each line that starts
    /// with it.
    public static func quote(_ units: [UInt16], selection: NSRange) -> Result {
        let lines = touchedLines(units, selection: selection)
        let prefix = Array(quotePrefix.utf16)
        let nonBlank = lines.filter { !isBlank($0, in: units) }
        let removing = !nonBlank.isEmpty && nonBlank.allSatisfy { starts($0, with: prefix, in: units) }
        var edits: [Edit] = []
        for line in lines {
            if removing {
                guard starts(line, with: prefix, in: units) else { continue }
                edits.append(Edit(range: NSRange(location: line.start, length: prefix.count), replacement: ""))
            } else {
                edits.append(Edit(range: NSRange(location: line.start, length: 0), replacement: quotePrefix))
            }
        }
        let first = lines[0].start
        let last = lines[lines.count - 1]
        let span = NSRange(location: first, length: last.contentEnd - first)
        return Result(edits: edits, selection: shifted(span, by: edits))
    }

    /// Code Block: when the touched lines are a fenced block, fences included, or lie inside
    /// one, that block's fence lines are removed (an unclosed block has only its opening one);
    /// otherwise a ```` ``` ```` line goes before the first touched line and another after the
    /// last. An added fence line ends with the touched lines' own terminator, `\n` when the last
    /// line has none.
    public static func codeBlock(_ units: [UInt16], selection: NSRange) -> Result {
        let lines = touchedLines(units, selection: selection)
        let first = lines[0]
        let last = lines[lines.count - 1]
        if let block = enclosingBlock(units, from: first.start, to: last.contentEnd) {
            return unfence(block, in: units)
        }
        let terminator = terminatorString(of: last, in: units) ?? terminatorString(of: first, in: units) ?? "\n"
        let opening = Edit(range: NSRange(location: first.start, length: 0), replacement: fence + terminator)
        let closing: Edit
        if last.next > last.contentEnd {
            closing = Edit(range: NSRange(location: last.next, length: 0), replacement: fence + terminator)
        } else {
            closing = Edit(range: NSRange(location: last.contentEnd, length: 0), replacement: terminator + fence)
        }
        let edits = [opening, closing]
        let shiftedEnd = last.contentEnd + (opening.replacement as NSString).length
        let closingEnd = shiftedEnd + (terminator as NSString).length + (fence as NSString).length
        return Result(edits: edits, selection: NSRange(location: first.start, length: closingEnd - first.start))
    }

    // MARK: - Lines

    /// A line: where it starts, where its content ends and where the next line starts (the
    /// count for the last line).
    struct Line: Equatable {
        let start: Int
        let contentEnd: Int
        let next: Int
    }

    /// Every line `selection` touches, in order; never empty.
    static func touchedLines(_ units: [UInt16], selection: NSRange) -> [Line] {
        let total = units.count
        let location = min(max(selection.location, 0), total)
        let end = min(location + max(selection.length, 0), total)
        let lastCharacter = end > location ? end - 1 : location
        let firstStart = lineStart(containing: location, in: units)
        let lastStart = lineStart(containing: lastCharacter, in: units)
        var lines: [Line] = []
        var start = firstStart
        while true {
            let line = self.line(from: start, in: units)
            lines.append(line)
            if start >= lastStart || line.next == start { break }
            start = line.next
        }
        return lines
    }

    /// The start of the line holding `offset`. The `\n` of a `\r\n` belongs to the line the
    /// `\r` ends.
    static func lineStart(containing offset: Int, in units: [UInt16]) -> Int {
        var i = offset
        if i > 0, i < units.count, units[i] == newline, units[i - 1] == carriageReturn { i -= 1 }
        while i > 0, !isTerminator(units[i - 1]) { i -= 1 }
        return i
    }

    static func line(from start: Int, in units: [UInt16]) -> Line {
        var i = start
        let total = units.count
        while i < total, !isTerminator(units[i]) { i += 1 }
        guard i < total else { return Line(start: start, contentEnd: i, next: i) }
        if units[i] == carriageReturn, i + 1 < total, units[i + 1] == newline {
            return Line(start: start, contentEnd: i, next: i + 2)
        }
        return Line(start: start, contentEnd: i, next: i + 1)
    }

    private static func isBlank(_ line: Line, in units: [UInt16]) -> Bool {
        (line.start..<line.contentEnd).allSatisfy { units[$0] == space || units[$0] == tab }
    }

    private static func starts(_ line: Line, with prefix: [UInt16], in units: [UInt16]) -> Bool {
        guard line.contentEnd - line.start >= prefix.count else { return false }
        return prefix.indices.allSatisfy { units[line.start + $0] == prefix[$0] }
    }

    private static func terminatorString(of line: Line, in units: [UInt16]) -> String? {
        guard line.next > line.contentEnd else { return nil }
        return String(utf16CodeUnits: Array(units[line.contentEnd..<line.next]), count: line.next - line.contentEnd)
    }

    // MARK: - Fenced blocks

    /// The fenced block, as `MarkdownScanner` reads it, whose lines hold every line from the one
    /// starting at `start` to the one ending at `end`, or nil. The scan covers only the
    /// paragraphs around the lines, widened to any fenced block they touch.
    private static func enclosingBlock(_ units: [UInt16], from start: Int, to end: Int) -> MarkdownScanner.Token? {
        let scope = MarkdownScanner.paragraphRange(
            in: units, editedRange: NSRange(location: start, length: end - start))
        for token in MarkdownScanner.scan(units, in: scope) {
            guard case .fencedCode = token.kind else { continue }
            let blockEnd = NSMaxRange(token.range)
            if token.range.location <= start, start < blockEnd, end <= blockEnd {
                return token
            }
        }
        return nil
    }

    /// Removes `block`'s fence lines: each with its terminator, or a closing fence that ends the
    /// text with the terminator before it. The selection covers the content lines left.
    private static func unfence(_ block: MarkdownScanner.Token, in units: [UInt16]) -> Result {
        var ranges: [NSRange] = []
        for marker in block.markers {
            let line = self.line(from: marker.location, in: units)
            if line.next > line.contentEnd || line.start == 0 {
                ranges.append(NSRange(location: line.start, length: line.next - line.start))
            } else {
                let previousEnd = self.line(from: lineStart(containing: line.start - 1, in: units), in: units)
                    .contentEnd
                ranges.append(NSRange(location: previousEnd, length: line.next - previousEnd))
            }
        }
        let merged = merge(ranges)
        let edits = merged.map { Edit(range: $0, replacement: "") }
        let content = block.content
        let contentLines = touchedLines(units, selection: content)
        var span = NSRange(location: content.location, length: 0)
        if content.length > 0, let lastLine = contentLines.last {
            span.length = lastLine.contentEnd - content.location
        }
        return Result(edits: edits, selection: shifted(span, by: edits))
    }

    /// `ranges` ascending with overlapping or touching ones joined.
    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// `range`, in the text before `edits`, in the text after them: each end moves by the net
    /// change of the edits before it; an end inside a removed range moves to where it was.
    private static func shifted(_ range: NSRange, by edits: [Edit]) -> NSRange {
        func map(_ index: Int, isStart: Bool) -> Int {
            var delta = 0
            for edit in edits {
                let editEnd = NSMaxRange(edit.range)
                let grown = (edit.replacement as NSString).length - edit.range.length
                if editEnd < index || (editEnd == index && (edit.range.length > 0 || !isStart)) {
                    delta += grown
                } else if edit.range.location < index {
                    delta += edit.range.location - index
                }
            }
            return index + delta
        }
        let start = map(range.location, isStart: true)
        let end = map(NSMaxRange(range), isStart: false)
        return NSRange(location: start, length: max(end - start, 0))
    }

    private static func isTerminator(_ unit: UInt16) -> Bool { unit == newline || unit == carriageReturn }

    private static let newline: UInt16 = 0x0A
    private static let carriageReturn: UInt16 = 0x0D
    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09
}
