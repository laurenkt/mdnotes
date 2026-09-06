import AppKit
import MDNotesApp
import XCTest

/// Headless app smoke tests: exercise real controllers without a running app or UI clicks.
@MainActor
final class AppSmokeTests: XCTestCase {
    func testMainWindowControllerCreatesWindow() {
        let controller = makeMainWindowController()
        XCTAssertNotNil(controller.window)
        XCTAssertEqual(controller.window?.title, "MDNotes")
    }
}
