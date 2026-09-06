import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public private(set) var mainWindowController: MainWindowController?
    public private(set) var libraryController: LibraryController?

    /// How `applicationShouldTerminate` tells AppKit the last write has landed. Tests, which
    /// must not actually terminate, replace it to observe the reply.
    public var replyToTerminate: @MainActor (NSApplication, Bool) -> Void = {
        $0.reply(toApplicationShouldTerminate: $1)
    }

    /// The folder `applicationDidFinishLaunching` opens as the library (L-1).
    public let libraryRoot: URL

    public override init() {
        libraryRoot = LibraryController.defaultRoot
        super.init()
    }

    /// Uses `mainWindowController` instead of building one at launch, and opens `libraryRoot`
    /// instead of the default library. For tests.
    public init(mainWindowController: MainWindowController, libraryRoot: URL = LibraryController.defaultRoot) {
        self.mainWindowController = mainWindowController
        self.libraryRoot = libraryRoot
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The window comes first and the index fills in behind it (PF-1, PF-7).
        let controller = mainWindowController ?? MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller

        let library = LibraryController(root: libraryRoot)
        controller.attach(library)
        library.start()
        libraryController = library
    }

    /// E-4: unsaved edits are written before the app quits. The write runs off the main thread
    /// (PF-6), so termination is deferred until it lands, then resumed through
    /// `replyToTerminate`. With nothing to write the app quits at once.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor = mainWindowController?.editorController, editor.hasUnsavedEdits else {
            return .terminateNow
        }
        let reply = replyToTerminate
        editor.flush { reply(sender, true) }
        return .terminateLater
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
