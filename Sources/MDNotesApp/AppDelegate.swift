import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public private(set) var mainWindowController: MainWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
