import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import MDNotesTestSupport
import XCTest

/// PF-9: converting 200 KB of pasted HTML to markdown (ED-13) on the main thread, which is
/// where `EditorTextView.paste(_:)` runs it (ED-14). The HTML is generated here from the
/// constructs ED-13 names, in the shape a browser's pasteboard HTML takes: a `<meta charset>`
/// head, block-level paragraphs, headings, nested lists with task items, links, emphasis by
/// tag and by inline style, code spans, fenced blocks, blockquotes and tables, with the
/// spans, fonts and colours a page carries that contribute only their text. Runs only in
/// `scripts/check.sh full` (release); `MDNOTES_SKIP_PERF=1` skips it (ADR-0007).
@MainActor
final class PastePerfTests: XCTestCase {
    /// PF-9's input size in bytes of UTF-8.
    nonisolated private static let htmlByteCount = 200 * 1024
    private static let warmUp = 3
    private static let iterations = 15

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipIf(PerfGate.isSkipped, "MDNOTES_SKIP_PERF=1")
    }

    // MARK: - Fixture

    /// One section of the generated page: every construct once, with `n` in its text so no
    /// two sections are equal.
    nonisolated private static func section(_ n: Int) -> String {
        """
        <h2>Section \(n): <span style="font-weight:700">planning</span> notes</h2>
        <p>Paragraph \(n) with <b>bold</b>, <i>italic</i>, <s>struck</s> and a
        <a href="https://example.com/page/\(n)">link to page \(n)</a>, plus <code>code_\(n)</code>
        and a <span style="color:#333;font-family:Helvetica">styled span</span> that is text only.</p>
        <ul>
          <li>First item \(n) with <strong>strong</strong> text</li>
          <li>Second item
            <ul>
              <li>Nested item <em>\(n)</em></li>
              <li><input type="checkbox" checked> Done task \(n)</li>
              <li><input type="checkbox"> Open task \(n)</li>
            </ul>
          </li>
          <li>Third item with a <a href="https://example.com/\(n)">https://example.com/\(n)</a></li>
        </ul>
        <ol start="\(n % 7 + 1)">
          <li>Step one of \(n)</li>
          <li>Step two of \(n)</li>
        </ol>
        <blockquote><p>Quoted paragraph \(n) that runs on for a while so the quote has a
        second line when it wraps in the source.</p></blockquote>
        <pre><code class="language-swift">let value\(n) = compute(\(n))
        print(value\(n))</code></pre>
        <table>
          <tr><th>Name</th><th>Count</th><th>Note</th></tr>
          <tr><td>alpha \(n)</td><td>\(n * 3)</td><td>first row</td></tr>
          <tr><td>beta \(n)</td><td>\(n * 5)</td><td>second | row</td></tr>
        </table>
        <div>A line in a div \(n)</div>
        <div><br></div>
        <div>Another line after a blank one, with <font color="#ff0000">a font tag</font>.</div>
        <hr>

        """
    }

    /// At least `htmlByteCount` bytes of page HTML: sections appended until the size is met,
    /// inside the head and body a browser writes.
    nonisolated private static let html: String = {
        var body = ""
        var n = 0
        while body.utf8.count < htmlByteCount {
            body += section(n)
            n += 1
        }
        return """
            <html><head><meta charset="utf-8"><title>Pasted page</title>
            <style>p { margin: 0 } .x { color: red }</style></head>
            <body>
            \(body)</body></html>
            """
    }()

    // MARK: PF-9

    func testPF9_converting200KBOfHTMLToMarkdownUnderBudget() throws {
        let html = Self.html
        XCTAssertGreaterThanOrEqual(html.utf8.count, Self.htmlByteCount, "at least 200 KB of HTML")
        XCTAssertLessThan(html.utf8.count, Self.htmlByteCount + 4096, "and not much more")

        var lastMarkdown: String?
        let samples = PerfGate.measure(warmUp: Self.warmUp, iterations: Self.iterations) {
            lastMarkdown = HTMLToMarkdown.markdown(fromHTML: html)
        }
        let markdown = try XCTUnwrap(lastMarkdown, "the page converts")
        XCTAssertTrue(markdown.contains("## Section 0: **planning** notes"), "headings and styled emphasis")
        XCTAssertTrue(markdown.contains("- [x] Done task 0"), "task items")
        XCTAssertTrue(markdown.contains("[link to page 0](https://example.com/page/0)"), "links")
        XCTAssertTrue(markdown.contains("```swift"), "fenced code")
        XCTAssertTrue(markdown.contains("| Name"), "tables")
        XCTAssertTrue(markdown.contains("> Quoted paragraph 0"), "quotes")

        let subject = "convert \(html.utf8.count / 1024) KB of HTML to markdown"
        PerfGate.report("PF-9", subject, samples, budget: PerfGate.Budget.pasteHTMLConversion200KB)
        XCTAssertLessThan(samples.median, PerfGate.Budget.pasteHTMLConversion200KB, "PF-9: \(subject) over budget")
    }
}
