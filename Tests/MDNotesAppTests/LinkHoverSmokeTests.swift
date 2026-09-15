import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the Cmd-hover over links (ED-12). The modifier change is a real
/// `flagsChanged` `NSEvent` sent through the window to the focused editor, carrying the pointer's
/// location as the running app's events do; mouse moves are real `mouseMoved` events handed to
/// the view as its tracking area would hand them. The cursor is read back from `NSCursor.current`
/// and the underline from the layout manager's temporary attributes, where the hover keeps it
/// so the storage, the undo stack and the file never see it.
@MainActor
final class LinkHoverSmokeTests: XCTestCase {
    private static let body = """
        # Links

        wiki [[Bar]] missing [[Not yet]] embed ![[pic.png]]
        std [standard link](https://example.com/a) auto <https://example.org/x> bare https://example.net/y end
        img ![alt](https://example.com/i.png) code `[[Bar]]` prose

        """

    @MainActor
    private struct Fixture {
        let controller: MainWindowController
        let window: NSWindow
        var textView: EditorTextView { controller.mainView.textView }
        var storage: NSTextStorage { textView.textStorage ?? NSTextStorage() }
        var layoutManager: EditorLayoutManager { textView.editorLayoutManager }

        /// The temporary underline at `location`, nil where there is none.
        func hoverUnderline(at location: Int) -> Int? {
            layoutManager.temporaryAttribute(.underlineStyle, atCharacterIndex: location, effectiveRange: nil) as? Int
        }

        /// The temporary underline of every character in `range`.
        func hoverUnderlines(in range: NSRange) -> [Int?] {
            (range.location..<(range.location + range.length)).map { hoverUnderline(at: $0) }
        }

        /// The storage's own underline at `location` (ED-11's dotted one, or nil).
        func storageUnderline(at location: Int) -> Int? {
            storage.attribute(.underlineStyle, at: location, effectiveRange: nil) as? Int
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        NSCursor.arrow.set()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
        NSCursor.arrow.set()
        try await super.tearDown()
    }

    /// A laid-out window showing `body` in a focused, editable editor, laid out whole so every
    /// character has a rect.
    private func makeFixture() throws -> Fixture {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        controller.mainView.layoutSubtreeIfNeeded()
        let window = try XCTUnwrap(controller.window)
        let textView = controller.mainView.textView
        textView.string = Self.body
        textView.isEditable = true
        XCTAssertTrue(window.makeFirstResponder(textView))
        if let container = textView.textContainer { textView.editorLayoutManager.ensureLayout(for: container) }
        return Fixture(controller: controller, window: window)
    }

    private func range(of needle: String, occurrence: Int = 0) -> NSRange {
        let text = Self.body as NSString
        var search = NSRange(location: 0, length: text.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = text.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let next = found.location + found.length
            search = NSRange(location: next, length: text.length - next)
        }
        XCTAssertNotEqual(found.location, NSNotFound, "\(needle) is in the fixture")
        return found
    }

    /// The window point at the centre of the character at `index`.
    private func point(overCharacterAt index: Int, in fixture: Fixture) throws -> NSPoint {
        let screenRect = fixture.textView.firstRect(
            forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, "the character has been laid out")
        let windowRect = fixture.window.convertFromScreen(screenRect)
        let point = NSPoint(x: windowRect.midX, y: windowRect.midY)
        XCTAssertIdentical(fixture.window.contentView?.hitTest(point), fixture.textView, "the point is over the editor")
        return point
    }

    /// A window point in the editor over no character: below the last line.
    private func pointOverNoCharacter(in fixture: Fixture) -> NSPoint {
        let bounds = fixture.textView.bounds
        let inView = NSPoint(x: bounds.midX, y: fixture.textView.isFlipped ? bounds.maxY - 4 : bounds.minY + 4)
        return fixture.textView.convert(inView, to: nil)
    }

    /// Command pressed (`down`) or released with the pointer at `point`: a `flagsChanged`
    /// dispatched by the window to its first responder, the editor.
    private func changeFlags(command down: Bool, at point: NSPoint, in fixture: Fixture) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged, location: point, modifierFlags: down ? .command : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        fixture.window.sendEvent(event)
    }

    /// The pointer moving to `point` with `flags` held, as the view's tracking area reports it.
    private func moveMouse(to point: NSPoint, flags: NSEvent.ModifierFlags, in fixture: Fixture) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        fixture.textView.mouseMoved(with: event)
    }

    private func exitMouse(flags: NSEvent.ModifierFlags, in fixture: Fixture) throws {
        let event = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseExited, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        fixture.textView.mouseExited(with: event)
    }

    private var solid: Int { NSUnderlineStyle.single.rawValue }

    // MARK: - ED-12 Cmd over a link: pointing hand and a solid underline; released: the I-beam

    func testED12_commandHeldOverALinkShowsThePointingHandAndASolidUnderline() throws {
        let fixture = try makeFixture()
        let link = range(of: "[[Bar]]")
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        XCTAssertEqual(fixture.hoverUnderlines(in: link), Array(repeating: nil, count: link.length))

        try changeFlags(command: true, at: try point(overCharacterAt: link.location + 3, in: fixture), in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, link)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
        XCTAssertEqual(
            fixture.hoverUnderlines(in: link), Array(repeating: solid, count: link.length),
            "solid over the whole link, brackets included")
        XCTAssertNil(fixture.hoverUnderline(at: link.location - 1), "the space before is not underlined")
        XCTAssertNil(fixture.hoverUnderline(at: link.location + link.length), "nor the one after")

        try changeFlags(command: false, at: try point(overCharacterAt: link.location + 3, in: fixture), in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "released Cmd restores the I-beam")
        XCTAssertEqual(fixture.hoverUnderlines(in: link), Array(repeating: nil, count: link.length))
    }

    func testED12_everyKindOfLinkHoversOverItsWholeRange() throws {
        let fixture = try makeFixture()
        let links: [(needle: String, offset: Int)] = [
            ("[[Not yet]]", 4), ("![[pic.png]]", 5), ("[standard link](https://example.com/a)", 3),
            ("[standard link](https://example.com/a)", 20), ("<https://example.org/x>", 8),
            ("https://example.net/y", 10),
        ]
        for (needle, offset) in links {
            let link = range(of: needle)
            try changeFlags(
                command: true, at: try point(overCharacterAt: link.location + offset, in: fixture), in: fixture)
            XCTAssertEqual(fixture.textView.hoveredLinkRange, link, needle)
            XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, needle)
            XCTAssertEqual(fixture.hoverUnderlines(in: link), Array(repeating: solid, count: link.length), needle)
            try changeFlags(
                command: false, at: try point(overCharacterAt: link.location + offset, in: fixture), in: fixture)
            XCTAssertNil(fixture.textView.hoveredLinkRange, needle)
            XCTAssertEqual(fixture.hoverUnderlines(in: link), Array(repeating: nil, count: link.length), needle)
        }
    }

    func testED12_whatIsNotALinkDoesNotHover() throws {
        let fixture = try makeFixture()
        let notLinks: [(needle: String, offset: Int, why: String)] = [
            ("![alt](https://example.com/i.png)", 12, "an image is not a link (ED-11)"),
            ("`[[Bar]]`", 4, "a wikilink in a code span is not a link (E-2)"),
            ("prose", 2, "prose"),
            ("# Links", 3, "a heading"),
        ]
        for (needle, offset, why) in notLinks {
            let index = range(of: needle).location + offset
            try changeFlags(command: true, at: try point(overCharacterAt: index, in: fixture), in: fixture)
            XCTAssertNil(fixture.textView.hoveredLinkRange, why)
            XCTAssertNotEqual(NSCursor.current, NSCursor.pointingHand, why)
            XCTAssertNil(fixture.hoverUnderline(at: index), why)
            try changeFlags(command: false, at: try point(overCharacterAt: index, in: fixture), in: fixture)
        }
        // Cmd over the editor but over no character at all.
        try changeFlags(command: true, at: pointOverNoCharacter(in: fixture), in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        try changeFlags(command: false, at: pointOverNoCharacter(in: fixture), in: fixture)
    }

    func testED12_commandWithAnotherModifierDoesNotHover() throws {
        let fixture = try makeFixture()
        let link = range(of: "[[Bar]]")
        let point = try point(overCharacterAt: link.location + 3, in: fixture)
        for flags in [NSEvent.ModifierFlags.shift, .option, .control, [.command, .shift], [.command, .option]] {
            try moveMouse(to: point, flags: flags, in: fixture)
            XCTAssertNil(fixture.textView.hoveredLinkRange, "\(flags)")
        }
        try moveMouse(to: point, flags: [.command, .numericPad, .function], in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, link, "the keypad and function flags do not count")
    }

    // MARK: - ED-12 the pointer moving with Cmd held

    func testED12_thePointerMovingOntoAndOffALinkWithCommandHeldFollows() throws {
        let fixture = try makeFixture()
        let bar = range(of: "[[Bar]]")
        let bare = range(of: "https://example.net/y")
        let prose = range(of: "prose").location + 2

        try moveMouse(to: try point(overCharacterAt: prose, in: fixture), flags: .command, in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        try moveMouse(to: try point(overCharacterAt: bar.location + 2, in: fixture), flags: .command, in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, bar)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
        try moveMouse(to: try point(overCharacterAt: bar.location + 5, in: fixture), flags: .command, in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, bar, "moving within the link keeps it")
        try moveMouse(to: try point(overCharacterAt: bare.location + 3, in: fixture), flags: .command, in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, bare, "moving onto another link moves the hover")
        XCTAssertEqual(fixture.hoverUnderlines(in: bar), Array(repeating: nil, count: bar.length))
        XCTAssertEqual(fixture.hoverUnderlines(in: bare), Array(repeating: solid, count: bare.length))
        try moveMouse(to: try point(overCharacterAt: prose, in: fixture), flags: .command, in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange, "moving off it with Cmd still held ends the hover")
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
        XCTAssertEqual(fixture.hoverUnderlines(in: bare), Array(repeating: nil, count: bare.length))

        try moveMouse(to: try point(overCharacterAt: bar.location + 2, in: fixture), flags: [], in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange, "over a link without Cmd nothing hovers")
    }

    func testED12_thePointerLeavingTheEditorEndsTheHover() throws {
        let fixture = try makeFixture()
        let link = range(of: "<https://example.org/x>")
        try moveMouse(to: try point(overCharacterAt: link.location + 3, in: fixture), flags: .command, in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, link)
        try exitMouse(flags: .command, in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
        XCTAssertEqual(fixture.hoverUnderlines(in: link), Array(repeating: nil, count: link.length))
    }

    func testED12_theCursorRectPassKeepsThePointingHandWhileALinkHovers() throws {
        let fixture = try makeFixture()
        let link = range(of: "[[Bar]]")
        let point = try point(overCharacterAt: link.location + 3, in: fixture)
        try changeFlags(command: true, at: point, in: fixture)
        NSCursor.arrow.set()
        let event = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .cursorUpdate, location: point, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        fixture.textView.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
    }

    // MARK: - ED-12 the underline is display only

    func testED12_theHoverUnderlineIsNeverInTheStorageNorAnEdit() throws {
        let fixture = try makeFixture()
        let missing = range(of: "[[Not yet]]")
        let target = range(of: "Not yet")
        let editor = fixture.controller.editorController
        XCTAssertEqual(
            fixture.storageUnderline(at: target.location), EditorStyler.missingLinkUnderline.rawValue,
            "ED-11's dotted underline is in the storage")
        XCTAssertNil(fixture.storageUnderline(at: missing.location))
        let before = fixture.storage.copy() as? NSAttributedString

        try changeFlags(command: true, at: try point(overCharacterAt: missing.location + 4, in: fixture), in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, missing)
        XCTAssertEqual(fixture.hoverUnderlines(in: missing), Array(repeating: solid, count: missing.length))
        XCTAssertEqual(
            fixture.storageUnderline(at: target.location), EditorStyler.missingLinkUnderline.rawValue,
            "the storage keeps the dotted underline under the target")
        XCTAssertNil(fixture.storageUnderline(at: missing.location), "and none on the brackets")
        XCTAssertEqual(fixture.storage, before, "no storage attribute changed")
        XCTAssertEqual(editor.text, Self.body)
        XCTAssertFalse(editor.hasUnsavedEdits, "a hover is not an edit (E-4)")
        XCTAssertEqual(fixture.textView.undoManager?.canUndo, false, "nor undoable (E-7)")

        try changeFlags(command: false, at: try point(overCharacterAt: missing.location + 4, in: fixture), in: fixture)
        XCTAssertEqual(fixture.storage, before)
        XCTAssertEqual(
            fixture.storageUnderline(at: target.location), EditorStyler.missingLinkUnderline.rawValue,
            "the dotted underline is still there once the hover ends")
        XCTAssertNil(fixture.hoverUnderline(at: target.location))
    }

    func testED12_aHoverSurvivesTextChangingUnderItWithoutLeavingAStrayUnderline() throws {
        let fixture = try makeFixture()
        let link = range(of: "https://example.net/y")
        try changeFlags(command: true, at: try point(overCharacterAt: link.location + 3, in: fixture), in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, link)
        // The text shrinks below the hovered range while Cmd is held.
        fixture.textView.string = "short"
        try changeFlags(command: false, at: pointOverNoCharacter(in: fixture), in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        XCTAssertEqual(fixture.hoverUnderlines(in: NSRange(location: 0, length: 5)), Array(repeating: nil, count: 5))
    }

    // MARK: - V-1

    func testV1_editorSnapshotShowsACommandHoveredLink() throws {
        let fixture = try makeFixture()
        let link = range(of: "[standard link](https://example.com/a)")
        try changeFlags(command: true, at: try point(overCharacterAt: link.location + 3, in: fixture), in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, link)
        let written = try writeWindowSnapshots(of: fixture.controller, named: "editor-link-hover")
        XCTAssertEqual(written.count, 2)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
        try changeFlags(command: false, at: try point(overCharacterAt: link.location + 3, in: fixture), in: fixture)
    }
}
