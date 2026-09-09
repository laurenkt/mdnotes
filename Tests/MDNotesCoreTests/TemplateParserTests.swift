import Foundation
import MDNotesCore
import XCTest

/// The pure half of templates: the header block and its `path` (TP-2), and token expansion
/// in paths and bodies (TP-3).
final class TemplateParserTests: XCTestCase {
    /// Wednesday 9 September 2026, 23:30:00 UTC. Pinned so the date tests are exact.
    private let instant = Date(timeIntervalSince1970: 1_788_996_600)

    private func environment(timeZone: String = "UTC", locale: String = "en_US_POSIX") throws
        -> TemplateParser.Environment
    {
        let zone = try XCTUnwrap(TimeZone(identifier: timeZone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return TemplateParser.Environment(
            date: instant, timeZone: zone, calendar: calendar, locale: Locale(identifier: locale))
    }

    private func rejection(of text: String) -> TemplateParser.Rejection? {
        do {
            _ = try TemplateParser.parse(text)
            return nil
        } catch {
            return error
        }
    }

    // MARK: TP-2 header block

    func testTP2_headerWithPathParsesIntoPathAndBody() throws {
        let template = try TemplateParser.parse("---\npath: daily/{{date:yyyy}}\n---\n# Today\n\n{{cursor}}\n")
        XCTAssertEqual(template.path, "daily/{{date:yyyy}}")
        XCTAssertEqual(template.body, "# Today\n\n{{cursor}}\n")
    }

    func testTP2_bodyIsEverythingAfterTheClosingFence() throws {
        // Nothing after the fence: an empty body.
        XCTAssertEqual(try TemplateParser.parse("---\npath: x\n---").body, "")
        XCTAssertEqual(try TemplateParser.parse("---\npath: x\n---\n").body, "")
        // Blank lines, later `---` rules and header-looking lines in the body are body.
        let body = "\n\nkey: value\n---\n\ntext"
        XCTAssertEqual(try TemplateParser.parse("---\npath: x\n---\n" + body).body, body)
    }

    func testTP2_pathValueIsTrimmedAndSplitAtTheFirstColon() throws {
        XCTAssertEqual(try TemplateParser.parse("---\n  path :   notes/{{title}}  \n---\n").path, "notes/{{title}}")
        XCTAssertEqual(try TemplateParser.parse("---\npath:a\n---\n").path, "a")
        // The value keeps any later colon; C-3 judges it at instantiation (TP-4).
        XCTAssertEqual(try TemplateParser.parse("---\npath: a:b\n---\n").path, "a:b")
        // The first `path` wins over a repeat.
        XCTAssertEqual(try TemplateParser.parse("---\npath: first\npath: second\n---\n").path, "first")
    }

    func testTP2_unknownKeysAndOtherHeaderLinesAreIgnored() throws {
        let template = try TemplateParser.parse(
            "---\ntitle: Daily\n\nno colon here\npath: daily\ncolour: red\n---\nbody")
        XCTAssertEqual(template.path, "daily")
        XCTAssertEqual(template.body, "body")
    }

    func testTP2_crlfLineEndingsAndTrailingSpacesOnFencesParse() throws {
        let template = try TemplateParser.parse("--- \r\npath: daily\r\n---\t\r\nline one\r\nline two")
        XCTAssertEqual(template.path, "daily")
        XCTAssertEqual(template.body, "line one\r\nline two")
    }

    func testTP2_missingHeaderIsRefusedWithAMessage() {
        XCTAssertEqual(rejection(of: ""), .missingHeader)
        XCTAssertEqual(rejection(of: "# Just a note\npath: daily\n"), .missingHeader)
        // The fence must be the first line.
        XCTAssertEqual(rejection(of: "\n---\npath: daily\n---\n"), .missingHeader)
        // A longer rule is not the fence.
        XCTAssertEqual(rejection(of: "----\npath: daily\n---\n"), .missingHeader)
        XCTAssertEqual(rejection(of: "--- path: daily ---\n"), .missingHeader)
        XCTAssertEqual(
            TemplateParser.Rejection.missingHeader.message,
            "This template has no header: it must start with a \u{201C}---\u{201D} line.")
    }

    func testTP2_unclosedHeaderIsRefusedWithAMessage() {
        XCTAssertEqual(rejection(of: "---\npath: daily\n"), .unterminatedHeader)
        XCTAssertEqual(rejection(of: "---"), .unterminatedHeader)
        XCTAssertEqual(rejection(of: "---\npath: daily\n----\nbody"), .unterminatedHeader)
        XCTAssertEqual(
            TemplateParser.Rejection.unterminatedHeader.message,
            "This template's header is not closed with a \u{201C}---\u{201D} line.")
    }

    func testTP2_missingPathIsRefusedWithAMessage() {
        XCTAssertEqual(rejection(of: "---\n---\nbody"), .missingPath)
        XCTAssertEqual(rejection(of: "---\ntitle: Daily\n---\nbody"), .missingPath)
        // An empty value is as good as none.
        XCTAssertEqual(rejection(of: "---\npath:\n---\nbody"), .missingPath)
        XCTAssertEqual(rejection(of: "---\npath:   \n---\nbody"), .missingPath)
        // The key is case-sensitive and must be the whole key.
        XCTAssertEqual(rejection(of: "---\nPath: daily\n---\n"), .missingPath)
        XCTAssertEqual(rejection(of: "---\npathname: daily\n---\n"), .missingPath)
        // A `path` after the closing fence is body, not header.
        XCTAssertEqual(rejection(of: "---\n---\npath: daily\n"), .missingPath)
        XCTAssertEqual(
            TemplateParser.Rejection.missingPath.message, "This template's header has no \u{201C}path\u{201D}.")
    }

    // MARK: TP-3 {{date:FORMAT}}

    func testTP3_dateTokenIsAUnicodePatternHandedToDateFormatter() throws {
        let env = try environment()
        func date(_ format: String) -> String {
            TemplateParser.expandPath("{{date:\(format)}}", title: "", in: env)
        }
        XCTAssertEqual(date("yyyy"), "2026")
        XCTAssertEqual(date("MM"), "09")
        XCTAssertEqual(date("MMMM"), "September")
        XCTAssertEqual(date("dd"), "09")
        XCTAssertEqual(date("EEEE"), "Wednesday")
        XCTAssertEqual(date("HH"), "23")
        XCTAssertEqual(date("mm"), "30")
        XCTAssertEqual(date("yyyy-MM-dd HH:mm"), "2026-09-09 23:30")
        // Pattern letters mean what Unicode says they mean, no more: `D` is the day of the
        // year and quoted text is literal.
        XCTAssertEqual(date("D"), "252")
        XCTAssertEqual(date("'at' h a"), "at 11 PM")
    }

    func testTP3_dateTokenExpandsInPathsAndBodiesAlike() throws {
        let env = try environment()
        let template = try TemplateParser.parse(
            "---\npath: daily/{{date:yyyy}}/{{date:MM-MMMM}}/{{date:dd-EEEE}}\n---\n# {{date:EEEE d MMMM yyyy}}\n")
        XCTAssertEqual(template.expandedPath(title: "", in: env), "daily/2026/09-September/09-Wednesday")
        XCTAssertEqual(template.expandedBody(title: "", in: env).text, "# Wednesday 9 September 2026\n")
    }

    func testTP3_dateTokenIsEvaluatedInTheLocalTimeZone() throws {
        // The same instant is still Wednesday in London and already Thursday in Auckland.
        let london = try environment(timeZone: "Europe/London")
        let auckland = try environment(timeZone: "Pacific/Auckland")
        XCTAssertEqual(
            TemplateParser.expandPath("{{date:yyyy-MM-dd EEEE HH:mm}}", title: "", in: london),
            "2026-09-10 Thursday 00:30")
        XCTAssertEqual(
            TemplateParser.expandPath("{{date:yyyy-MM-dd EEEE HH:mm}}", title: "", in: auckland),
            "2026-09-10 Thursday 11:30")
        XCTAssertEqual(
            TemplateParser.expandPath("{{date:yyyy-MM-dd EEEE HH:mm}}", title: "", in: try environment()),
            "2026-09-09 Wednesday 23:30")
    }

    func testTP3_dateTokenNamesFollowTheLocale() throws {
        XCTAssertEqual(
            TemplateParser.expandPath("{{date:MMMM EEEE}}", title: "", in: try environment(locale: "fr_FR")),
            "septembre mercredi")
        XCTAssertEqual(
            TemplateParser.expandPath("{{date:MMMM EEEE}}", title: "", in: try environment(locale: "de_DE")),
            "September Mittwoch")
    }

    func testTP3_defaultEnvironmentIsNowInTheLocalZone() {
        // No pinned values to compare against, only the shape: four digits of a plausible year.
        let year = TemplateParser.expandPath("{{date:yyyy}}", title: "")
        XCTAssertEqual(year.count, 4)
        XCTAssertGreaterThanOrEqual(Int(year) ?? 0, 2026)
    }

    // MARK: TP-3 {{title}}

    func testTP3_titleTokenIsTheGivenTitleInPathAndBody() throws {
        let template = try TemplateParser.parse(
            "---\npath: meetings/{{title}}\n---\n# {{title}}\n\nNotes on {{title}}: {{cursor}}")
        XCTAssertEqual(template.expandedPath(title: "Weekly sync"), "meetings/Weekly sync")
        XCTAssertEqual(template.expandedBody(title: "Weekly sync").text, "# Weekly sync\n\nNotes on Weekly sync: ")
        // No title given: the token expands to nothing. TP-5 refuses before this when the path
        // needs one; a body may simply go without.
        XCTAssertEqual(template.expandedBody(title: "").text, "# \n\nNotes on : ")
    }

    func testTP3_pathNeedsTitleOnlyWhenItHasTheToken() throws {
        XCTAssertTrue(try TemplateParser.parse("---\npath: meetings/{{title}}\n---\n").pathNeedsTitle)
        XCTAssertFalse(try TemplateParser.parse("---\npath: daily/{{date:yyyy}}\n---\n# {{title}}\n").pathNeedsTitle)
        // An unknown token spelled like the title is not the title token.
        XCTAssertFalse(try TemplateParser.parse("---\npath: {{Title}} {{ title }} {{title\n---\n").pathNeedsTitle)
    }

    // MARK: TP-3 {{cursor}}

    func testTP3_cursorIsRemovedFromTheBodyAndMarksTheCaret() {
        let body = TemplateParser.expandBody("# Heading\n\n{{cursor}}\n\nMore text\n", title: "")
        XCTAssertEqual(body.text, "# Heading\n\n\n\nMore text\n")
        XCTAssertEqual(body.cursorOffset, 11)
    }

    func testTP3_cursorOffsetCountsUTF16UnitsOfTheExpandedText() throws {
        // Two non-BMP characters (two UTF-16 units each) and an expanded title before it: the
        // offset is what `NSRange` needs on the expanded text, not on the template.
        let env = try environment()
        let body = TemplateParser.expandBody("😀🎉 {{title}} {{date:yyyy}}{{cursor}}end", title: "Café", in: env)
        XCTAssertEqual(body.text, "😀🎉 Café 2026end")
        XCTAssertEqual(body.cursorOffset, "😀🎉 Café 2026".utf16.count)
        XCTAssertEqual(body.cursorOffset, 14)
    }

    func testTP3_cursorAtTheEdgesAndAbsent() {
        XCTAssertEqual(TemplateParser.expandBody("{{cursor}}text", title: ""), .init(text: "text", cursorOffset: 0))
        XCTAssertEqual(TemplateParser.expandBody("text{{cursor}}", title: ""), .init(text: "text", cursorOffset: 4))
        XCTAssertEqual(TemplateParser.expandBody("{{cursor}}", title: ""), .init(text: "", cursorOffset: 0))
        XCTAssertNil(TemplateParser.expandBody("no caret here", title: "").cursorOffset)
        XCTAssertNil(TemplateParser.expandBody("", title: "").cursorOffset)
    }

    func testTP3_everyCursorIsRemovedAndTheFirstMarksTheCaret() {
        let body = TemplateParser.expandBody("a{{cursor}}b{{cursor}}c", title: "")
        XCTAssertEqual(body.text, "abc")
        XCTAssertEqual(body.cursorOffset, 1)
    }

    func testTP3_cursorIsNotATokenInAPath() throws {
        let template = try TemplateParser.parse("---\npath: notes/{{cursor}}\n---\n")
        XCTAssertEqual(template.expandedPath(title: ""), "notes/{{cursor}}")
        XCTAssertEqual(TemplateParser.expandPath("{{cursor}}{{title}}", title: "t"), "{{cursor}}t")
    }

    // MARK: TP-3 unknown tokens

    func testTP3_unknownTokensAreLeftLiteral() throws {
        let env = try environment()
        func expand(_ text: String) -> String {
            TemplateParser.expandBody(text, title: "T", in: env).text
        }
        XCTAssertEqual(expand("{{foo}}"), "{{foo}}")
        XCTAssertEqual(expand("{{ title }}"), "{{ title }}")
        XCTAssertEqual(expand("{{Title}}"), "{{Title}}")
        XCTAssertEqual(expand("{{date}}"), "{{date}}")
        XCTAssertEqual(expand("{{date:}}"), "{{date:}}")
        XCTAssertEqual(expand("{{}}"), "{{}}")
        // Braces that never form a token.
        XCTAssertEqual(expand("{{title"), "{{title")
        XCTAssertEqual(expand("title}}"), "title}}")
        XCTAssertEqual(expand("{title}"), "{title}")
        XCTAssertEqual(expand("{{{title}}}"), "{T}")
        // Known tokens around unknown ones still expand, in paths too.
        XCTAssertEqual(expand("{{x {{title}} {{y}} {{date:yyyy}}"), "{{x T {{y}} 2026")
        XCTAssertEqual(TemplateParser.expandPath("{{who}}/{{title}}", title: "T", in: env), "{{who}}/T")
    }

    func testTP3_literalTextSurvivesByteForByte() throws {
        let text = "Plain *markdown*, [[links]], #tags, `code`, tabs\tand\r\nCRLF, unicode Straße 😀.\n"
        XCTAssertEqual(TemplateParser.expandBody(text, title: "T"), .init(text: text, cursorOffset: nil))
        XCTAssertEqual(TemplateParser.expandPath(text, title: "T"), text)
    }
}
