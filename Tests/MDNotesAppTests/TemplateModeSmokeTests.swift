import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for template mode in the search field (TP-5) over a real library,
/// keystrokes through the window's real field editor and key events through the window: `@`
/// lists templates instead of notes, the word after it filters them by name, each row's
/// snippet is the path the template would create, Enter instantiates the selected or first
/// template with the remaining words as the title, a template whose path needs a title is
/// refused inline without one, `@` alone lists all, Escape leaves the mode, and a re-listed
/// `templates/` reaches the rows on show (TP-7). Template mode's window is rendered (V-1).
@MainActor
final class TemplateModeSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Written oldest first, so the empty query lists Beta then Alpha (S-3).
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "alpha body"),
        ("daily/Beta.md", "beta body"),
    ]
    private static let templates: [(name: String, text: String)] = [
        ("meeting", "---\npath: meetings/{{date:yyyy-MM-dd}}/{{title}}\n---\n# {{title}}\n\n{{cursor}}\n"),
        ("daily", "---\npath: daily/{{date:yyyy-MM-dd}}\n---\n# {{date:EEEE}}\n"),
        ("existing", "---\npath: daily/Beta\n---\n# {{cursor}}would be written\n"),
        ("colon", "---\npath: {{title}}: notes\n---\n"),
        ("headless", "no header here\n"),
    ]
    private static let allTemplateNames = ["colon", "daily", "existing", "headless", "meeting"]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Wednesday 9 September 2026, 23:30:00 UTC, which the environment pins in UTC.
    private static let instant = Date(timeIntervalSince1970: 1_788_996_600)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let fixtureFiles = [
        "Alpha.md", "daily/Beta.md", "templates/colon.md", "templates/daily.md", "templates/existing.md",
        "templates/headless.md", "templates/meeting.md",
    ]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-template-mode-\(UUID().uuidString)", isDirectory: true)
        for (i, note) in Self.notes.enumerated() {
            try write(note.path, note.body, modifiedAt: Self.base.addingTimeInterval(Double(i) * 60))
        }
        for template in Self.templates {
            try write("templates/\(template.name).md", template.text, modifiedAt: Self.base)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    // MARK: - Fixture

    private func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    private func write(_ relativePath: String, _ body: String, modifiedAt: Date) throws {
        try FileManager.default.createDirectory(
            at: url(relativePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url(relativePath), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url(relativePath).path)
    }

    private func environment() throws -> TemplateParser.Environment {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return TemplateParser.Environment(
            date: Self.instant, timeZone: zone, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A laid-out window with a ready library attached, its templates listed, the date pinned
    /// and the search field focused, as at launch, listing the fixture notes under the empty
    /// query. No watcher: the TP-7 test feeds the change through `apply(_:)` itself.
    private func makeController() async throws -> (MainWindowController, LibraryController, NSWindow) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let environment = try environment()
        controller.templateEnvironment = { environment }
        let library = LibraryController(root: root, watchesFileSystem: false)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [beta, alpha])
        await waitUntil("templates listed") { !library.templateNames.isEmpty }
        XCTAssertEqual(library.templateNames, Self.allTemplateNames)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        XCTAssertTrue(searchFieldHasFocus(controller))
        return (controller, library, window)
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for the editor's read of `id` to land, the async tail of S-8.
    private func waitForEditor(_ controller: MainWindowController, toShow id: NoteID) async {
        await waitUntil("editor shows \(id.relativePath)") {
            controller.editorController.noteID == id && controller.editorController.body != nil
        }
    }

    // MARK: - Typing and keys

    /// The field editor currently editing the search field.
    private func fieldEditor(_ controller: MainWindowController) throws -> NSTextView {
        try XCTUnwrap(
            controller.mainView.searchField.currentEditor() as? NSTextView, "search field is not being edited")
    }

    /// Types `text` into the search field one character at a time, as key presses would.
    private func type(_ text: String, into controller: MainWindowController) throws {
        let editor = try fieldEditor(controller)
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    /// Replaces the search field's text with `text` through its field editor, as selecting
    /// all and typing would.
    private func retype(_ text: String, into controller: MainWindowController) throws {
        let editor = try fieldEditor(controller)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private enum Key {
        case down, escape, `return`

        var characters: String {
            switch self {
            case .down: "\u{F701}"  // NSDownArrowFunctionKey
            case .escape: "\u{1B}"
            case .return: "\r"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .down: 125
            case .escape: 53
            case .return: 36
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .down: .function
            case .escape, .return: []
            }
        }
    }

    /// Sends `key` as a user's key press: a `keyDown` then a `keyUp`, key equivalents offered
    /// first as the running app's event loop would.
    private func press(_ key: Key, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: key.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                    isARepeat: false, keyCode: key.keyCode))
            if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
    }

    /// Presses Enter and waits for the instantiation it starts to settle, returning the note
    /// it reported, or nil for a refusal.
    private func pressReturnAndSettle(_ controller: MainWindowController, in window: NSWindow) async throws
        -> NoteID?
    {
        let settled = expectation(description: "instantiation settled")
        var reported: NoteID?
        controller.onInstantiateTemplate = { id in
            reported = id
            settled.fulfill()
        }
        try press(.return, in: window)
        await fulfillment(of: [settled], timeout: 10)
        controller.onInstantiateTemplate = nil
        return reported
    }

    /// A focused text field's first responder is its field editor, not the field itself.
    private func searchFieldHasFocus(_ controller: MainWindowController) -> Bool {
        guard let editor = controller.window?.firstResponder as? NSTextView else { return false }
        return editor.isFieldEditor && editor.delegate === controller.mainView.searchField
    }

    // MARK: - What the list shows

    private func templateNames(_ controller: MainWindowController) -> [String]? {
        controller.listController.templateRows?.map(\.name)
    }

    private func snippets(_ controller: MainWindowController) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: (controller.listController.templateRows ?? []).map { ($0.name, $0.snippet) })
    }

    /// The row view at `row`, made if the table has not laid it out yet.
    private func rowView(_ controller: MainWindowController, row: Int) throws -> NoteRowView {
        let table = controller.mainView.tableView
        table.layoutSubtreeIfNeeded()
        return try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NoteRowView)
    }

    /// Every file under the root, as relative paths, hidden and temp files included.
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

    private func fileText(_ id: NoteID) throws -> String {
        try String(contentsOf: url(id.relativePath), encoding: .utf8)
    }

    // MARK: TP-5 `@` alone lists all templates instead of notes

    func testTP5_atAloneListsEveryTemplateInsteadOfNotes() async throws {
        let (controller, _, _) = try await makeController()
        // A note selected before is no longer: the list shows no notes at all.
        XCTAssertTrue(controller.listController.select(beta))
        await waitForEditor(controller, toShow: beta)

        try type("@", into: controller)
        XCTAssertEqual(controller.query, "@")
        XCTAssertTrue(controller.isInTemplateMode)
        XCTAssertTrue(controller.listController.isShowingTemplates)
        XCTAssertEqual(templateNames(controller), Self.allTemplateNames, "the store's order, all of them")
        XCTAssertEqual(controller.listController.results.count, 0, "no notes are listed")
        XCTAssertEqual(controller.mainView.tableView.numberOfRows, 5)
        XCTAssertNil(controller.listController.selectedID)
        XCTAssertNil(controller.listController.selectedEntry)
        XCTAssertNil(controller.listController.selectedTemplate)
        XCTAssertNil(controller.editorController.noteID, "the editor empties as for a query listing nothing")
        XCTAssertTrue(searchFieldHasFocus(controller))

        // The rows are the second row kind: name where the title goes, no date, no thumbnail.
        let daily = try rowView(controller, row: 1)
        XCTAssertEqual(daily.titleLabel.stringValue, "daily")
        XCTAssertEqual(daily.snippetLabel.stringValue, "daily/2026-09-09")
        XCTAssertEqual(daily.dateLabel.stringValue, "")
        XCTAssertTrue(daily.thumbnailView.isHidden)
        XCTAssertNil(daily.thumbnailPath)
    }

    func testTP5_atFollowedByWhitespaceStillListsEveryTemplate() async throws {
        let (controller, _, _) = try await makeController()
        try type("@ ", into: controller)
        XCTAssertEqual(templateNames(controller), Self.allTemplateNames)
        try type("Standup", into: controller)
        XCTAssertEqual(templateNames(controller), Self.allTemplateNames, "words after the space are the title")
        XCTAssertEqual(snippets(controller)["meeting"], "meetings/2026-09-09/Standup")
    }

    // MARK: TP-5 the word after `@` filters templates by name with the S-2 rules

    func testTP5_wordAfterAtFiltersTemplatesByNameCaseInsensitively() async throws {
        let (controller, _, _) = try await makeController()
        try type("@DAI", into: controller)
        XCTAssertEqual(templateNames(controller), ["daily"])
        try retype("@e", into: controller)
        XCTAssertEqual(templateNames(controller), ["existing", "headless", "meeting"], "a substring anywhere")
        try retype("@ing", into: controller)
        XCTAssertEqual(templateNames(controller), ["existing", "meeting"])
        try retype("@zzz", into: controller)
        XCTAssertEqual(templateNames(controller), [], "nothing matches, and the list is still in template mode")
        XCTAssertTrue(controller.listController.isShowingTemplates)
        XCTAssertEqual(controller.mainView.tableView.numberOfRows, 0)
        try retype("@meeting Standup notes", into: controller)
        XCTAssertEqual(templateNames(controller), ["meeting"], "only the first word filters")
    }

    func testTP5_everyKeystrokeReloadsTheTemplateRows() async throws {
        let (controller, _, _) = try await makeController()
        var seen: [(query: String, rows: Int)] = []
        let editor = try fieldEditor(controller)
        for character in "@dai" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            seen.append((controller.query, controller.mainView.tableView.numberOfRows))
        }
        XCTAssertEqual(seen.map(\.query), ["@", "@d", "@da", "@dai"])
        XCTAssertEqual(seen.map(\.rows), [5, 2, 1, 1], "`@d` lists daily and headless")

        // Deleting the `@` leaves template mode for the note query the rest makes.
        editor.selectAll(nil)
        editor.insertText("alpha", replacementRange: editor.selectedRange())
        XCTAssertEqual(controller.query, "alpha")
        XCTAssertFalse(controller.isInTemplateMode)
        XCTAssertFalse(controller.listController.isShowingTemplates)
        XCTAssertNil(controller.listController.templateRows)
        XCTAssertEqual(controller.listController.results.map(\.id), [alpha])
    }

    // MARK: TP-5 the snippet is the expanded path

    func testTP5_rowSnippetIsThePathTheTemplateWouldCreate() async throws {
        let (controller, _, _) = try await makeController()
        try type("@", into: controller)
        XCTAssertEqual(
            snippets(controller),
            [
                "colon": "{{title}}: notes",
                "daily": "daily/2026-09-09",
                "existing": "daily/Beta",
                "headless": TemplateParser.Rejection.missingHeader.message,
                "meeting": "meetings/2026-09-09/{{title}}",
            ], "date tokens expanded (TP-3), `{{title}}` shown where a title is wanted, a bad template says why (TP-2)")

        try type("meeting Standup", into: controller)
        XCTAssertEqual(snippets(controller), ["meeting": "meetings/2026-09-09/Standup"], "the title words fill it in")
        try type(" for Tuesday", into: controller)
        XCTAssertEqual(snippets(controller), ["meeting": "meetings/2026-09-09/Standup for Tuesday"])
        let row = try rowView(controller, row: 0)
        XCTAssertEqual(row.titleLabel.stringValue, "meeting")
        XCTAssertEqual(row.snippetLabel.stringValue, "meetings/2026-09-09/Standup for Tuesday")
    }

    // MARK: TP-5 Enter instantiates the first template with the remaining words as the title

    func testTP5_enterInstantiatesTheFirstListedTemplateWithTheRemainingWordsAsTitle() async throws {
        let (controller, _, window) = try await makeController()
        let created = NoteID(relativePath: "meetings/2026-09-09/Weekly sync.md")
        try type("@meet Weekly  sync", into: controller)
        XCTAssertEqual(templateNames(controller), ["meeting"])
        XCTAssertNil(controller.listController.selectedTemplate, "nothing selected: the first row acts")

        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created)
        XCTAssertEqual(try fileText(created), "# Weekly sync\n\n\n", "the title as words, joined by one space")
        XCTAssertEqual(try filesOnDisk(), (fixtureFiles + ["meetings/2026-09-09/Weekly sync.md"]).sorted())
        XCTAssertNil(controller.inlineMessage)

        // The note is open and the editor focused with the caret at `{{cursor}}` (TP-4)...
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertEqual(controller.editorController.noteID, created)
        await waitForEditor(controller, toShow: created)
        XCTAssertEqual(controller.mainView.textView.string, "# Weekly sync\n\n\n")
        XCTAssertEqual(controller.mainView.textView.selectedRange(), NSRange(location: 15, length: 0))
        // ...while the field keeps the query and the list keeps showing templates.
        XCTAssertEqual(controller.mainView.searchField.stringValue, "@meet Weekly  sync")
        XCTAssertEqual(controller.query, "@meet Weekly  sync")
        XCTAssertTrue(controller.listController.isShowingTemplates)
        XCTAssertEqual(templateNames(controller), ["meeting"])
        XCTAssertNil(controller.listController.selectedID)
        XCTAssertNotNil(controller.library?.snapshot.entry(for: created), "and the snapshot lists it")

        // Escape then shows the note among the others, selected as the editor's note (S-8).
        try press(.escape, in: window)
        XCTAssertEqual(controller.query, "")
        XCTAssertFalse(controller.listController.isShowingTemplates)
        XCTAssertEqual(controller.listController.results.map(\.id), [created, beta, alpha])
        XCTAssertEqual(controller.listController.selectedID, created)
        XCTAssertEqual(controller.editorController.noteID, created)
        XCTAssertTrue(searchFieldHasFocus(controller))
    }

    func testTP5_enterOpensAnExistingPathWithoutWriting() async throws {
        let (controller, _, window) = try await makeController()
        let text = try fileText(beta)
        try type("@exist", into: controller)
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, beta)
        XCTAssertEqual(try fileText(beta), text, "found, not written (TP-4)")
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
        XCTAssertEqual(controller.editorController.noteID, beta)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertTrue(controller.listController.isShowingTemplates)
        XCTAssertNil(controller.inlineMessage)
    }

    func testTP5_enterActsOnTheSelectedTemplate() async throws {
        let (controller, _, window) = try await makeController()
        let table = controller.mainView.tableView
        try type("@", into: controller)

        // Down from the field selects the first row and focuses the list (S-7); Down again
        // moves to `daily`. Enter in the list acts on it.
        try press(.down, in: window)
        XCTAssertIdentical(window.firstResponder, table)
        XCTAssertEqual(controller.listController.selectedTemplate?.name, "colon")
        XCTAssertNil(controller.listController.selectedEntry, "a template row is not a note")
        XCTAssertNil(controller.editorController.noteID, "so selecting it loads nothing")
        try press(.down, in: window)
        XCTAssertEqual(controller.listController.selectedTemplate?.name, "daily")
        let created = NoteID(relativePath: "daily/2026-09-09.md")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created)
        XCTAssertEqual(try fileText(created), "# Wednesday\n")
        XCTAssertEqual(controller.editorController.noteID, created)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertTrue(controller.listController.isShowingTemplates, "the list still shows templates")

        // Back in the field with a row selected, Enter acts on that row, not the first.
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(controller.listController.selectedTemplate?.name, "existing")
        let second = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(second, beta)
        XCTAssertEqual(controller.editorController.noteID, beta)
    }

    func testTP5_theSelectedTemplateStaysSelectedWhileTheFilterStillListsIt() async throws {
        let (controller, _, _) = try await makeController()
        let table = controller.mainView.tableView
        try type("@", into: controller)
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        XCTAssertEqual(controller.listController.selectedTemplate?.name, "meeting")
        try type("e", into: controller)
        XCTAssertEqual(templateNames(controller), ["existing", "headless", "meeting"])
        XCTAssertEqual(controller.listController.selectedTemplate?.name, "meeting", "followed to its new row")
        XCTAssertEqual(table.selectedRow, 2)
        try type("x", into: controller)
        XCTAssertEqual(templateNames(controller), ["existing"])
        XCTAssertNil(controller.listController.selectedTemplate, "no longer listed, so nothing is selected")
        XCTAssertEqual(table.selectedRow, -1)
    }

    // MARK: TP-5 a path that needs `{{title}}` asks for one inline and creates nothing

    func testTP5_enterWithoutATitleWhenThePathNeedsOneAsksInlineAndCreatesNothing() async throws {
        let (controller, _, window) = try await makeController()
        try type("@meeting", into: controller)
        XCTAssertTrue(controller.mainView.messageLabel.isHidden)

        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertNil(reported)
        let message = try XCTUnwrap(controller.inlineMessage)
        XCTAssertTrue(message.contains("needs a title"), message)
        XCTAssertTrue(message.contains("meeting"), message)
        XCTAssertFalse(controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(controller.mainView.messageLabel.stringValue, message)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing was created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("meetings").path), "no folder was made either")
        XCTAssertNil(controller.editorController.noteID)
        XCTAssertTrue(searchFieldHasFocus(controller), "focus stays in the field to type the title")
        XCTAssertEqual(controller.query, "@meeting", "the query is kept")
        XCTAssertTrue(controller.listController.isShowingTemplates)

        // Typing the title clears the message, and Enter then creates the note.
        try type(" Standup", into: controller)
        XCTAssertNil(controller.inlineMessage)
        XCTAssertTrue(controller.mainView.messageLabel.isHidden)
        let created = NoteID(relativePath: "meetings/2026-09-09/Standup.md")
        let retried = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(retried, created)
        XCTAssertEqual(try fileText(created), "# Standup\n\n\n")
    }

    func testTP5_aTemplateWhosePathNeedsNoTitleIsInstantiatedWithoutOne() async throws {
        let (controller, _, window) = try await makeController()
        try type("@daily", into: controller)
        let created = NoteID(relativePath: "daily/2026-09-09.md")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertEqual(reported, created)
        XCTAssertNil(controller.inlineMessage)
        XCTAssertEqual(try fileText(created), "# Wednesday\n")
    }

    func testTP5_enterWithNoMatchingTemplateShowsAMessageAndCreatesNothing() async throws {
        let (controller, _, window) = try await makeController()
        try type("@zzz", into: controller)
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertNil(reported)
        let message = try XCTUnwrap(controller.inlineMessage)
        XCTAssertTrue(message.contains("zzz"), message)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
        XCTAssertNil(controller.editorController.noteID)
        XCTAssertTrue(searchFieldHasFocus(controller))
    }

    func testTP2_enterOnATemplateThatDoesNotParseIsRefusedWithItsOwnReason() async throws {
        let (controller, _, window) = try await makeController()
        try type("@headless a title", into: controller)
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertNil(reported)
        XCTAssertEqual(controller.inlineMessage, TemplateParser.Rejection.missingHeader.message)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    func testC3_enterOnATemplateWhoseExpandedPathIsIllegalIsRefusedInline() async throws {
        let (controller, _, window) = try await makeController()
        try type("@colon Meeting", into: controller)
        XCTAssertEqual(snippets(controller)["colon"], "Meeting: notes")
        let reported = try await pressReturnAndSettle(controller, in: window)
        XCTAssertNil(reported)
        XCTAssertEqual(controller.inlineMessage, NoteCreation.Rejection.illegalCharacter(":").message)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
    }

    // MARK: TP-5 Escape leaves template mode as it clears any query (S-7)

    func testTP5_escapeInTheFieldLeavesTemplateModeAndClearsTheQuery() async throws {
        let (controller, _, window) = try await makeController()
        try type("@dai", into: controller)
        XCTAssertTrue(controller.listController.isShowingTemplates)

        try press(.escape, in: window)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "")
        XCTAssertEqual(controller.query, "")
        XCTAssertFalse(controller.isInTemplateMode)
        XCTAssertFalse(controller.listController.isShowingTemplates)
        XCTAssertNil(controller.listController.templateRows)
        XCTAssertEqual(controller.listController.results.map(\.id), [beta, alpha], "every note again")
        XCTAssertEqual(controller.mainView.tableView.numberOfRows, 2)
        XCTAssertNil(controller.listController.selectedID)
        XCTAssertTrue(searchFieldHasFocus(controller))
        let row = try rowView(controller, row: 0)
        XCTAssertEqual(row.titleLabel.stringValue, "Beta")
        XCTAssertEqual(row.snippetLabel.stringValue, "beta body")
        XCTAssertNotEqual(row.dateLabel.stringValue, "", "a note row has its date back")
    }

    func testTP5_escapeInTheListLeavesTemplateModeAndReturnsToTheField() async throws {
        let (controller, _, window) = try await makeController()
        try type("@", into: controller)
        try press(.down, in: window)
        XCTAssertIdentical(window.firstResponder, controller.mainView.tableView)
        XCTAssertEqual(controller.listController.selectedTemplate?.name, "colon")

        try press(.escape, in: window)
        XCTAssertEqual(controller.query, "")
        XCTAssertFalse(controller.listController.isShowingTemplates)
        XCTAssertEqual(controller.listController.results.map(\.id), [beta, alpha])
        XCTAssertNil(controller.listController.selectedTemplate)
        XCTAssertNil(controller.listController.selectedID)
        XCTAssertTrue(searchFieldHasFocus(controller))
    }

    // MARK: TP-7 a re-listed `templates/` reaches the rows on show

    func testTP7_relistedTemplatesReachTheRowsOnShow() async throws {
        let (controller, library, _) = try await makeController()
        try type("@", into: controller)
        XCTAssertEqual(templateNames(controller), Self.allTemplateNames)

        try write("templates/zulu.md", "---\npath: z/{{date:yyyy}}/{{title}}\n---\n", modifiedAt: Self.base)
        library.apply(LibraryChanges(templates: ["zulu"]))
        await waitUntil("zulu listed") { self.templateNames(controller)?.contains("zulu") == true }
        XCTAssertEqual(templateNames(controller), Self.allTemplateNames + ["zulu"])
        XCTAssertEqual(snippets(controller)["zulu"], "z/2026/{{title}}")
        XCTAssertEqual(controller.mainView.tableView.numberOfRows, 6)

        // A changed template's row shows its new path.
        try write("templates/zulu.md", "---\npath: zed/{{title}}\n---\n", modifiedAt: Self.base)
        library.apply(LibraryChanges(templates: ["zulu"]))
        await waitUntil("zulu re-read") { self.snippets(controller)["zulu"] == "zed/{{title}}" }

        // A removed one leaves the rows.
        try FileManager.default.removeItem(at: url("templates/zulu.md"))
        library.apply(LibraryChanges(templates: ["zulu"]))
        await waitUntil("zulu gone") { self.templateNames(controller) == Self.allTemplateNames }
        XCTAssertEqual(controller.mainView.tableView.numberOfRows, 5)
    }

    func testTP7_aRelistingInNoteModeLeavesTheNoteListAlone() async throws {
        let (controller, library, _) = try await makeController()
        try type("beta", into: controller)
        XCTAssertEqual(controller.listController.results.map(\.id), [beta])
        try write("templates/zulu.md", "---\npath: z\n---\n", modifiedAt: Self.base)
        library.apply(LibraryChanges(templates: ["zulu"]))
        await waitUntil("zulu listed") { library.templateNames.contains("zulu") }
        XCTAssertFalse(controller.listController.isShowingTemplates)
        XCTAssertEqual(controller.listController.results.map(\.id), [beta])
    }

    // MARK: V-1 the window in template mode

    func testV1_templateModeWindowSnapshot() async throws {
        let (controller, _, _) = try await makeController()
        try type("@meeting Standup", into: controller)
        XCTAssertEqual(templateNames(controller), ["meeting"])
        try retype("@", into: controller)
        controller.mainView.tableView.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        let written = try writeWindowSnapshots(of: controller, named: "template-list")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }
}
