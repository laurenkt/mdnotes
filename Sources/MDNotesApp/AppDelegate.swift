import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public private(set) var mainWindowController: MainWindowController?
    public private(set) var libraryController: LibraryController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The window comes first and the index fills in behind it (PF-1, PF-7).
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller

        let library = LibraryController(root: LibraryController.defaultRoot)
        controller.attach(library)
        library.start()
        libraryController = library
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
