import Foundation
import MDNotesCore
import XCTest

/// The pure and disk halves of making a note from a template (TP-4): a template plus a title
/// planned into the note it names and the body it gets, every C-3 rule refusing an expanded
/// path, an unparsed template refused with its own reason (TP-2), and `NoteStore.instantiate`
/// leaving an existing file alone or writing a new one with its folders and the caret placed.
final class TemplateInstantiationTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    private var store = NoteStore(root: FileManager.default.temporaryDirectory)

    /// Wednesday 9 September 2026, 23:30:00 UTC. Pinned so the date tokens are exact.
    private let instant = Date(timeIntervalSince1970: 1_788_996_600)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-instantiate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func environment() throws -> TemplateParser.Environment {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return TemplateParser.Environment(
            date: instant, timeZone: zone, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func template(_ path: String, body: String = "") -> TemplateParser.Template {
        TemplateParser.Template(path: path, body: body)
    }

    private func plan(_ template: TemplateParser.Template, title: String) throws -> TemplateInstantiation.Plan {
        try TemplateInstantiation.plan(template, title: title, in: try environment())
    }

    private func rejection(of template: TemplateParser.Template, title: String) throws
        -> TemplateInstantiation.Rejection?
    {
        do {
            _ = try TemplateInstantiation.plan(template, title: title, in: try environment())
            return nil
        } catch let rejection as TemplateInstantiation.Rejection {
            return rejection
        }
    }

    /// Every file under the root, as relative paths, temp files included.
    private func filesOnDisk() throws -> [String] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []))
        var paths: [String] = []
        for case let url as URL in enumerator
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            paths.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
        }
        return paths.sorted()
    }

    // MARK: TP-4 the plan: path and body expanded for the title, path judged as a query

    func testTP4_planExpandsThePathAndTheBodyForTheTitle() throws {
        let plan = try plan(
            template("meetings/{{date:yyyy-MM-dd}}/{{title}}", body: "# {{title}}\n\n{{cursor}}\nend"),
            title: "Standup")
        XCTAssertEqual(plan.id, NoteID(relativePath: "meetings/2026-09-09/Standup.md"))
        XCTAssertEqual(plan.id.title, "Standup")
        XCTAssertEqual(plan.body.text, "# Standup\n\n\nend")
        XCTAssertEqual(plan.body.cursorOffset, 11)
    }

    func testTP4_planWithoutCursorHasNoCursorOffset() throws {
        let plan = try plan(template("daily/{{date:yyyy}}/{{date:MM-dd}}", body: "# {{date:EEEE}}\n"), title: "")
        XCTAssertEqual(plan.id, NoteID(relativePath: "daily/2026/09-09.md"))
        XCTAssertEqual(plan.body, TemplateParser.ExpandedBody(text: "# Wednesday\n", cursorOffset: nil))
    }

    func testTP4_expandedPathIsTrimmedLikeAQuery() throws {
        XCTAssertEqual(try plan(template("{{title}}"), title: "  Padded  ").id, NoteID(relativePath: "Padded.md"))
        XCTAssertEqual(
            try plan(template("notes/{{title}}"), title: "two  words ").id, NoteID(relativePath: "notes/two  words.md"))
    }

    func testTP4_cursorInAPathIsLiteralText() throws {
        // `{{cursor}}` is a body token; in a path it is ordinary characters, and legal ones.
        XCTAssertEqual(try plan(template("x{{cursor}}"), title: "").id, NoteID(relativePath: "x{{cursor}}.md"))
    }

    // MARK: C-3 the expanded path is refused by the same rules as a typed query

    func testC3_everyRuleRefusesTheExpandedPathAndNamesIt() throws {
        let cases: [(path: String, title: String, expanded: String, rule: NoteCreation.Rejection)] = [
            ("a:{{title}}", "b", "a:b", .illegalCharacter(":")),
            ("nul\0here", "", "nul\0here", .illegalCharacter("\0")),
            ("meetings/{{title}}", "", "meetings/", .emptySegment),
            ("a//{{title}}", "b", "a//b", .emptySegment),
            ("/{{title}}", "b", "/b", .emptySegment),
            ("../{{title}}", "out", "../out", .relativeSegment("..")),
            ("a/./{{title}}", "b", "a/./b", .relativeSegment(".")),
            (".{{title}}", "hidden", ".hidden", .hiddenSegment(".hidden")),
            ("a/.{{title}}", "b", "a/.b", .hiddenSegment(".b")),
            ("Trash/{{title}}", "gone", "Trash/gone", .skippedFolder("Trash")),
            ("templates/{{date:yyyy}}", "", "templates/2026", .skippedFolder("templates")),
            ("{{title}}", "", "", .empty),
            ("{{title}}", "   ", "   ", .empty),
        ]
        for testCase in cases {
            let rejection = try rejection(of: template(testCase.path), title: testCase.title)
            XCTAssertEqual(rejection, .path(testCase.expanded, testCase.rule), testCase.path)
            let message = try XCTUnwrap(rejection).message
            XCTAssertFalse(message.isEmpty, testCase.path)
            XCTAssertFalse(message.contains("\0"), "the message must be showable: \(testCase.path)")
            XCTAssertEqual(rejection?.localizedDescription, message, "the same text through `any Error`")
        }
    }

    func testC3_aPathRuleKeepsTheQueryMessageAndAnEmptyPathNamesTheTemplate() throws {
        XCTAssertEqual(
            try rejection(of: template("a:{{title}}"), title: "b")?.message,
            NoteCreation.Rejection.illegalCharacter(":").message)
        XCTAssertEqual(
            try rejection(of: template("Trash/{{title}}"), title: "x")?.message,
            NoteCreation.Rejection.skippedFolder("Trash").message)
        // "Type a title to create a note" is about the search field; an empty template path is
        // the template's fault, so its message says so and shows what the path became.
        let empty = try XCTUnwrap(try rejection(of: template("{{title}}"), title: ""))
        XCTAssertNotEqual(empty.message, NoteCreation.Rejection.empty.message)
        XCTAssertTrue(empty.message.lowercased().contains("template"), empty.message)
    }

    // MARK: TP-2 a template that did not parse is refused with its own reason

    func testTP2_unparsedTemplateIsRefusedWithItsParserReason() throws {
        for parserRejection in [TemplateParser.Rejection.missingHeader, .unterminatedHeader, .missingPath] {
            do {
                _ = try TemplateInstantiation.plan(.failure(parserRejection), title: "x", in: try environment())
                XCTFail("\(parserRejection) was accepted")
            } catch let rejection as TemplateInstantiation.Rejection {
                XCTAssertEqual(rejection, .template(parserRejection))
                XCTAssertEqual(rejection.message, parserRejection.message)
                XCTAssertEqual(rejection.localizedDescription, parserRejection.message)
            }
        }
        let parsed = try TemplateInstantiation.plan(
            .success(template("notes/{{title}}", body: "b")), title: "ok", in: try environment())
        XCTAssertEqual(
            parsed,
            TemplateInstantiation.Plan(
                id: NoteID(relativePath: "notes/ok.md"), body: .init(text: "b", cursorOffset: nil)))
    }

    // MARK: TP-4 the store: a new path is created with folders and body; an existing one is untouched

    func testTP4_instantiateCreatesTheFileWithItsFoldersAndTheExpandedBodyAndTheCaretAtCursor() throws {
        let plan = try plan(
            template("meetings/{{date:yyyy-MM-dd}}/{{title}}", body: "# {{title}}\n\n{{cursor}}\n"), title: "Standup")
        let before = Date().addingTimeInterval(-2)
        let outcome = try store.instantiate(plan)
        XCTAssertEqual(outcome.id, plan.id)
        XCTAssertTrue(outcome.created)
        XCTAssertGreaterThanOrEqual(outcome.modifiedAt, before)
        XCTAssertEqual(outcome.cursorOffset, 11, "where `{{cursor}}` stood")
        XCTAssertEqual(try store.read(plan.id), .text("# Standup\n\n\n"))
        XCTAssertEqual(try store.modificationDate(of: plan.id), outcome.modifiedAt)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("meetings/2026-09-09").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the missing folders were made")
        XCTAssertEqual(try filesOnDisk(), ["meetings/2026-09-09/Standup.md"], "and no temp file is left behind")
        XCTAssertEqual(try LibraryScanner.scan(root: root).map(\.id), [plan.id], "the scanner lists it")
    }

    func testTP4_instantiateWithoutCursorPutsTheCaretAtTheEndInUTF16() throws {
        // An emoji is one Character and two UTF-16 units; the caret is counted as NSRange does.
        let plan = try plan(template("{{title}}", body: "# {{title}} \u{1F389}"), title: "Party")
        let outcome = try store.instantiate(plan)
        XCTAssertTrue(outcome.created)
        XCTAssertEqual(try store.read(plan.id), .text("# Party \u{1F389}"))
        XCTAssertEqual(outcome.cursorOffset, ("# Party \u{1F389}" as NSString).length)
        XCTAssertEqual(outcome.cursorOffset, 10)
    }

    func testTP4_instantiateOpensAnExistingFileWithoutWritingIt() throws {
        let plan = try plan(template("daily/{{date:yyyy-MM-dd}}", body: "# {{cursor}}fresh"), title: "")
        let url = store.url(for: plan.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "precious".write(to: url, atomically: true, encoding: .utf8)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        let outcome = try store.instantiate(plan)
        XCTAssertEqual(outcome.id, plan.id)
        XCTAssertFalse(outcome.created)
        XCTAssertEqual(outcome.modifiedAt, stamp, "the file was not touched")
        XCTAssertNil(outcome.cursorOffset, "the caret is left where opening the note puts it")
        XCTAssertEqual(try store.read(plan.id), .text("precious"))
        XCTAssertEqual(try filesOnDisk(), ["daily/2026-09-09.md"], "nothing else was written")
    }

    func testTP4_instantiateNeverOverwritesACaseVariantOfAnExistingFile() throws {
        let existing = try plan(template("Notes/{{title}}"), title: "Keep")
        XCTAssertTrue(try store.instantiate(existing).created)
        let variant = try plan(template("notes/{{title}}", body: "new body"), title: "keep")
        let outcome = try store.instantiate(variant)
        // On a case-insensitive volume the two ids name one file, which stays as it is.
        let isCaseInsensitive = FileManager.default.fileExists(atPath: store.url(for: variant.id).path)
        XCTAssertEqual(outcome.created, !isCaseInsensitive)
        XCTAssertEqual(try store.read(existing.id), .text(""))
    }
}
