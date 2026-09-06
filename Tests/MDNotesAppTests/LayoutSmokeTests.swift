import AppKit
import MDNotesApp
import XCTest

/// Headless layout smoke tests for W-1 and W-2: the views exist, are stacked in the specified
/// order at a given window size, and the frame and split position persist.
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
        XCTAssertEqual(view.splitView.arrangedSubviews, [view.listScrollView, view.editorScrollView])
        XCTAssertFalse(view.splitView.isVertical, "list above editor: the divider runs horizontally")
        XCTAssertIdentical(view.listScrollView.documentView, view.tableView)
        XCTAssertIdentical(view.editorScrollView.documentView, view.textView)

        // Search field across the top, full width.
        let search = view.searchField.frame
        XCTAssertEqual(search.maxY, size.height, accuracy: 0.5)
        XCTAssertEqual(search.minX, 0, accuracy: 0.5)
        XCTAssertEqual(search.width, size.width, accuracy: 0.5)
        XCTAssertGreaterThan(search.height, 0)

        // Split view directly below it, full width, reaching the bottom (strip hidden, K-6).
        let split = view.splitView.frame
        XCTAssertEqual(split.maxY, search.minY, accuracy: 0.5)
        XCTAssertEqual(split.width, size.width, accuracy: 0.5)
        XCTAssertTrue(view.backlinksStrip.isHidden)
        XCTAssertEqual(split.minY, 0, accuracy: 0.5)

        // Inside the split: list on top, editor below, both non-empty, meeting at the divider.
        let list = view.listScrollView.frame
        let editor = view.editorScrollView.frame
        XCTAssertEqual(list.minY, 0, accuracy: 0.5)
        XCTAssertEqual(list.height, MainView.defaultListHeight, accuracy: 0.5)
        XCTAssertGreaterThan(editor.height, 0)
        XCTAssertEqual(editor.minY - list.maxY, view.splitView.dividerThickness, accuracy: 0.5)
        XCTAssertEqual(editor.maxY, split.height, accuracy: 0.5)
        XCTAssertEqual(list.width, size.width, accuracy: 0.5)
        XCTAssertEqual(editor.width, size.width, accuracy: 0.5)
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
        XCTAssertEqual(view.splitView.frame.maxY, view.searchField.frame.minY, accuracy: 0.5)
    }

    func testW2_listKeepsItsHeightWhenTheWindowGrows() {
        let controller = makeLaidOutController(size: NSSize(width: 800, height: 600))
        let view = controller.mainView
        let listHeightBefore = view.listScrollView.frame.height
        controller.window?.setContentSize(NSSize(width: 800, height: 800))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.listScrollView.frame.height, listHeightBefore, accuracy: 0.5)
        XCTAssertEqual(view.editorScrollView.frame.maxY, view.splitView.frame.height, accuracy: 0.5)
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
