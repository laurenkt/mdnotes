import AppKit
import MDNotesApp
import XCTest

/// Main-actor box so a controller can ride inside a `@Sendable` teardown block.
@MainActor
private final class ControllerBox {
    let controller: MainWindowController
    init(_ controller: MainWindowController) { self.controller = controller }
}

extension XCTestCase {
    /// Creates a `MainWindowController` and releases its frame autosave name at teardown.
    ///
    /// AppKit lets one live window own a frame autosave name at a time and does not release it
    /// when the window is deallocated. The app has exactly one window (W-1), but a test process
    /// creates many, so every test must build its controller through this helper.
    @MainActor
    func makeMainWindowController(autosaveClock: any AutosaveClock = SystemAutosaveClock()) -> MainWindowController {
        let box = ControllerBox(MainWindowController(autosaveClock: autosaveClock))
        addTeardownBlock {
            await MainActor.run { _ = box.controller.window?.setFrameAutosaveName("") }
        }
        return box.controller
    }
}

extension MainView {
    /// The W-6 hairline's layout rectangle. A separator box's frame carries a 2 pt alignment
    /// inset on every side; this is the one-point-tall rectangle the stack lays out.
    var searchSeparatorRect: NSRect {
        searchSeparator.alignmentRect(forFrame: searchSeparator.frame)
    }
}
