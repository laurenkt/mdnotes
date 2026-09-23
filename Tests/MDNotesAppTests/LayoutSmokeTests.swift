import AppKit
import MDNotesApp
import XCTest

/// Headless layout smoke tests for W-1, W-2 and W-6: the views exist, are stacked in the
/// specified order at a given window size with the W-6 insets, and the frame and split
/// position persist.
@MainActor
final class LayoutSmokeTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        resetPersistedState()
    }

    override func tearDown() async throws {
        resetPersistedState()
        try await super.tearDown()
    }

    private func resetPersistedState() {
        UserDefaults.standard.removeObject(forKey: MainView.listHeightDefaultsKey)
    }

    private func makeLaidOutController(size: NSSize) -> MainWindowController {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(size)
        controller.mainView.layoutSubtreeIfNeeded()
        return controller
    }

    // Stack coordinates are AppKit's (origin bottom-left); NSSplitView's are flipped (top-down).

    func testW2_viewsExistAndAreLaidOutAtAGivenSize() {
        let size = NSSize(width: 800, height: 600)
        let controller = makeLaidOutController(size: size)
        let view = controller.mainView
        XCTAssertEqual(view.frame.size, size)

        // Hierarchy: everything is a descendant of the content view, in the right containers.
        XCTAssertTrue(view.searchField.isDescendant(of: view))
        XCTAssertTrue(view.splitView.isDescendant(of: view))
        XCTAssertTrue(view.backlinksStrip.isDescendant(of: view))
        XCTAssertEqual(view.splitView.arrangedSubviews, [view.listScrollView, view.editorPane])
        XCTAssertEqual(view.editorPane.arrangedSubviews, [view.readOnlyNotice, view.editorScrollView])
        XCTAssertFalse(view.splitView.isVertical, "list above editor: the divider runs horizontally")
        XCTAssertIdentical(view.listScrollView.documentView, view.tableView)
        XCTAssertIdentical(view.editorScrollView.documentView, view.textView)

        // Search strip across the top, full width, the field inside it (W-6).
        let strip = view.searchStrip.frame
        XCTAssertEqual(strip.maxY, size.height, accuracy: 0.5)
        XCTAssertEqual(strip.minX, 0, accuracy: 0.5)
        XCTAssertEqual(strip.width, size.width, accuracy: 0.5)
        XCTAssertGreaterThan(view.searchField.frame.height, 0)
        XCTAssertTrue(view.searchField.isDescendant(of: view.searchStrip))

        // The hairline directly under the strip, then the split view, full width, reaching the
        // bottom (backlinks strip hidden, K-6).
        let separator = view.searchSeparatorRect
        XCTAssertEqual(separator.maxY, strip.minY, accuracy: 0.5)
        let split = view.splitView.frame
        XCTAssertEqual(split.maxY, separator.minY, accuracy: 0.5)
        XCTAssertEqual(split.width, size.width, accuracy: 0.5)
        XCTAssertTrue(view.backlinksStrip.isHidden)
        XCTAssertEqual(split.minY, 0, accuracy: 0.5)

        // Inside the split: list on top, editor pane below, both non-empty, meeting at the
        // divider. The notice bar is hidden (L-8), so the editor fills its pane.
        let list = view.listScrollView.frame
        let pane = view.editorPane.frame
        let editor = view.editorScrollView.frame
        XCTAssertEqual(list.minY, 0, accuracy: 0.5)
        XCTAssertEqual(list.height, MainView.defaultListHeight, accuracy: 0.5)
        XCTAssertGreaterThan(pane.height, 0)
        XCTAssertEqual(pane.minY - list.maxY, view.splitView.dividerThickness, accuracy: 0.5)
        XCTAssertEqual(pane.maxY, split.height, accuracy: 0.5)
        XCTAssertEqual(list.width, size.width, accuracy: 0.5)
        XCTAssertEqual(pane.width, size.width, accuracy: 0.5)
        XCTAssertTrue(view.readOnlyNotice.isHidden)
        XCTAssertEqual(editor.size, pane.size)
    }

    func testW2_backlinksStripSitsBelowTheEditorWhenShown() {
        let size = NSSize(width: 800, height: 600)
        let controller = makeLaidOutController(size: size)
        let view = controller.mainView
        view.backlinksStrip.isHidden = false
        view.layoutSubtreeIfNeeded()

        let strip = view.backlinksStrip.frame
        XCTAssertEqual(strip.height, MainView.backlinksStripHeight, accuracy: 0.5)
        XCTAssertEqual(strip.minY, 0, accuracy: 0.5)
        XCTAssertEqual(strip.width, size.width, accuracy: 0.5)
        XCTAssertEqual(view.splitView.frame.minY, strip.maxY, accuracy: 0.5)
        XCTAssertEqual(view.splitView.frame.maxY, view.searchSeparatorRect.minY, accuracy: 0.5)
    }

    /// The editor's text view sits at its clip view's origin whatever size the window takes,
    /// so scrolling to either end of a long note stops at the text view's own edge, past the
    /// bottom by no more than the inset AppKit gives the clip view at the window's bottom
    /// corner (I-14).
    func testW2_editorTextViewSitsAtTheClipViewOrigin() throws {
        let controller = makeLaidOutController(size: NSSize(width: 800, height: 600))
        let view = controller.mainView
        let text = view.textView
        let clip = view.editorScrollView.contentView
        XCTAssertEqual(text.frame.origin, .zero, "after the window takes its size")

        text.string = (1...80).map { "Line \($0)" }.joined(separator: "\n\n") + "\n"
        view.layoutSubtreeIfNeeded()
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        XCTAssertEqual(text.frame.origin, .zero, "with a long note shown")
        XCTAssertGreaterThan(text.frame.height, clip.bounds.height, "the note is taller than the editor")

        text.scrollToEndOfDocument(nil)
        XCTAssertEqual(
            clip.bounds.maxY, text.frame.maxY + clip.contentInsets.bottom, accuracy: 0.5,
            "scrolled to the end, not past it")
        text.scrollToBeginningOfDocument(nil)
        XCTAssertEqual(clip.bounds.minY, text.frame.minY, accuracy: 0.5, "scrolled to the top, not past it")

        controller.window?.setContentSize(NSSize(width: 700, height: 500))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(text.frame.origin, .zero, "after the window shrinks")
        text.scrollToEndOfDocument(nil)
        XCTAssertEqual(
            clip.bounds.maxY, text.frame.maxY + clip.contentInsets.bottom, accuracy: 0.5,
            "scrolled to the end after a resize")
    }

    func testW6_titleBarShowsTheWindowTitle() throws {
        let controller = makeLaidOutController(size: NSSize(width: 800, height: 600))
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.title, "MDNotes")
        XCTAssertNil(window.toolbar, "the search field lives in the content area, not a toolbar")
    }

    func testW6_searchFieldIsInsetOnAStripAboveAHairline() {
        let size = NSSize(width: 800, height: 600)
        let controller = makeLaidOutController(size: size)
        let view = controller.mainView
        let strip = view.searchStrip.frame
        let field = view.searchField.frame  // in the strip's coordinates

        // 8 pt above and below, 10 pt either side (W-6).
        XCTAssertEqual(field.minX, MainView.searchFieldHorizontalInset, accuracy: 0.5)
        XCTAssertEqual(strip.width - field.maxX, MainView.searchFieldHorizontalInset, accuracy: 0.5)
        XCTAssertEqual(field.minY, MainView.searchFieldVerticalInset, accuracy: 0.5)
        XCTAssertEqual(strip.height - field.maxY, MainView.searchFieldVerticalInset, accuracy: 0.5)
        XCTAssertEqual(strip.height, field.height + 2 * MainView.searchFieldVerticalInset, accuracy: 0.5)
        XCTAssertEqual(MainView.searchFieldVerticalInset, 8)
        XCTAssertEqual(MainView.searchFieldHorizontalInset, 10)

        // A standard search field with its default bezel, on a strip that paints nothing of
        // its own so the window background shows through; no custom drawing (W-6).
        XCTAssertTrue(view.searchField.isBezeled)
        XCTAssertEqual(view.searchField.bezelStyle, .roundedBezel)
        XCTAssertFalse(view.searchStrip.wantsLayer)
        XCTAssertTrue(type(of: view.searchStrip) == NSView.self, "a plain view, nothing custom")
        XCTAssertEqual(view.window?.backgroundColor, .windowBackgroundColor)

        // The hairline: the standard separator box, one point tall, edge to edge.
        let separator = view.searchSeparatorRect
        XCTAssertEqual(view.searchSeparator.boxType, .separator)
        XCTAssertEqual(separator.height, MainView.searchSeparatorHeight, accuracy: 0.5)
        XCTAssertEqual(separator.minX, 0, accuracy: 0.5)
        XCTAssertEqual(separator.width, size.width, accuracy: 0.5)
        XCTAssertEqual(separator.maxY, strip.minY, accuracy: 0.5)
        XCTAssertEqual(view.splitView.frame.maxY, separator.minY, accuracy: 0.5)
    }

    func testW2_listKeepsItsHeightWhenTheWindowGrows() {
        let controller = makeLaidOutController(size: NSSize(width: 800, height: 600))
        let view = controller.mainView
        let listHeightBefore = view.listScrollView.frame.height
        controller.window?.setContentSize(NSSize(width: 800, height: 800))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.listScrollView.frame.height, listHeightBefore, accuracy: 0.5)
        XCTAssertEqual(view.editorPane.frame.maxY, view.splitView.frame.height, accuracy: 0.5)
    }

    func testW1_windowFrameHasAutosaveName() {
        let controller = makeLaidOutController(size: NSSize(width: 800, height: 600))
        XCTAssertEqual(controller.window?.frameAutosaveName, MainWindowController.frameAutosaveName)
    }

    func testW1_windowFramePersistsAcrossControllers() {
        let first = makeMainWindowController()
        guard let firstWindow = first.window else { return XCTFail("no window") }
        let target = NSRect(x: 120, y: 140, width: 720, height: 540)
        firstWindow.setFrame(target, display: false)
        firstWindow.saveFrame(usingName: MainWindowController.frameAutosaveName)
        firstWindow.setFrameAutosaveName("")

        let second = makeMainWindowController()
        XCTAssertEqual(second.window?.frame.size, target.size)
    }

    func testW1_splitPositionPersistsAcrossControllers() {
        let size = NSSize(width: 800, height: 600)
        let first = makeLaidOutController(size: size)
        let target: CGFloat = 333
        first.mainView.splitView.setPosition(target, ofDividerAt: 0)
        first.mainView.layoutSubtreeIfNeeded()
        XCTAssertEqual(first.mainView.listScrollView.frame.height, target, accuracy: 0.5)
        XCTAssertEqual(first.mainView.persistedListHeight ?? -1, target, accuracy: 0.5)
        first.window?.setFrameAutosaveName("")

        let second = makeLaidOutController(size: size)
        XCTAssertEqual(second.mainView.listScrollView.frame.height, target, accuracy: 0.5)
    }

    func testW1_unusablePersistedSplitFallsBackToDefault() {
        UserDefaults.standard.set(-5.0, forKey: MainView.listHeightDefaultsKey)
        let controller = makeLaidOutController(size: NSSize(width: 800, height: 600))
        XCTAssertEqual(
            controller.mainView.listScrollView.frame.height, MainView.defaultListHeight, accuracy: 0.5)
        // The unusable value is replaced by the position actually shown.
        XCTAssertEqual(controller.mainView.persistedListHeight ?? -1, MainView.defaultListHeight, accuracy: 0.5)
    }
}
