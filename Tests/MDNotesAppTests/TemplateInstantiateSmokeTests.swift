import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for making a note from a template through the window (TP-4), over a
/// real library: an existing path is opened and nothing written; a new path is created with
/// its folders and the expanded body, listed, and opened with the caret at `{{cursor}}` or the
/// end and the editor focused; an illegal expanded path (C-3), a template that does not parse
/// (TP-2) and a template that is not there are refused inline with nothing created.
@MainActor
final class TemplateInstantiateSmokeTests: XCTestCase {
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
            .appendingPathComponent("mdnotes-instantiate-\(UUID().uuidString)", isDirectory: true)
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

    /// A laid-out window with a ready library attached and the search field focused, as at
    /// launch, listing the fixture notes under the empty query.
    private func makeController(autosaveClock: any AutosaveClock = SystemAutosaveClock()) async throws
        -> (MainWindowController, NSWindow)
    {
        let controller = makeMainWindowController(autosaveClock: autosaveClock)
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        await waitUntil("library ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [beta, alpha])
        await waitUntil("templates listed") { !library.templateNames.isEmpty }
        XCTAssertEqual(library.templateNames, ["colon", "daily", "existing", "headless", "meeting"])
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        XCTAssertTrue(searchFieldHasFocus(controller))
        return (controller, window)
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

    /// Asks the window to instantiate the template and waits for it to settle, returning the
    /// note it reported.
    private func instantiateAndSettle(
        _ controller: MainWindowController, _ name: String, title: String
    ) async throws -> NoteID? {
        let settled = expectation(description: "instantiation settled")
        var reported: NoteID?
        controller.onInstantiateTemplate = { id in
            reported = id
            settled.fulfill()
        }
        controller.instantiateTemplate(named: name, title: title, in: try environment())
        await fulfillment(of: [settled], timeout: 10)
        controller.onInstantiateTemplate = nil
        return reported
    }

    /// A focused text field's first responder is its field editor, not the field itself.
    private func searchFieldHasFocus(_ controller: MainWindowController) -> Bool {
        guard let editor = controller.window?.firstResponder as? NSTextView else { return false }
        return editor.isFieldEditor && editor.delegate === controller.mainView.searchField
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

    private func modificationDate(_ id: NoteID) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url(id.relativePath).path)[.modificationDate] as? Date)
    }

    // MARK: TP-4 an existing path is opened and nothing is written

    func testTP4_existingPathIsOpenedWithoutWritingAnything() async throws {
        let (controller, window) = try await makeController()
        let stamp = try modificationDate(beta)
        let snapshotStamp = try XCTUnwrap(controller.library?.snapshot.entry(for: beta)?.modifiedAt)

        let reported = try await instantiateAndSettle(controller, "existing", title: "ignored")
        XCTAssertEqual(reported, beta)
        XCTAssertEqual(controller.listController.selectedID, beta, "the empty query lists it, so it is selected")
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView, "and the editor is focused")
        XCTAssertEqual(controller.editorController.noteID, beta)
        await waitForEditor(controller, toShow: beta)
        XCTAssertEqual(controller.mainView.textView.string, "beta body", "the file's own text, not the template's")
        XCTAssertEqual(controller.mainView.textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.mainView.textView.isEditable)
        XCTAssertEqual(try fileText(beta), "beta body", "the file is untouched")
        XCTAssertEqual(try modificationDate(beta), stamp)
        XCTAssertEqual(controller.library?.snapshot.entry(for: beta)?.modifiedAt, snapshotStamp)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing was created")
        XCTAssertNil(controller.inlineMessage)
    }

    // MARK: TP-4 a new path is created with folders and the expanded body, caret at the cursor

    func testTP4_newPathIsCreatedWithFoldersAndTheExpandedBodyAndTheCaretAtCursor() async throws {
        let (controller, window) = try await makeController()
        let created = NoteID(relativePath: "meetings/2026-09-09/Standup.md")

        let reported = try await instantiateAndSettle(controller, "meeting", title: "Standup")
        XCTAssertEqual(reported, created)
        XCTAssertEqual(try fileText(created), "# Standup\n\n\n", "tokens expanded, `{{cursor}}` removed")
        XCTAssertEqual(try filesOnDisk(), (fixtureFiles + ["meetings/2026-09-09/Standup.md"]).sorted())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url("meetings/2026-09-09").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the missing folders were made")

        // The snapshot lists it at once with the body that was written, and the list selects it.
        XCTAssertEqual(
            try XCTUnwrap(controller.library?.snapshot.entry(for: created)).body, CaseFolding.fold("# Standup\n\n\n"),
            "indexed at once, folded as every body is")
        XCTAssertEqual(controller.listController.results.first?.id, created, "the newest note (S-3)")
        XCTAssertEqual(controller.listController.selectedID, created)

        // The editor is focused and shows the new note with the caret where `{{cursor}}` stood.
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertEqual(controller.editorController.noteID, created)
        await waitForEditor(controller, toShow: created)
        XCTAssertEqual(controller.mainView.textView.string, "# Standup\n\n\n")
        XCTAssertEqual(controller.mainView.textView.selectedRange(), NSRange(location: 11, length: 0))
        XCTAssertTrue(controller.mainView.textView.isEditable)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView, "the load did not move focus")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "", "the field is not edited")
        XCTAssertNil(controller.inlineMessage)
    }

    func testTP4_withoutACursorTheCaretGoesToTheEnd() async throws {
        let (controller, window) = try await makeController()
        let created = NoteID(relativePath: "daily/2026-09-09.md")

        let reported = try await instantiateAndSettle(controller, "daily", title: "")
        XCTAssertEqual(reported, created)
        XCTAssertEqual(try fileText(created), "# Wednesday\n")
        XCTAssertEqual(controller.listController.selectedID, created)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        await waitForEditor(controller, toShow: created)
        XCTAssertEqual(controller.mainView.textView.string, "# Wednesday\n")
        XCTAssertEqual(
            controller.mainView.textView.selectedRange(),
            NSRange(location: ("# Wednesday\n" as NSString).length, length: 0))
        XCTAssertNil(controller.inlineMessage)
    }

    func testTP4_instantiatingTwiceOpensTheNoteMadeTheFirstTimeAndWritesNothing() async throws {
        let clock = ManualAutosaveClock()
        let (controller, window) = try await makeController(autosaveClock: clock)
        let created = NoteID(relativePath: "meetings/2026-09-09/Standup.md")
        let first = try await instantiateAndSettle(controller, "meeting", title: "Standup")
        XCTAssertEqual(first, created)
        await waitForEditor(controller, toShow: created)
        let stamp = try modificationDate(created)

        // Type into the note, then instantiate the same template and title again: the file is
        // found, so nothing is written, the note stays open with its unsaved edit, and the
        // caret is left alone.
        controller.mainView.textView.insertText(
            "agenda", replacementRange: controller.mainView.textView.selectedRange())
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        let second = try await instantiateAndSettle(controller, "meeting", title: "Standup")
        XCTAssertEqual(second, created)
        XCTAssertEqual(controller.listController.selectedID, created)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertEqual(controller.editorController.noteID, created)
        XCTAssertEqual(controller.mainView.textView.string, "# Standup\n\nagenda\n")
        XCTAssertEqual(controller.mainView.textView.selectedRange(), NSRange(location: 17, length: 0))
        XCTAssertEqual(try fileText(created), "# Standup\n\n\n", "the file was not written over")
        XCTAssertEqual(try modificationDate(created), stamp)
        XCTAssertEqual(try filesOnDisk(), (fixtureFiles + ["meetings/2026-09-09/Standup.md"]).sorted())

        // The edit reaches the file through autosave as usual (E-4).
        clock.advance(by: 1)
        await waitUntil("autosave landed") { (try? self.fileText(created)) == "# Standup\n\nagenda\n" }
    }

    // MARK: C-3 an illegal expanded path is refused inline and nothing is created

    func testC3_illegalExpandedPathIsRefusedInlineAndNothingIsCreated() async throws {
        let (controller, _) = try await makeController()
        XCTAssertNil(controller.inlineMessage)
        XCTAssertTrue(controller.mainView.messageLabel.isHidden)

        let reported = try await instantiateAndSettle(controller, "colon", title: "Meeting")
        XCTAssertNil(reported)
        let message = try XCTUnwrap(controller.inlineMessage)
        XCTAssertEqual(message, NoteCreation.Rejection.illegalCharacter(":").message, "the C-3 reason, as typed")
        XCTAssertFalse(controller.mainView.messageLabel.isHidden)
        XCTAssertEqual(controller.mainView.messageLabel.stringValue, message)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles, "nothing was created")
        XCTAssertTrue(searchFieldHasFocus(controller), "focus stays in the field")
        XCTAssertNil(controller.editorController.noteID)
        XCTAssertNil(controller.listController.selectedID)
    }

    func testC3_pathThatExpandsToAnEmptySegmentWithoutATitleIsRefusedInline() async throws {
        let (controller, _) = try await makeController()
        // `meetings/{{date}}/{{title}}` with no title ends in `/`: an empty file name (C-3).
        let reported = try await instantiateAndSettle(controller, "meeting", title: "")
        XCTAssertNil(reported)
        XCTAssertEqual(controller.inlineMessage, NoteCreation.Rejection.emptySegment.message)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("meetings").path), "no folder was made either")
        XCTAssertNil(controller.editorController.noteID)

        // A later, good instantiation clears the message.
        let good = try await instantiateAndSettle(controller, "meeting", title: "Standup")
        XCTAssertNotNil(good)
        XCTAssertNil(controller.inlineMessage)
        XCTAssertTrue(controller.mainView.messageLabel.isHidden)
    }

    // MARK: TP-2 a template that does not parse, or is not there, is refused inline

    func testTP2_unparsedTemplateIsRefusedInlineWithItsOwnReason() async throws {
        let (controller, _) = try await makeController()
        let reported = try await instantiateAndSettle(controller, "headless", title: "x")
        XCTAssertNil(reported)
        XCTAssertEqual(controller.inlineMessage, TemplateParser.Rejection.missingHeader.message)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
        XCTAssertNil(controller.editorController.noteID)
    }

    func testTP4_missingTemplateIsRefusedInline() async throws {
        let (controller, _) = try await makeController()
        let reported = try await instantiateAndSettle(controller, "nope", title: "x")
        XCTAssertNil(reported)
        XCTAssertNotNil(controller.inlineMessage)
        XCTAssertEqual(try filesOnDisk(), fixtureFiles)
        XCTAssertNil(controller.editorController.noteID)
    }

    func testTP4_withoutALibraryNothingHappens() async throws {
        let controller = makeMainWindowController()
        var reports = 0
        controller.onInstantiateTemplate = { _ in reports += 1 }
        controller.instantiateTemplate(named: "meeting", title: "x", in: try environment())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reports, 0)
        XCTAssertNil(controller.inlineMessage)
    }
}
