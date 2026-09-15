import Foundation

/// Markdown from the HTML a pasteboard carries (ED-13, ADR-0019).
///
/// The HTML is tidied and parsed by Foundation's `XMLDocument` (`.documentTidyHTML`, libtidy
/// underneath), so unclosed tags, misnested lists and fragments without `<html>` all become a
/// tree, and the tree is walked once. What the walk emits, in the forms `MarkdownScanner`
/// recognises (ED-1):
/// - `<h1>` to `<h6>` as ATX headings on one line;
/// - `<b>`/`<strong>` as `**x**`, `<i>`/`<em>` as `*x*`, `<s>`/`<strike>`/`<del>` as `~~x~~`;
///   an inline `style` carrying `font-weight`, `font-style` or `text-decoration` counts the
///   same way (Google Docs writes bold as `<span style="font-weight:700">` and wraps whole
///   documents in `<b style="font-weight:normal">`), so a span contributes emphasis it is
///   styled with and nothing else; whitespace at the edges of emphasis is moved outside the
///   markers and empty emphasis emits none;
/// - `<a href>` as `[text](href)`, or `<href>` when the text is the URL or empty; fragment-only
///   and `javascript:` links contribute their text;
/// - `<ul>`/`<ol>` as `- ` and `<n>. ` items, nested by two spaces per level, an `<ol start>`
///   honoured; an item beginning with `<input type="checkbox">` is a task item `- [ ]`/`- [x]`;
///   lists are tight, a second paragraph in an item continuing under the item text;
/// - `<code>`, `<kbd>`, `<samp>` and `<tt>` as code spans fenced longer than any backtick run
///   inside; `<pre>` as a fenced block kept verbatim, the info string from a `language-` or
///   `lang-` class on the `<code>` inside;
/// - `<blockquote>` as `> ` on every line, nested by repetition;
/// - `<table>` as a pipe table whose header is the first row, cells on one line with `|`
///   escaped and columns padded to equal widths;
/// - `<img>` with an `http(s)` source as `![alt](src)`; data and file images contribute nothing
///   (ED-15 rules out fetching or storing them);
/// - `<hr>` as `---` after a blank line (ED-8);
/// - `<p>` and the other block containers as paragraphs separated by one blank line; `<div>`
///   as a line (Mail and Notes write one per line, a blank line as `<div><br></div>`); `<br>`
///   as a line break, two in a row as a blank line.
/// Everything else (`<span>`, `<font>`, `<u>`, unknown tags) contributes only its text, and
/// `<script>`, `<style>`, `<head>` and their kind nothing. Runs of whitespace, no-break spaces
/// included, collapse to one space outside `<pre>`. Nothing in the text is escaped: a literal
/// `*` pasted from a page stays a `*` (ED-15 leaves CommonMark edge cases out).
public enum HTMLToMarkdown {
    /// The markdown for `html`, or nil when it cannot be parsed even after tidying (the caller
    /// then falls back to the pasteboard's other types). Empty for HTML holding no text.
    public static func markdown(fromHTML html: String) -> String? {
        // Tidy reads the input as Latin-1 unless a byte-order mark says otherwise; with one it
        // takes UTF-8 and a `<meta charset>` in the fragment no longer garbles the text.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: html.hasPrefix("\u{FEFF}") ? html.dropFirst().utf8 : html[...].utf8)
        guard let document = try? XMLDocument(data: data, options: [.documentTidyHTML]),
            let root = document.rootElement()
        else { return nil }
        var converter = Converter()
        converter.render(root)
        return converter.finish()
    }
}

// MARK: - Converter

/// One walk of the tree into one markdown string. Output is lazy: block boundaries, line breaks,
/// inter-word spaces and opening emphasis markers are pending until content arrives, so an empty
/// element emits nothing and no marker is ever left dangling at a line end. Blockquote and list
/// continuation prefixes are a stack applied to every line started while they are pushed.
private struct Converter {
    private var out = ""
    private var prefixes: [String] = []
    private var atLineStart = true
    private var pendingNewlines = 0
    private var pendingSpace = false
    private var pendingOpeners: [String] = []
    private var activeMarkers: [String] = []
    private var listDepth = 0
    /// Above zero inside a list item: block boundaries are single line breaks (tight lists).
    private var tightDepth = 0
    /// Above zero inside a heading or table cell: line breaks and block boundaries are spaces.
    private var inlineDepth = 0
    /// The one node the walk steps over: an item's checkbox, already spelt as its task box.
    private var skippedNode: XMLNode?
    /// Set right after a list marker: the item's first block must start on the marker's line.
    private var holdsLine = false
    /// The shortest prefix in force while the pending line breaks were requested: the blank line
    /// between two blocks belongs to the context both share (leaving a quote, no `>`).
    private var blankPrefix: String?

    init(inlineOnly: Bool = false) {
        inlineDepth = inlineOnly ? 1 : 0
    }

    mutating func finish() -> String {
        while let last = out.last, last == " " || last == "\n" { out.removeLast() }
        return out
    }

    // MARK: Walking

    mutating func render(_ node: XMLNode) {
        if let skippedNode, node === skippedNode { return }
        switch node.kind {
        case .text:
            text(node.stringValue ?? "")
        case .element:
            guard let element = node as? XMLElement else { return }
            renderElement(element)
        default:
            break
        }
    }

    mutating func renderChildren(of node: XMLNode) {
        for child in node.children ?? [] { render(child) }
    }

    private mutating func renderElement(_ element: XMLElement) {
        let name = Self.name(of: element)
        switch name {
        case "head", "script", "style", "template", "noscript", "title", "meta", "link", "iframe", "svg", "canvas",
            "select", "datalist", "object", "embed", "video", "audio", "map", "area", "base", "param", "source",
            "track":
            return
        case "br":
            lineBreak()
        case "hr":
            blockBoundary()
            write("---")
            blockBoundary()
        case "h1", "h2", "h3", "h4", "h5", "h6":
            heading(element, level: Int(name.dropFirst()) ?? 1)
        case "ul", "ol", "menu":
            list(element, ordered: name == "ol")
        case "blockquote":
            blockBoundary()
            prefixes.append("> ")
            renderChildren(of: element)
            prefixes.removeLast()
            blockBoundary()
        case "pre":
            codeBlock(element)
        case "table":
            table(element)
        case "a":
            link(element)
        case "img":
            image(element)
        case "code", "kbd", "samp", "tt":
            codeSpan(element)
        case "input", "wbr":
            return
        case "div":
            lineBoundary()
            renderChildren(of: element)
            lineBoundary()
        case _ where Self.blockNames.contains(name):
            blockBoundary()
            renderChildren(of: element)
            blockBoundary()
        default:
            inline(element, name: name)
        }
    }

    /// Block-level elements: a boundary before and after, and the reason an emphasis or link
    /// wrapping one is rendered without its markers.
    private static let blockNames: Set<String> = [
        "html", "body", "p", "div", "section", "article", "header", "footer", "main", "nav", "aside", "address",
        "figure", "figcaption", "form", "fieldset", "legend", "center", "details", "summary", "dl", "dt", "dd",
        "li", "ul", "ol", "menu", "blockquote", "pre", "table", "thead", "tbody", "tfoot", "tr", "td", "th",
        "caption", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    private static func name(of element: XMLElement) -> String {
        (element.localName ?? element.name ?? "").lowercased()
    }

    private static func containsBlock(_ node: XMLNode) -> Bool {
        for child in node.children ?? [] {
            guard let element = child as? XMLElement else { continue }
            if blockNames.contains(name(of: element)) || containsBlock(element) { return true }
        }
        return false
    }

    // MARK: Text

    /// Text outside `<pre>`: whitespace runs, no-break spaces included, become one pending
    /// space, dropped at a line start.
    private mutating func text(_ text: String) {
        let scalars = text.unicodeScalars
        guard let last = scalars.last else { return }
        if let first = scalars.first, first.properties.isWhitespace { pendingSpace = true }
        let words = scalars.split(whereSeparator: { $0.properties.isWhitespace })
        for (index, word) in words.enumerated() {
            write(String(word))
            if index < words.count - 1 { pendingSpace = true }
        }
        if last.properties.isWhitespace { pendingSpace = true }
    }

    private mutating func lineBreak() {
        if inlineDepth > 0 {
            pendingSpace = true
        } else if !out.isEmpty, !holdsLine {
            pendingNewlines = min(pendingNewlines + 1, 2)
            noteBlankPrefix()
        }
    }

    private mutating func blockBoundary() {
        if inlineDepth > 0 {
            pendingSpace = true
        } else if !out.isEmpty, !holdsLine {
            pendingNewlines = max(pendingNewlines, tightDepth > 0 ? 1 : 2)
            noteBlankPrefix()
        }
    }

    /// A `<div>` starts and ends a line, not a paragraph: Mail and Notes write one per line and
    /// spell a blank line as `<div><br></div>`, which this keeps apart from a line break.
    private mutating func lineBoundary() {
        if inlineDepth > 0 {
            pendingSpace = true
        } else if !out.isEmpty, !holdsLine {
            pendingNewlines = max(pendingNewlines, 1)
            noteBlankPrefix()
        }
    }

    private mutating func noteBlankPrefix() {
        let current = prefixes.joined()
        if let blankPrefix, blankPrefix.count <= current.count { return }
        blankPrefix = current
    }

    /// Content on the current line: whatever is pending (line breaks, the line's prefix, a
    /// space, opening markers) lands first.
    private mutating func write(_ content: String) {
        holdsLine = false
        flushNewlines()
        if atLineStart {
            out += prefixes.joined()
            atLineStart = false
        } else if pendingSpace {
            out += " "
        }
        pendingSpace = false
        if !pendingOpeners.isEmpty {
            out += pendingOpeners.joined()
            pendingOpeners.removeAll()
        }
        out += content
    }

    /// One whole line, verbatim (code block lines and table rows), empty ones included.
    private mutating func writeLine(_ line: String) {
        lineBoundary()
        holdsLine = false
        flushNewlines()
        if atLineStart {
            out += prefixes.joined()
            atLineStart = false
        }
        pendingSpace = false
        out += line
    }

    private mutating func flushNewlines() {
        guard pendingNewlines > 0 else { return }
        while out.last == " " { out.removeLast() }
        let blankLine = (blankPrefix ?? prefixes.joined()).replacing(/\s+$/, with: "")
        for index in 0..<pendingNewlines {
            out += "\n"
            if index < pendingNewlines - 1 { out += blankLine }
        }
        blankPrefix = nil
        pendingNewlines = 0
        atLineStart = true
        pendingSpace = false
    }

    // MARK: Inline

    private struct Emphasis {
        var bold = false
        var italic = false
        var strike = false

        var markers: [String] {
            (bold ? ["**"] : []) + (italic ? ["*"] : []) + (strike ? ["~~"] : [])
        }
    }

    /// The emphasis an inline element carries: its tag, overridden by its inline style.
    private static func emphasis(of element: XMLElement, name: String) -> Emphasis {
        var emphasis = Emphasis()
        switch name {
        case "b", "strong": emphasis.bold = true
        case "i", "em": emphasis.italic = true
        case "s", "strike", "del": emphasis.strike = true
        default: break
        }
        guard let style = element.attribute(forName: "style")?.stringValue?.lowercased() else { return emphasis }
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch property {
            case "font-weight":
                if let weight = Int(value) {
                    emphasis.bold = weight >= 600
                } else if value == "bold" || value == "bolder" {
                    emphasis.bold = true
                } else if value == "normal" || value == "lighter" {
                    emphasis.bold = false
                }
            case "font-style":
                emphasis.italic = value == "italic" || value == "oblique"
            case "text-decoration", "text-decoration-line":
                if value.contains("line-through") {
                    emphasis.strike = true
                } else if value == "none" {
                    emphasis.strike = false
                }
            default:
                break
            }
        }
        return emphasis
    }

    private mutating func inline(_ element: XMLElement, name: String) {
        let markers = Self.emphasis(of: element, name: name).markers.filter { !activeMarkers.contains($0) }
        guard !markers.isEmpty, !Self.containsBlock(element) else {
            renderChildren(of: element)
            return
        }
        pendingOpeners += markers
        activeMarkers += markers
        renderChildren(of: element)
        activeMarkers.removeLast(markers.count)
        for marker in markers.reversed() {
            if let pending = pendingOpeners.lastIndex(of: marker) {
                pendingOpeners.remove(at: pending)
            } else {
                out += marker
            }
        }
    }

    private mutating func link(_ element: XMLElement) {
        let href = (element.attribute(forName: "href")?.stringValue ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard Self.isLinkable(href), !Self.containsBlock(element) else {
            renderChildren(of: element)
            return
        }
        write("[")
        let start = out.utf8.count
        renderChildren(of: element)
        let textLength = out.utf8.count - start
        if textLength == 0 {
            out.removeLast()
            pendingSpace = false
            write("<\(href)>")
        } else if out.utf8.suffix(textLength).elementsEqual(href.utf8) {
            out.removeSubrange(out.utf8.index(out.utf8.endIndex, offsetBy: -(textLength + 1))...)
            out += "<\(href)>"
        } else {
            out += "](\(Self.destination(href)))"
        }
    }

    private static func isLinkable(_ href: String) -> Bool {
        !href.isEmpty && !href.hasPrefix("#") && !href.lowercased().hasPrefix("javascript:")
    }

    /// A destination inside `(...)`: spaces and parentheses percent-encoded so the link ends
    /// where it should.
    private static func destination(_ href: String) -> String {
        href.replacing(" ", with: "%20").replacing("(", with: "%28").replacing(")", with: "%29")
    }

    private mutating func image(_ element: XMLElement) {
        let source = (element.attribute(forName: "src")?.stringValue ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let scheme = source.lowercased()
        guard scheme.hasPrefix("http://") || scheme.hasPrefix("https://") else { return }
        let alt = (element.attribute(forName: "alt")?.stringValue ?? "")
            .replacing(/[\[\]]/, with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        write("![\(alt)](\(Self.destination(source)))")
    }

    private mutating func codeSpan(_ element: XMLElement) {
        var raw = ""
        Self.collectText(of: element, into: &raw)
        let content = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !content.isEmpty else { return }
        let fence = String(repeating: "`", count: Self.longestBacktickRun(in: content) + 1)
        let padded = content.hasPrefix("`") || content.hasSuffix("`") ? " \(content) " : content
        write(fence + padded + fence)
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    /// Every text node under `node` as written, a `<br>` as a newline; scripts and styles left out.
    private static func collectText(of node: XMLNode, into text: inout String) {
        for child in node.children ?? [] {
            switch child.kind {
            case .text:
                text += child.stringValue ?? ""
            case .element:
                guard let element = child as? XMLElement else { continue }
                switch name(of: element) {
                case "br": text += "\n"
                case "script", "style": continue
                default: collectText(of: element, into: &text)
                }
            default:
                continue
            }
        }
    }

    // MARK: Blocks

    private mutating func heading(_ element: XMLElement, level: Int) {
        blockBoundary()
        write(String(repeating: "#", count: level))
        pendingSpace = true
        inlineDepth += 1
        renderChildren(of: element)
        inlineDepth -= 1
        blockBoundary()
    }

    private mutating func codeBlock(_ element: XMLElement) {
        var text = ""
        Self.collectText(of: element, into: &text)
        if text.hasPrefix("\n") { text.removeFirst() }
        while let last = text.last, last == "\n" || last == " " { text.removeLast() }
        let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(in: text) + 1))
        blockBoundary()
        writeLine(fence + Self.infoString(of: element))
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            writeLine(String(line))
        }
        writeLine(fence)
        blockBoundary()
    }

    /// The language named by a `language-x` or `lang-x` class on the `<pre>` or its `<code>`.
    private static func infoString(of pre: XMLElement) -> String {
        var candidates = [pre]
        candidates += (pre.children ?? []).compactMap { $0 as? XMLElement }.filter { name(of: $0) == "code" }
        for element in candidates {
            guard let classes = element.attribute(forName: "class")?.stringValue else { continue }
            for token in classes.split(whereSeparator: { $0.isWhitespace }) {
                for prefix in ["language-", "lang-"] where token.hasPrefix(prefix) {
                    return String(token.dropFirst(prefix.count))
                }
            }
        }
        return ""
    }

    private mutating func list(_ element: XMLElement, ordered: Bool) {
        let nested = listDepth > 0
        if nested { lineBoundary() } else { blockBoundary() }
        listDepth += 1
        var number = Int(element.attribute(forName: "start")?.stringValue ?? "") ?? 1
        for child in element.children ?? [] {
            guard let item = child as? XMLElement else { continue }
            switch Self.name(of: item) {
            case "li":
                lineBoundary()
                if Self.holdsOnlyLists(item) {
                    // Tidy's wrapper for a list nested directly in a list: no item of its own.
                    prefixes.append("  ")
                    renderChildren(of: item)
                    prefixes.removeLast()
                } else {
                    listItem(item, marker: ordered ? "\(number)." : "-")
                    if ordered { number += 1 }
                }
            case "ul", "ol", "menu":
                prefixes.append("  ")
                render(item)
                prefixes.removeLast()
            default:
                render(item)
            }
        }
        listDepth -= 1
        if nested { lineBoundary() } else { blockBoundary() }
    }

    private mutating func listItem(_ item: XMLElement, marker: String) {
        let checkbox = Self.checkbox(in: item)
        var marker = marker
        if let checkbox { marker += checkbox.checked ? " [x]" : " [ ]" }
        write(marker)
        pendingSpace = true
        holdsLine = true
        prefixes.append("  ")
        tightDepth += 1
        let outerSkip = skippedNode
        skippedNode = checkbox?.node
        renderChildren(of: item)
        skippedNode = outerSkip
        tightDepth -= 1
        prefixes.removeLast()
    }

    private static func holdsOnlyLists(_ item: XMLElement) -> Bool {
        var sawList = false
        for child in item.children ?? [] {
            if let element = child as? XMLElement {
                guard ["ul", "ol", "menu"].contains(name(of: element)) else { return false }
                sawList = true
            } else if child.kind == .text {
                guard (child.stringValue ?? "").allSatisfy({ $0.isWhitespace }) else { return false }
            }
        }
        return sawList
    }

    /// The checkbox an item starts with, before any text and outside any nested list.
    private static func checkbox(in item: XMLNode) -> (node: XMLNode, checked: Bool)? {
        for child in item.children ?? [] {
            switch child.kind {
            case .text:
                if !(child.stringValue ?? "").allSatisfy({ $0.isWhitespace }) { return nil }
            case .element:
                guard let element = child as? XMLElement else { continue }
                let name = name(of: element)
                if name == "input" {
                    guard element.attribute(forName: "type")?.stringValue?.lowercased() == "checkbox" else {
                        return nil
                    }
                    return (element, element.attribute(forName: "checked") != nil)
                }
                if ["ul", "ol", "menu", "br", "img"].contains(name) { return nil }
                if let found = checkbox(in: element) { return found }
                if !plainText(of: element).allSatisfy({ $0.isWhitespace }) { return nil }
            default:
                continue
            }
        }
        return nil
    }

    private static func plainText(of node: XMLNode) -> String {
        var text = ""
        collectText(of: node, into: &text)
        return text
    }

    private mutating func table(_ element: XMLElement) {
        var rows: [[String]] = []
        var caption: XMLElement?
        for child in element.children ?? [] {
            guard let section = child as? XMLElement else { continue }
            switch Self.name(of: section) {
            case "tr":
                rows.append(Self.cells(of: section))
            case "thead", "tbody", "tfoot":
                for row in (section.children ?? []).compactMap({ $0 as? XMLElement }) where Self.name(of: row) == "tr" {
                    rows.append(Self.cells(of: row))
                }
            case "caption":
                caption = section
            default:
                continue
            }
        }
        if let caption {
            blockBoundary()
            renderChildren(of: caption)
            blockBoundary()
        }
        guard let columns = rows.map(\.count).max(), columns > 0 else { return }
        var widths = [Int](repeating: 3, count: columns)
        for row in rows {
            for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) }
        }
        func line(_ cells: [String]) -> String {
            let padded = (0..<columns).map { index -> String in
                let cell = index < cells.count ? cells[index] : ""
                return cell + String(repeating: " ", count: widths[index] - cell.count)
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        blockBoundary()
        writeLine(line(rows[0]))
        writeLine(line(widths.map { String(repeating: "-", count: $0) }))
        for row in rows.dropFirst() { writeLine(line(row)) }
        blockBoundary()
    }

    /// A row's cells, each rendered on one line with its pipes escaped.
    private static func cells(of row: XMLElement) -> [String] {
        (row.children ?? []).compactMap { $0 as? XMLElement }
            .filter { ["td", "th"].contains(name(of: $0)) }
            .map { cell in
                var converter = Converter(inlineOnly: true)
                converter.renderChildren(of: cell)
                return converter.finish().replacing("|", with: "\\|")
            }
    }
}
