import AppKit
import Foundation

/// Markdown from the RTF a pasteboard carries when it has no HTML (ED-13, ADR-0019): the
/// fallback after `HTMLToMarkdown`. It lives in the app layer because decoding RTF into an
/// attributed string (`NSAttributedString(rtf:)`) and reading font traits (`NSFont`) are AppKit
/// on macOS, and `MDNotesCore` is Foundation only.
///
/// RTF carries no structure beyond paragraphs, so what the conversion derives is what the
/// attributed string can say, in the forms `MarkdownScanner` recognises (ED-1):
/// - font traits: a bold font as `**x**`, an italic one as `*x*`, a strikethrough attribute as
///   `~~x~~`; a fixed-pitch font as a code span, or, when a whole paragraph is fixed-pitch, a
///   line of a fenced code block, consecutive such paragraphs making one block. Runs the reader
///   split on colour or font changes are merged first, whitespace at the edges of a run is kept
///   outside its markers, and markers close and reopen at every change of traits so they nest;
/// - a `.link` attribute as `[text](url)`, or `<url>` when the text is the URL; fragment-only
///   and `javascript:` links contribute their text;
/// - list markers: a paragraph whose style carries `NSTextList`s is an item, `- ` or `<n>. ` by
///   the innermost list's `isOrdered`, numbered from its `startingItemNumber` in the order the
///   items appear, nested by two spaces per list; lists are tight and a blank line separates
///   them from what is around them. TextEdit and Pages have no task items, so none are derived;
/// - paragraphs: a paragraph break is a line break, an empty paragraph a blank line (at most one
///   in a row), and two paragraphs with space between them in the source (`paragraphSpacing` on
///   the first or `paragraphSpacingBefore` on the second, Pages' body style) are separated by a
///   blank line; a line separator (`\line`, U+2028) is a line break inside the paragraph, in an
///   item continued under the item text.
/// Headings, blockquotes, tables and images have no RTF representation the reader exposes
/// (Pages exports a heading as a bigger bold paragraph, which arrives as bold text; attachments
/// travel as RTFD, not RTF), so they contribute only their text. Underline, colour, size, font
/// and indentation contribute nothing. Text is kept as it is, no escaping (ED-15), except that
/// every line loses its trailing whitespace and attachment characters (U+FFFC) go.
public enum RTFToMarkdown {
    /// The markdown for RTF `data`, or nil when it is no RTF the system can read (the caller then
    /// falls back to the pasteboard's plain text). Empty for RTF holding no text.
    public static func markdown(fromRTF data: Data) -> String? {
        var attributes: NSDictionary?
        guard let text = NSAttributedString(rtf: data, documentAttributes: &attributes) else { return nil }
        return markdown(from: text)
    }

    /// The markdown for an attributed string already decoded (from RTF, RTFD or any other rich
    /// source that ends up with fonts, links and text lists).
    public static func markdown(from text: NSAttributedString) -> String {
        var converter = Converter(text: text)
        converter.render()
        return converter.finish()
    }
}

// MARK: - Converter

/// One pass over the paragraphs into lines of markdown. Blank lines are entries of their own,
/// collapsed as they are added, so no construct needs to know what came before it beyond the
/// previous paragraph's kind.
private struct Converter {
    private let text: NSAttributedString
    private let string: NSString
    private var lines: [String] = []
    /// The lines of the fenced block being gathered, fenced when the block ends.
    private var codeBlock: [String]?
    /// The lists in force for the previous item, innermost last, with how many items each has
    /// had so far: the number of the next ordered item, and the way a nested list is told from
    /// a new one (the reader gives every paragraph of one list the same `NSTextList`).
    private var openLists: [(list: NSTextList, count: Int)] = []
    private var previous: Paragraph?

    init(text: NSAttributedString) {
        self.text = text
        self.string = text.string as NSString
    }

    // MARK: Paragraphs

    private enum Kind {
        case blank
        case prose
        case item
        case code
    }

    private struct Paragraph {
        var range: NSRange
        var kind: Kind
        var lists: [NSTextList]
        var spacingBefore: CGFloat
        var spacingAfter: CGFloat
    }

    mutating func render() {
        var location = 0
        while location < string.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            string.getParagraphStart(
                &start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let paragraph = classify(NSRange(location: start, length: contentsEnd - start), terminator: contentsEnd)
            render(paragraph)
            previous = paragraph
            location = end
        }
    }

    mutating func finish() -> String {
        endCodeBlock()
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func classify(_ range: NSRange, terminator: Int) -> Paragraph {
        let style =
            range.location < string.length
            ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            : nil
        let lists = style?.textLists ?? []
        var paragraph = Paragraph(
            range: range, kind: .blank, lists: lists, spacingBefore: style?.paragraphSpacingBefore ?? 0,
            spacingAfter: style?.paragraphSpacing ?? 0)
        if !lists.isEmpty {
            paragraph.kind = isBlank(range) ? .blank : .item
        } else if isBlank(range) {
            // An empty paragraph inside a fixed-pitch stretch is a blank line of the block.
            let fontAt = min(terminator, string.length - 1)
            let isCode =
                codeBlock != nil && fontAt >= 0
                && Self.traits(of: text.attributes(at: fontAt, effectiveRange: nil)).code
            paragraph.kind = isCode ? .code : .blank
        } else {
            paragraph.kind = isWhollyCode(range) ? .code : .prose
        }
        return paragraph
    }

    private func isBlank(_ range: NSRange) -> Bool {
        string.substring(with: range).unicodeScalars.allSatisfy { $0.properties.isWhitespace || $0 == "\u{FFFC}" }
    }

    /// Every non-whitespace character in a fixed-pitch font.
    private func isWhollyCode(_ range: NSRange) -> Bool {
        var wholly = true
        text.enumerateAttributes(in: range) { attributes, runRange, stop in
            let run = string.substring(with: runRange)
            guard run.unicodeScalars.contains(where: { !$0.properties.isWhitespace && $0 != "\u{FFFC}" }) else {
                return
            }
            if !Self.traits(of: attributes).code {
                wholly = false
                stop.pointee = true
            }
        }
        return wholly
    }

    private mutating func render(_ paragraph: Paragraph) {
        if paragraph.kind != .code { endCodeBlock() }
        // An empty paragraph inside a list keeps the list open, so numbering carries on after it.
        if paragraph.kind != .item, paragraph.lists.isEmpty { openLists.removeAll() }
        switch paragraph.kind {
        case .blank:
            blankLine()
        case .code:
            if codeBlock == nil {
                blankLine()
                codeBlock = []
            }
            let content = Self.clean(string.substring(with: paragraph.range))
            codeBlock? += content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        case .item:
            if previous?.kind != .item { blankLine() }
            item(paragraph)
        case .prose:
            switch previous?.kind {
            case .item:
                blankLine()
            case .prose where (previous?.spacingAfter ?? 0) > 0 || paragraph.spacingBefore > 0:
                blankLine()
            default:
                break
            }
            let rendered = inline(paragraph.range)
            guard !rendered.isEmpty else {
                blankLine()
                return
            }
            for line in rendered.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(Self.trimmingTrailingWhitespace(String(line)))
            }
        }
    }

    private mutating func blankLine() {
        guard let last = lines.last, !last.isEmpty else { return }
        lines.append("")
    }

    private mutating func endCodeBlock() {
        guard var block = codeBlock else { return }
        codeBlock = nil
        while block.last?.allSatisfy({ $0.isWhitespace }) == true { block.removeLast() }
        guard !block.isEmpty else { return }
        let longest = block.map(Self.longestBacktickRun).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        lines.append(fence)
        lines += block
        lines.append(fence)
        blankLine()
    }

    // MARK: Lists

    private mutating func item(_ paragraph: Paragraph) {
        let lists = paragraph.lists
        // Keep the open lists this item is still in; anything deeper or different starts afresh.
        var shared = 0
        while shared < min(openLists.count, lists.count), openLists[shared].list === lists[shared] { shared += 1 }
        // A different outermost list is a new list: a blank line keeps the two apart.
        if shared == 0, !openLists.isEmpty { blankLine() }
        openLists.removeSubrange(shared...)
        for list in lists[shared...] { openLists.append((list, 0)) }
        openLists[lists.count - 1].count += 1

        let list = lists[lists.count - 1]
        let number = list.startingItemNumber + openLists[lists.count - 1].count - 1
        var rendered = inline(paragraph.range)
        // Readers that keep the marker text in the string spell it as tab, marker, tab.
        if rendered.hasPrefix("\t"), let end = rendered.dropFirst().firstIndex(of: "\t") {
            let marker = list.marker(forItemNumber: number)
            let spelt = String(rendered[rendered.index(after: rendered.startIndex)..<end])
            if [marker, marker + ".", marker + ")"].contains(spelt) { rendered.removeSubrange(...end) }
        }
        rendered = rendered.trimmingCharacters(in: .whitespaces)
        guard !rendered.isEmpty else { return }

        let indent = String(repeating: "  ", count: lists.count - 1)
        let bullet = list.isOrdered ? "\(number). " : "- "
        let continuation = indent + String(repeating: " ", count: bullet.count)
        for (index, line) in rendered.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let content = Self.trimmingTrailingWhitespace(String(line))
            lines.append(index == 0 ? indent + bullet + content : continuation + content)
        }
    }

    // MARK: Inline

    private struct Traits: Equatable {
        var bold = false
        var italic = false
        var strike = false
        var code = false

        /// The emphasis markers wanted, in nesting order: bold outermost.
        var markers: [String] {
            (bold ? ["**"] : []) + (italic ? ["*"] : []) + (strike ? ["~~"] : [])
        }
    }

    private struct Run {
        var text: String
        var traits: Traits
        var link: String?
    }

    private static func traits(of attributes: [NSAttributedString.Key: Any]) -> Traits {
        var traits = Traits()
        if let font = attributes[.font] as? NSFont {
            let symbolic = font.fontDescriptor.symbolicTraits
            traits.bold = symbolic.contains(.bold)
            traits.italic = symbolic.contains(.italic)
            traits.code = symbolic.contains(.monoSpace) || font.isFixedPitch
        }
        if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { traits.strike = true }
        return traits
    }

    private static func link(of attributes: [NSAttributedString.Key: Any]) -> String? {
        let href: String
        switch attributes[.link] {
        case let url as URL: href = url.absoluteString
        case let string as String: href = string
        default: return nil
        }
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.lowercased().hasPrefix("javascript:") else {
            return nil
        }
        return trimmed
    }

    /// The paragraph's runs with equal traits and link merged.
    private func runs(in range: NSRange) -> [Run] {
        var runs: [Run] = []
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            let run = Run(
                text: Self.clean(string.substring(with: runRange)), traits: Self.traits(of: attributes),
                link: Self.link(of: attributes))
            guard !run.text.isEmpty else { return }
            if let last = runs.last, last.traits == run.traits, last.link == run.link {
                runs[runs.count - 1].text += run.text
            } else {
                runs.append(run)
            }
        }
        return runs
    }

    /// One paragraph as inline markdown; line separators inside it are newlines.
    private func inline(_ range: NSRange) -> String {
        var writer = InlineWriter()
        for run in runs(in: range) { writer.write(run) }
        return writer.finish()
    }

    /// Emits runs with emphasis markers as a stack: at a change of traits the markers no longer
    /// wanted are closed (and any above them reopened), whitespace between runs lands between
    /// closing and opening markers, and a link's brackets wrap its runs with the markers opened
    /// inside them closed before `]`.
    private struct InlineWriter {
        private var out = ""
        private var stack: [String] = []
        private var pendingWhitespace = ""
        private var link: (href: String, start: Int, depth: Int)?

        mutating func write(_ run: Run) {
            let scalars = run.text.unicodeScalars
            let leadingCount = scalars.prefix(while: { $0.properties.isWhitespace }).count
            guard leadingCount < scalars.count else {
                pendingWhitespace += run.text
                return
            }
            let trailingCount = scalars.reversed().prefix(while: { $0.properties.isWhitespace }).count
            let core = String(scalars.dropFirst(leadingCount).dropLast(trailingCount))
            pendingWhitespace += String(scalars.prefix(leadingCount))

            if let link, link.href != run.link {
                popMarkers(to: link.depth)
                closeLink()
            }
            // A code span takes no emphasis of its own: whatever is open stays open around it.
            let wanted = run.traits.code ? stack : run.traits.markers
            popMarkers(to: Self.sharedPrefix(stack, wanted))
            out += pendingWhitespace
            pendingWhitespace = ""
            if let href = run.link, link == nil {
                out += "["
                link = (href, out.utf8.count, stack.count)
            }
            for marker in wanted[stack.count...] {
                out += marker
                stack.append(marker)
            }
            out += run.traits.code ? Self.codeSpan(core) : core
            pendingWhitespace = String(scalars.suffix(trailingCount))
        }

        mutating func finish() -> String {
            if let link {
                popMarkers(to: link.depth)
                closeLink()
            }
            popMarkers(to: 0)
            return out
        }

        private mutating func popMarkers(to depth: Int) {
            while stack.count > depth { out += stack.removeLast() }
        }

        private mutating func closeLink() {
            guard let link else { return }
            self.link = nil
            let textBytes = out.utf8.count - link.start
            if out.utf8.suffix(textBytes).elementsEqual(link.href.utf8) {
                out.removeSubrange(out.utf8.index(out.utf8.endIndex, offsetBy: -(textBytes + 1))...)
                out += "<\(link.href)>"
            } else {
                out += "](\(Self.destination(link.href)))"
            }
        }

        private static func sharedPrefix(_ a: [String], _ b: [String]) -> Int {
            var count = 0
            while count < min(a.count, b.count), a[count] == b[count] { count += 1 }
            return count
        }

        /// A destination inside `(...)`: spaces and parentheses percent-encoded so the link ends
        /// where it should.
        private static func destination(_ href: String) -> String {
            href.replacing(" ", with: "%20").replacing("(", with: "%28").replacing(")", with: "%29")
        }

        private static func codeSpan(_ core: String) -> String {
            let content = core.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let fence = String(repeating: "`", count: Converter.longestBacktickRun(in: content) + 1)
            let padded = content.hasPrefix("`") || content.hasSuffix("`") ? " \(content) " : content
            return fence + padded + fence
        }
    }

    // MARK: Text

    /// A run's text as markdown sees it: line separators as newlines, attachment characters gone.
    private static func clean(_ text: String) -> String {
        text.replacing("\u{2028}", with: "\n").replacing("\u{FFFC}", with: "")
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        line.replacing(/\s+$/, with: "")
    }

    fileprivate static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }
}
