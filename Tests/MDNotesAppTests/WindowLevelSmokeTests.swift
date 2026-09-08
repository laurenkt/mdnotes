import AppKit
import MDNotesApp
import XCTest

/// Headless smoke tests for W-5 (ADR-0011): the main window floats and follows the active
/// Space, and what must appear above it, the completion panel and Settings, is at a higher
/// level. Level and collection behaviour are asserted directly: a test process cannot see
/// window stacking.
@MainActor
final class WindowLevelSmokeTests: XCTestCase {
    func testW5_mainWindowIsFloatingAndMovesToTheActiveSpace() throws {
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(MainWindowController.windowLevel, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces), "follows the user, not on every Space")
    }

    func testW5_completionPanelLevelIsAboveTheMainWindow() throws {
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        let editor = controller.editorController
        XCTAssertGreaterThan(editor.linkCompletion.panelLevel.rawValue, window.level.rawValue)
        XCTAssertGreaterThan(editor.tagCompletion.panelLevel.rawValue, window.level.rawValue)
        XCTAssertEqual(editor.linkCompletion.panelLevel, MainWindowController.overlayLevel)
    }

    func testW5_settingsWindowLevelIsAboveTheMainWindow() throws {
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        let preferences = PreferencesWindowController(libraryRoot: FileManager.default.temporaryDirectory)
        let settings = try XCTUnwrap(preferences.window)
        XCTAssertGreaterThan(settings.level.rawValue, window.level.rawValue)
        XCTAssertEqual(settings.level, MainWindowController.overlayLevel)
    }
}
