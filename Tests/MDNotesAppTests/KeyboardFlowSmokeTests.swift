import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the keyboard flow between the search field, the list and the
/// editor (S-7, S-8, S-12). Every key is a real `NSEvent` sent through `NSWindow.sendEvent`, so it
/// takes the responder-chain path a user's keystroke does: key equivalents first, then the
/// first responder's `keyDown`, `interpretKeyEvents` and the command selector it maps to.
@MainActor
final class KeyboardFlowSmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Written oldest first, so the empty query lists Gamma, Beta, Alpha (S-3).
    private static let notes: [(path: String, body: String)] = [
        ("Alpha.md", "alpha body"),
        ("daily/Beta.md", "beta body"),
        ("Gamma.md", "gamma body"),
    ]
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-keys-\(UUID().uuidString)", isDirectory: true)
        for (i, note) in Self.notes.enumerated() {
            let url = root.appendingPathComponent(note.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try note.body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.base.addingTimeInterval(Double(i) * 60)], ofItemAtPath: url.path)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// A laid-out window with a ready library attached and the search field focused, as at launch.
    private func makeController() async throws -> (MainWindowController, NSWindow) {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let library = LibraryController(root: root)
        controller.attach(library)
        library.start()
        let deadline = Date().addingTimeInterval(20)
        while library.phase != .ready {
            if Date() > deadline {
                XCTFail("library never became ready")
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma, beta, alpha])
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(controller.mainView.searchField))
        XCTAssertTrue(searchFieldHasFocus(controller), "the search field starts focused")
        return (controller, window)
    }

    /// Waits for the editor to show `id`, the async tail of S-8.
    private func waitForEditor(_ controller: MainWindowController, toShow id: NoteID) async {
        let deadline = Date().addingTimeInterval(10)
        while controller.editorController.noteID != id || controller.mainView.textView.string.isEmpty {
            if Date() > deadline { return XCTFail("editor never showed \(id.relativePath)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Keys

    private enum Key {
        case down, up, escape, `return`, keypadEnter, tab
        case shiftTab, controlTab
        case commandL

        var characters: String {
            switch self {
            case .down: "\u{F701}"  // NSDownArrowFunctionKey
            case .up: "\u{F700}"  // NSUpArrowFunctionKey
            case .escape: "\u{1B}"
            case .return: "\r"
            case .keypadEnter: "\u{03}"
            case .tab, .controlTab: "\t"
            case .shiftTab: "\u{19}"  // NSBackTabCharacter, what AppKit reports for Shift-Tab
            case .commandL: "l"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .down: 125
            case .up: 126
            case .escape: 53
            case .return: 36
            case .keypadEnter: 76
            case .tab, .shiftTab, .controlTab: 48
            case .commandL: 37
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .down, .up: .function
            case .keypadEnter: .numericPad
            case .commandL: .command
            case .shiftTab: .shift
            case .controlTab: .control
            case .escape, .return, .tab: []
            }
        }
    }

    /// Sends `key` as a user's key press: a `keyDown` then a `keyUp`. The running app's event
    /// loop (`NSApplication.sendEvent`) offers every `keyDown` to the key window's key
    /// equivalents before the window dispatches it to its first responder; a headless test
    /// process has no key window, so that step is taken here by hand and the rest is the
    /// window's own `sendEvent`.
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

    // MARK: - Focus

    /// A focused text field's first responder is its field editor, not the field itself.
    private func searchFieldHasFocus(_ controller: MainWindowController) -> Bool {
        guard let editor = controller.window?.firstResponder as? NSTextView else { return false }
        return editor.isFieldEditor && editor.delegate === controller.mainView.searchField
    }

    private func firstResponderDescription(_ window: NSWindow) -> String {
        window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    }

    // MARK: S-7 Down from the search field selects the first row

    func testS7_downArrowFromTheSearchFieldSelectsTheFirstRowAndFocusesTheList() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        XCTAssertEqual(table.selectedRow, -1)

        try press(.down, in: window)
        XCTAssertEqual(table.selectedRow, 0, "the first row is selected")
        XCTAssertEqual(controller.listController.selectedID, gamma)
        XCTAssertIdentical(window.firstResponder, table, "focus moves to the list")
        await waitForEditor(controller, toShow: gamma)
        XCTAssertIdentical(window.firstResponder, table, "loading the editor does not steal focus (S-8)")

        // Down in the list is the table's own navigation.
        try press(.down, in: window)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(controller.listController.selectedID, beta)
        XCTAssertIdentical(window.firstResponder, table)
    }

    func testS7_downArrowFromTheSearchFieldSelectsTheFirstRowOfTheFilteredList() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        editor.insertText("alp", replacementRange: editor.selectedRange())
        XCTAssertEqual(controller.listController.results.map(\.id), [alpha])

        try press(.down, in: window)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(controller.listController.selectedID, alpha)
        XCTAssertIdentical(window.firstResponder, table)
        XCTAssertEqual(controller.query, "alp", "the query is untouched")
    }

    func testS7_downArrowWithAnEmptyListLeavesFocusInTheSearchField() async throws {
        let (controller, window) = try await makeController()
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        editor.insertText("zqx", replacementRange: editor.selectedRange())
        XCTAssertEqual(controller.mainView.tableView.numberOfRows, 0)

        try press(.down, in: window)
        XCTAssertEqual(controller.mainView.tableView.selectedRow, -1)
        XCTAssertTrue(searchFieldHasFocus(controller), "nothing to select, so focus stays put")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "zqx")
    }

    // MARK: S-7 Up from the first row returns to the search field

    func testS7_upArrowFromTheFirstRowReturnsToTheSearchField() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        try press(.down, in: window)
        try press(.down, in: window)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertIdentical(window.firstResponder, table)

        // Up from the second row is ordinary list navigation.
        try press(.up, in: window)
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertIdentical(window.firstResponder, table, "up from row 1 stays in the list")

        // Up from the first row leaves the list.
        try press(.up, in: window)
        XCTAssertTrue(
            searchFieldHasFocus(controller),
            "expected the search field's editor, got \(firstResponderDescription(window))")
        XCTAssertEqual(table.selectedRow, 0, "the selection is left alone")
        XCTAssertEqual(controller.listController.selectedID, gamma)
    }

    // MARK: S-7 Escape clears the query and returns to the search field

    func testS7_escapeInTheListClearsTheQueryAndReturnsToTheSearchField() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        editor.insertText("b", replacementRange: editor.selectedRange())
        XCTAssertEqual(controller.query, "b")
        XCTAssertEqual(controller.listController.results.map(\.id), [beta, gamma, alpha])
        try press(.down, in: window)
        XCTAssertIdentical(window.firstResponder, table)
        XCTAssertEqual(controller.listController.selectedID, beta)

        try press(.escape, in: window)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "", "the field is emptied")
        XCTAssertEqual(controller.query, "", "the list was reloaded for the empty query")
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma, beta, alpha])
        XCTAssertTrue(
            searchFieldHasFocus(controller),
            "expected the search field's editor, got \(firstResponderDescription(window))")
        XCTAssertEqual(controller.listController.selectedID, beta, "the selected note is kept")
    }

    func testS7_escapeInTheEditorClearsTheQueryAndReturnsToTheSearchField() async throws {
        let (controller, window) = try await makeController()
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        editor.insertText("alpha", replacementRange: editor.selectedRange())
        try press(.down, in: window)
        try press(.return, in: window)
        await waitForEditor(controller, toShow: alpha)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)

        try press(.escape, in: window)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "")
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma, beta, alpha])
        XCTAssertTrue(
            searchFieldHasFocus(controller),
            "expected the search field's editor, got \(firstResponderDescription(window))")
        XCTAssertEqual(controller.editorController.noteID, alpha, "the editor keeps its note")
        XCTAssertEqual(controller.mainView.textView.string, "alpha body")
    }

    func testS7_escapeInTheSearchFieldClearsTheQueryAndKeepsFocus() async throws {
        let (controller, window) = try await makeController()
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        editor.insertText("gam", replacementRange: editor.selectedRange())
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma])

        try press(.escape, in: window)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "")
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma, beta, alpha])
        XCTAssertTrue(searchFieldHasFocus(controller))

        // Escape on an already empty field is harmless.
        try press(.escape, in: window)
        XCTAssertEqual(controller.query, "")
        XCTAssertTrue(searchFieldHasFocus(controller))
    }

    // MARK: S-7 Cmd-L focuses the search field from anywhere

    func testS7_commandLFocusesTheSearchFieldFromTheListAndTheEditor() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        let fieldEditor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        fieldEditor.insertText("a", replacementRange: fieldEditor.selectedRange())

        // From the list.
        try press(.down, in: window)
        XCTAssertIdentical(window.firstResponder, table)
        try press(.commandL, in: window)
        XCTAssertTrue(
            searchFieldHasFocus(controller),
            "expected the search field's editor, got \(firstResponderDescription(window))")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "a", "Cmd-L does not clear the query")
        XCTAssertEqual(controller.query, "a")
        let selected = try XCTUnwrap(controller.mainView.searchField.currentEditor()?.selectedRange)
        XCTAssertEqual(selected, NSRange(location: 0, length: 1), "the text is selected, ready to replace")

        // From the editor.
        try press(.down, in: window)
        try press(.tab, in: window)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        try press(.commandL, in: window)
        XCTAssertTrue(
            searchFieldHasFocus(controller),
            "expected the search field's editor, got \(firstResponderDescription(window))")

        // In the field itself it is a no-op that keeps focus.
        try press(.commandL, in: window)
        XCTAssertTrue(searchFieldHasFocus(controller))
        XCTAssertEqual(controller.mainView.searchField.stringValue, "a")
    }

    // MARK: S-8 Tab or Enter on a selected row moves focus to the editor

    func testS8_enterOnASelectedRowMovesFocusToTheEditor() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        try press(.down, in: window)
        XCTAssertIdentical(window.firstResponder, table)
        XCTAssertEqual(controller.listController.selectedID, gamma)

        try press(.return, in: window)
        XCTAssertIdentical(
            window.firstResponder, controller.mainView.textView,
            "expected the editor, got \(firstResponderDescription(window))")
        await waitForEditor(controller, toShow: gamma)
        XCTAssertEqual(controller.mainView.textView.string, "gamma body")
        XCTAssertEqual(table.selectedRow, 0, "the row stays selected")
    }

    func testS8_keypadEnterOnASelectedRowMovesFocusToTheEditor() async throws {
        let (controller, window) = try await makeController()
        try press(.down, in: window)
        try press(.keypadEnter, in: window)
        XCTAssertIdentical(
            window.firstResponder, controller.mainView.textView,
            "expected the editor, got \(firstResponderDescription(window))")
    }

    func testS8_tabOnASelectedRowMovesFocusToTheEditor() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        try press(.down, in: window)
        try press(.down, in: window)
        XCTAssertEqual(controller.listController.selectedID, beta)

        try press(.tab, in: window)
        XCTAssertIdentical(
            window.firstResponder, controller.mainView.textView,
            "expected the editor, got \(firstResponderDescription(window))")
        await waitForEditor(controller, toShow: beta)
        XCTAssertEqual(controller.mainView.textView.string, "beta body")
        XCTAssertEqual(table.selectedRow, 1)
    }

    func testS8_enterInTheListWithNoSelectionDoesNotFocusTheEditor() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertEqual(table.selectedRow, -1)

        try press(.return, in: window)
        XCTAssertNotIdentical(window.firstResponder, controller.mainView.textView)
        XCTAssertNil(controller.editorController.noteID)
    }

    func testS8_theWholeFlowRoundTrips() async throws {
        // Type, Down, Enter, edit position, Escape, and the field is focused and empty again.
        let (controller, window) = try await makeController()
        let fieldEditor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        fieldEditor.insertText("beta", replacementRange: fieldEditor.selectedRange())
        XCTAssertEqual(controller.listController.results.map(\.id), [beta])

        try press(.down, in: window)
        XCTAssertIdentical(window.firstResponder, controller.mainView.tableView)
        try press(.return, in: window)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)
        await waitForEditor(controller, toShow: beta)

        try press(.escape, in: window)
        XCTAssertTrue(searchFieldHasFocus(controller))
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma, beta, alpha])
        XCTAssertEqual(controller.listController.selectedID, beta)

        try press(.down, in: window)
        XCTAssertEqual(controller.listController.selectedID, gamma, "Down always takes the first row")
        XCTAssertIdentical(window.firstResponder, controller.mainView.tableView)
    }

    // MARK: S-12 Keyboard focus order

    func testS12_tabFromSearchFocusesListSelectsFirst() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        XCTAssertEqual(table.selectedRow, -1)

        try press(.tab, in: window)
        XCTAssertIdentical(
            window.firstResponder, table, "expected the list, got \(firstResponderDescription(window))")
        XCTAssertEqual(table.selectedRow, 0, "the first row is selected, as Down would (S-7)")
        XCTAssertEqual(controller.listController.selectedID, gamma)
        await waitForEditor(controller, toShow: gamma)
        XCTAssertIdentical(window.firstResponder, table, "loading the editor does not steal focus (S-8)")
    }

    func testS12_tabFromSearchKeepsExistingSelection() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        try press(.down, in: window)
        try press(.down, in: window)
        XCTAssertEqual(controller.listController.selectedID, beta)
        try press(.commandL, in: window)
        XCTAssertTrue(searchFieldHasFocus(controller))

        try press(.tab, in: window)
        XCTAssertIdentical(
            window.firstResponder, table, "expected the list, got \(firstResponderDescription(window))")
        XCTAssertEqual(table.selectedRow, 1, "the selected row is kept")
        XCTAssertEqual(controller.listController.selectedID, beta)
    }

    func testS12_tabFromSearchEmptyListStays() async throws {
        let (controller, window) = try await makeController()
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        editor.insertText("zqx", replacementRange: editor.selectedRange())
        XCTAssertEqual(controller.mainView.tableView.numberOfRows, 0)

        try press(.tab, in: window)
        XCTAssertTrue(
            searchFieldHasFocus(controller),
            "nothing listed, so focus stays put; got \(firstResponderDescription(window))")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "zqx", "no tab is typed into the query")
        XCTAssertEqual(controller.query, "zqx")
    }

    func testS12_tabInEditorInsertsTab() async throws {
        let (controller, window) = try await makeController()
        let textView = controller.mainView.textView
        try press(.down, in: window)
        await waitForEditor(controller, toShow: gamma)
        try press(.tab, in: window)
        XCTAssertIdentical(window.firstResponder, textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        try press(.tab, in: window)
        XCTAssertIdentical(
            window.firstResponder, textView, "focus stays in the editor, got \(firstResponderDescription(window))")
        XCTAssertEqual(textView.string, "\tgamma body", "a tab character is inserted at the caret")
    }

    func testS12_shiftTabEditorToList() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        try press(.down, in: window)
        try press(.down, in: window)
        try press(.tab, in: window)
        await waitForEditor(controller, toShow: beta)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)

        try press(.shiftTab, in: window)
        XCTAssertIdentical(
            window.firstResponder, table, "expected the list, got \(firstResponderDescription(window))")
        XCTAssertEqual(table.selectedRow, 1, "the selection is left alone")
        XCTAssertEqual(controller.mainView.textView.string, "beta body", "nothing is typed into the note")
    }

    func testS12_shiftTabListToSearch() async throws {
        let (controller, window) = try await makeController()
        let table = controller.mainView.tableView
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        editor.insertText("a", replacementRange: editor.selectedRange())
        try press(.down, in: window)
        try press(.down, in: window)
        XCTAssertIdentical(window.firstResponder, table)
        let selected = controller.listController.selectedID

        try press(.shiftTab, in: window)
        XCTAssertTrue(
            searchFieldHasFocus(controller),
            "expected the search field's editor, got \(firstResponderDescription(window))")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "a", "the query is kept")
        XCTAssertEqual(controller.query, "a")
        XCTAssertEqual(controller.listController.selectedID, selected, "the selection is left alone")

        // Shift-Tab in the search field does nothing.
        try press(.shiftTab, in: window)
        XCTAssertTrue(
            searchFieldHasFocus(controller),
            "Shift-Tab in the field keeps focus, got \(firstResponderDescription(window))")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "a")
        XCTAssertEqual(controller.listController.selectedID, selected)
    }

    func testS12_controlTabEditorToSearch() async throws {
        let (controller, window) = try await makeController()
        let fieldEditor = try XCTUnwrap(controller.mainView.searchField.currentEditor() as? NSTextView)
        fieldEditor.insertText("gam", replacementRange: fieldEditor.selectedRange())
        try press(.down, in: window)
        try press(.tab, in: window)
        await waitForEditor(controller, toShow: gamma)
        XCTAssertIdentical(window.firstResponder, controller.mainView.textView)

        try press(.controlTab, in: window)
        XCTAssertTrue(
            searchFieldHasFocus(controller),
            "expected the search field's editor, got \(firstResponderDescription(window))")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "gam", "the query is kept")
        XCTAssertEqual(controller.mainView.textView.string, "gamma body", "no tab is typed into the note")
    }
}
