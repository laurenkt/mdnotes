import AppKit

/// The single main window. Search field, note list and editor will live here.
@MainActor
public final class MainWindowController: NSWindowController {
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MDNotes"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
