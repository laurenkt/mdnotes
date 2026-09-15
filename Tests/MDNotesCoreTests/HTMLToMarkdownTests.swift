import Foundation
import MDNotesCore
import XCTest

/// `HTMLToMarkdown` (ED-13): one byte-exact fixture per pasteboard source (Mail, Safari, Notes,
/// Google Docs) under `Fixtures/`, plus one test per construct the walk emits.
final class HTMLToMarkdownTests: XCTestCase {
    // MARK: ED-13 fixtures: what each source puts on the pasteboard, byte-exact

    func testED13_mailFixture() throws {
        try assertFixture("mail")
    }

    func testED13_safariFixture() throws {
        try assertFixture("safari")
    }

    func testED13_notesFixture() throws {
        try assertFixture("notes")
    }

    func testED13_googleDocsFixture() throws {
        try assertFixture("google-docs")
    }

    private func assertFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let html = try fixture(name, extension: "html")
        let expected = try fixture(name, extension: "md")
        let markdown = try XCTUnwrap(HTMLToMarkdown.markdown(fromHTML: html), "\(name).html did not parse")
        XCTAssertEqual(markdown, expected, "\(name).html", file: file, line: line)
    }

    private func fixture(_ name: String, extension ext: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "missing fixture \(name).\(ext)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: ED-13 headings, paragraphs and line breaks

    func testED13_headingsAreATXOnOneLine() {
        XCTAssertEqual(
            convert("<h1>Title</h1><h3>Sub <br> head</h3><h6>Deep</h6>"), "# Title\n\n### Sub head\n\n###### Deep")
    }

    func testED13_paragraphsAreSeparatedByOneBlankLineAndWhitespaceCollapses() {
        XCTAssertEqual(convert("<p>  one\n   two </p>\n\n<p>three&nbsp;&nbsp;four</p>"), "one two\n\nthree four")
    }

    func testED13_lineBreaksAndDivLines() {
        XCTAssertEqual(convert("<p>a<br>b</p>"), "a\nb")
        XCTAssertEqual(convert("<p>a<br><br>b</p>"), "a\n\nb", "two breaks are a blank line")
        XCTAssertEqual(convert("<div>a</div><div>b</div>"), "a\nb", "a div is a line")
        XCTAssertEqual(convert("<div>a</div><div><br></div><div>b</div>"), "a\n\nb", "Notes' blank line")
    }

    // MARK: ED-13 emphasis by tag and by inline style

    func testED13_emphasisTags() {
        XCTAssertEqual(
            convert("<p><b>bold</b> <strong>strong</strong> <i>it</i> <em>em</em> <s>s</s> <del>del</del></p>"),
            "**bold** **strong** *it* *em* ~~s~~ ~~del~~")
        XCTAssertEqual(convert("<p><i><b>both</b></i></p>"), "***both***")
    }

    func testED13_emphasisFromInlineStyle() {
        XCTAssertEqual(
            convert(
                "<p><span style=\"font-weight:700\">bold</span> <span style=\"font-style: italic;\">it</span> "
                    + "<span style=\"text-decoration:line-through\">gone</span> <span style=\"color:red\">plain</span></p>"
            ),
            "**bold** *it* ~~gone~~ plain")
        XCTAssertEqual(convert("<b style=\"font-weight:normal\">not bold</b>"), "not bold", "Google Docs' wrapper")
    }

    func testED13_emphasisKeepsEdgeWhitespaceOutsideAndEmitsNothingWhenEmpty() {
        XCTAssertEqual(convert("<p>a<b> bold </b>c</p>"), "a **bold** c")
        XCTAssertEqual(convert("<p>a <b></b> b <i> </i> c</p>"), "a b c")
    }

    // MARK: ED-13 links and images

    func testED13_links() {
        XCTAssertEqual(convert("<a href=\"https://x.y/z\">text</a>"), "[text](https://x.y/z)")
        XCTAssertEqual(convert("<a href=\"https://x.y/z\">https://x.y/z</a>"), "<https://x.y/z>", "URL as text")
        XCTAssertEqual(convert("<a href=\"https://x.y/z\"></a>"), "<https://x.y/z>", "empty text")
        XCTAssertEqual(
            convert("<a href=\"#top\">top</a> <a href=\"javascript:void(0)\">js</a> <a>none</a>"), "top js none")
        XCTAssertEqual(convert("<a href=\"https://x.y/a b(c)\">t</a>"), "[t](https://x.y/a%20b%28c%29)")
    }

    func testED13_remoteImagesOnly() {
        XCTAssertEqual(convert("<img src=\"https://x.y/i.png\" alt=\"An [image]\">"), "![An image](https://x.y/i.png)")
        XCTAssertEqual(convert("<p>a <img src=\"data:image/png;base64,AAAA\" alt=\"local\"> b</p>"), "a b")
        XCTAssertEqual(convert("<p>a <img src=\"file:///tmp/x.png\"> b</p>"), "a b")
    }

    // MARK: ED-13 lists, nesting, task items

    func testED13_listsNestByTwoSpaces() {
        XCTAssertEqual(
            convert("<ul><li>a<ul><li>b<ul><li>c</li></ul></li></ul></li><li>d</li></ul>"),
            "- a\n  - b\n    - c\n- d")
        XCTAssertEqual(convert("<ol start=\"3\"><li>x</li><li>y<ol><li>z</li></ol></li></ol>"), "3. x\n4. y\n  1. z")
        XCTAssertEqual(convert("<p>before</p><ul><li>a</li></ul><p>after</p>"), "before\n\n- a\n\nafter")
    }

    func testED13_listNestedDirectlyInAListIsNestedUnderThePreviousItem() {
        XCTAssertEqual(
            convert("<ul><li><p>a</p></li><ul><li><p>b</p></li></ul><li><p>c</p></li></ul>"),
            "- a\n  - b\n- c", "Google Docs' shape, tidied")
    }

    func testED13_taskItems() {
        XCTAssertEqual(
            convert(
                "<ul><li><input type=\"checkbox\" checked> done</li><li><input type=\"checkbox\"> open</li>"
                    + "<li>plain</li></ul>"),
            "- [x] done\n- [ ] open\n- plain")
        XCTAssertEqual(
            convert("<ol><li><p><input type=\"checkbox\"> in a paragraph</p></li></ol>"), "1. [ ] in a paragraph")
    }

    func testED13_blocksInsideAnItemContinueUnderItsText() {
        XCTAssertEqual(convert("<ul><li><p>one</p><p>two</p></li><li>x</li></ul>"), "- one\n  two\n- x")
        XCTAssertEqual(convert("<ul><li>q<blockquote>quoted</blockquote></li></ul>"), "- q\n  > quoted")
    }

    // MARK: ED-13 code

    func testED13_codeSpans() {
        XCTAssertEqual(convert("<p>run <code>ls -la</code> or <kbd>Cmd</kbd></p>"), "run `ls -la` or `Cmd`")
        XCTAssertEqual(convert("<code>a `b` c</code>"), "``a `b` c``")
        XCTAssertEqual(convert("<code>`tick</code>"), "`` `tick ``")
        XCTAssertEqual(convert("<p>a <code></code> b</p>"), "a b")
    }

    func testED13_codeBlocksAreFencedVerbatimWithTheLanguage() {
        XCTAssertEqual(
            convert("<pre><code class=\"language-swift\">let x = 1\n\n  let y = 2\n</code></pre>"),
            "```swift\nlet x = 1\n\n  let y = 2\n```")
        XCTAssertEqual(convert("<p>a</p><pre>x<br>y</pre><p>b</p>"), "a\n\n```\nx\ny\n```\n\nb")
        XCTAssertEqual(convert("<pre>```\n</pre>"), "````\n```\n````", "fenced longer than the run inside")
    }

    // MARK: ED-13 blockquotes, tables, rules

    func testED13_blockquotesPrefixEveryLineAndNest() {
        XCTAssertEqual(
            convert("<blockquote><p>a</p><p>b</p><blockquote>c</blockquote></blockquote><p>d</p>"),
            "> a\n>\n> b\n>\n> > c\n\nd")
        XCTAssertEqual(convert("<blockquote><ul><li>x</li><li>y</li></ul></blockquote>"), "> - x\n> - y")
    }

    func testED13_tablesArePipeTablesWithTheFirstRowAsHeader() {
        XCTAssertEqual(
            convert(
                "<table><thead><tr><th>A</th><th>Bee</th></tr></thead>"
                    + "<tbody><tr><td>1 | x</td><td>two<br>lines</td></tr><tr><td><b>3</b></td></tr></tbody></table>"),
            "| A      | Bee       |\n| ------ | --------- |\n| 1 \\| x | two lines |\n| **3**  |           |")
        XCTAssertEqual(convert("<table><tr><td>only</td></tr></table>"), "| only |\n| ---- |")
        XCTAssertEqual(convert("<table></table><p>x</p>"), "x")
    }

    func testED13_rulesFollowABlankLine() {
        XCTAssertEqual(convert("<p>a</p><hr><p>b</p>"), "a\n\n---\n\nb")
    }

    // MARK: ED-13 everything else is text only

    func testED13_otherElementsContributeOnlyTheirText() {
        XCTAssertEqual(
            convert(
                "<p><span style=\"color:red;font-size:30px\">span</span> <font face=\"Menlo\">font</font> <u>u</u> "
                    + "<sup>sup</sup> <mark>mark</mark></p>"),
            "span font u sup mark")
    }

    func testED13_scriptsStylesAndHeadContributeNothing() {
        XCTAssertEqual(
            convert(
                "<html><head><title>T</title><style>p{}</style></head>"
                    + "<body><p>x</p><script>var y;</script><!-- c --></body></html>"),
            "x")
    }

    func testED13_fragmentsAndUnclosedTagsAreTidied() {
        XCTAssertEqual(
            convert("<meta charset='utf-8'>plain <b>bold <i>both"), convert("<p>plain <b>bold <i>both</i></b></p>"))
        XCTAssertEqual(convert("\u{FEFF}<p>x</p>"), "x", "a byte-order mark of its own")
        XCTAssertEqual(convert("just text"), "just text")
        XCTAssertEqual(convert("<p>caf\u{E9} \u{2603} &rsquo; &#8217;</p>"), "caf\u{E9} \u{2603} \u{2019} \u{2019}")
    }

    func testED13_unparsableHTMLIsNil() {
        XCTAssertNil(HTMLToMarkdown.markdown(fromHTML: ""))
    }

    private func convert(_ html: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let markdown = HTMLToMarkdown.markdown(fromHTML: html) else {
            XCTFail("did not parse: \(html)", file: file, line: line)
            return ""
        }
        return markdown
    }
}
