import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the Cmd-hover over links (ED-12). The modifier change is a real
/// `flagsChanged` `NSEvent` sent through the window to the focused editor, with the pointer's
/// location given to the view through `pointerLocationInWindow` (the running app's modifier
/// events do not carry it); mouse moves are real `mouseMoved` events handed to the view as its
/// tracking area would hand them, and in `testED12_handSurvivesTextViewCursorHandling` sent
/// through an on-screen window so `NSTextView`'s own cursor handling runs as it does in the app. The cursor is read back from `NSCursor.current`
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
    /// dispatched by the window to its first responder, the editor. The view asks where the
    /// pointer is rather than trusting the event, so the test tells it; the event carries
    /// `eventLocation`, the point itself unless a test says otherwise.
    private func changeFlags(
        command down: Bool, at point: NSPoint, eventLocation: NSPoint? = nil, in fixture: Fixture
    ) throws {
        fixture.textView.pointerLocationInWindow = { point }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged, location: eventLocation ?? point, modifierFlags: down ? .command : [],
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

    /// ADR-0021: an image `![alt](url)` is a link for Cmd, hovered over its whole range, the
    /// `!` and the URL included, as a standard link is.
    func testED12_imageLinkHover() throws {
        let fixture = try makeFixture()
        let image = range(of: "![alt](https://example.com/i.png)")
        for offset in [0, 3, 12, image.length - 1] {
            let index = image.location + offset
            try changeFlags(command: true, at: try point(overCharacterAt: index, in: fixture), in: fixture)
            XCTAssertEqual(fixture.textView.hoveredLinkRange, image, "offset \(offset)")
            XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "offset \(offset)")
            XCTAssertEqual(
                fixture.hoverUnderlines(in: image), Array(repeating: solid, count: image.length), "offset \(offset)")
            XCTAssertNil(fixture.hoverUnderline(at: image.location - 1), "the space before is not underlined")
            XCTAssertNil(fixture.hoverUnderline(at: image.location + image.length), "nor the one after")
            try changeFlags(command: false, at: try point(overCharacterAt: index, in: fixture), in: fixture)
            XCTAssertNil(fixture.textView.hoveredLinkRange)
            XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "released Cmd restores the I-beam")
            XCTAssertEqual(fixture.hoverUnderlines(in: image), Array(repeating: nil, count: image.length))
        }
        let after = image.location + image.length
        try moveMouse(to: try point(overCharacterAt: after, in: fixture), flags: .command, in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange, "the character after the image is not the image")
        try moveMouse(to: try point(overCharacterAt: image.location + 5, in: fixture), flags: [], in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange, "over an image without Cmd nothing hovers")
    }

    func testED12_whatIsNotALinkDoesNotHover() throws {
        let fixture = try makeFixture()
        let notLinks: [(needle: String, offset: Int, why: String)] = [
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

    /// I-12: `flagsChanged` goes to the first responder alone, so with the search field or the
    /// list focused the window itself hands the modifier change to the editor's hover.
    func testED12_commandHoversALinkWhateverHasFocus() throws {
        let fixture = try makeFixture()
        let link = range(of: "[[Bar]]")
        let over = try point(overCharacterAt: link.location + 3, in: fixture)
        let focused: [(String, NSView)] = [
            ("search field", fixture.controller.mainView.searchField),
            ("list", fixture.controller.mainView.tableView),
        ]
        for (name, view) in focused {
            XCTAssertTrue(fixture.window.makeFirstResponder(view), "\(name) takes focus")
            XCTAssertFalse(fixture.window.firstResponder === fixture.textView, "\(name) has focus, not the editor")

            try changeFlags(command: true, at: over, in: fixture)
            XCTAssertEqual(fixture.textView.hoveredLinkRange, link, "Cmd with the \(name) focused")
            XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "the hand with the \(name) focused")
            XCTAssertEqual(fixture.hoverUnderlines(in: link), Array(repeating: solid, count: link.length))

            try changeFlags(command: false, at: over, in: fixture)
            XCTAssertNil(fixture.textView.hoveredLinkRange, "released with the \(name) focused")
            XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
            XCTAssertEqual(fixture.hoverUnderlines(in: link), Array(repeating: nil, count: link.length))
        }
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

    /// ED-12's last sentence: the cursor the user sees. The window is put on screen, frontmost
    /// at the pointer, so `NSTextView`'s own `mouseMoved` does what it does in the running app
    /// (sets the I-beam on every move over its text), and every event goes through
    /// `window.sendEvent`: a mouse move, a cursor update, a modifier change and a second move
    /// within the same link, the pointing hand read back from `NSCursor.current` after each.
    func testED12_handSurvivesTextViewCursorHandling() throws {
        let fixture = try makeFixture()
        try putOnScreen(fixture)
        defer { fixture.window.orderOut(nil) }
        let link = range(of: "[standard link](https://example.com/a)")
        let first = try point(overCharacterAt: link.location + 3, in: fixture)
        let second = try point(overCharacterAt: link.location + 20, in: fixture)
        let prose = try point(overCharacterAt: range(of: "prose").location + 2, in: fixture)

        NSCursor.arrow.set()
        try sendMouseMoved(to: prose, flags: [], in: fixture)
        XCTAssertEqual(
            NSCursor.current, NSCursor.iBeam, "the text view's own cursor handling runs: a plain move sets the I-beam")

        try sendMouseMoved(to: first, flags: .command, in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, link, "a move with Cmd held hovers the link")
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "after the mouse moved")

        try sendCursorUpdate(at: first, in: fixture)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "after a cursor update")

        // The running app's modifier change carries the window's top-left corner, not the pointer.
        let corner = NSPoint(x: 0, y: fixture.window.contentLayoutRect.maxY)
        try changeFlags(command: false, at: first, eventLocation: corner, in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        try changeFlags(command: true, at: first, eventLocation: corner, in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, link, "Cmd pressed with the pointer resting on the link")
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "after the flags changed")

        try sendMouseMoved(to: second, flags: .command, in: fixture)
        XCTAssertEqual(fixture.textView.hoveredLinkRange, link, "a second move within the same link keeps it")
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "after a second move within the link")
        try sendMouseMoved(to: second, flags: .command, in: fixture)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "after a move to the same point")

        try sendMouseMoved(to: prose, flags: .command, in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "off the link the I-beam is back")

        try sendMouseMoved(to: second, flags: .command, in: fixture)
        XCTAssertEqual(NSCursor.current, NSCursor.pointingHand, "back onto the link")
        try changeFlags(command: false, at: second, in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "released Cmd restores the I-beam")
        try sendMouseMoved(to: first, flags: [], in: fixture)
        XCTAssertNil(fixture.textView.hoveredLinkRange)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "a move without Cmd keeps the I-beam")
    }

    /// Orders the window front above every other app's windows and waits until the window
    /// server reports it as the window under the editor, which `NSTextView`'s `mouseMoved`
    /// checks before it touches the cursor.
    /// The test process is never the active app, so the tracking areas (active in the key
    /// window or the active app) hand the window's mouse moves to nobody; the window is told to
    /// accept them instead, which hands each to its first responder, the text view, as the
    /// tracking areas do in the running app.
    private func putOnScreen(_ fixture: Fixture) throws {
        fixture.window.acceptsMouseMovedEvents = true
        fixture.window.level = .popUpMenu
        fixture.window.orderFrontRegardless()
        let probe = fixture.window.convertPoint(toScreen: pointOverNoCharacter(in: fixture))
        let deadline = Date().addingTimeInterval(5)
        while NSWindow.windowNumber(at: probe, belowWindowWithWindowNumber: 0) != fixture.window.windowNumber,
            Date() < deadline
        {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(
            NSWindow.windowNumber(at: probe, belowWindowWithWindowNumber: 0), fixture.window.windowNumber,
            "the window is frontmost under the editor")
    }

    /// A `mouseMoved` to `point` with `flags` held, dispatched by the window to the tracking
    /// areas under it (the text view's own and the hover's) and its first responder.
    private func sendMouseMoved(to point: NSPoint, flags: NSEvent.ModifierFlags, in fixture: Fixture) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        fixture.window.sendEvent(event)
    }

    /// A `cursorUpdate` at `point` with Command held, sent through the window. A synthesized
    /// cursor update carries no tracking area, so the window routes it nowhere; it is then
    /// handed to the owner of the text view's own cursor-update tracking area, as the window
    /// hands a real one.
    private func sendCursorUpdate(at point: NSPoint, in fixture: Fixture) throws {
        let event = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .cursorUpdate, location: point, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        fixture.window.sendEvent(event)
        let area = try XCTUnwrap(
            fixture.textView.trackingAreas.first { $0.options.contains(.cursorUpdate) },
            "the text view tracks cursor updates itself")
        let owner = try XCTUnwrap(area.owner as? NSResponder)
        owner.cursorUpdate(with: event)
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
