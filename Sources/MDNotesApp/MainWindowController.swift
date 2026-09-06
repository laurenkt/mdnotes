import AppKit

/// The single main window (W-1). Its content is a `MainView` laid out per W-2.
@MainActor
public final class MainWindowController: NSWindowController {
    /// Autosave name under which `NSWindow` persists the frame.
    nonisolated public static let frameAutosaveName = "MainWindow"

    public let mainView: MainView

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MDNotes"
        window.minSize = NSSize(width: 400, height: 300)
        // W-4: closing quits, so nothing ever needs the window released on close.
        window.isReleasedWhenClosed = false
        window.center()
        let view = MainView(frame: window.contentLayoutRect)
        window.contentView = view
        window.initialFirstResponder = view.searchField
        mainView = view
        super.init(window: window)
        // W-1: one window, one persisted frame. Cascading would discard the autosave name, and
        // the name must be set after the content view exists so a restored frame lays it out.
        shouldCascadeWindows = false
        windowFrameAutosaveName = Self.frameAutosaveName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
