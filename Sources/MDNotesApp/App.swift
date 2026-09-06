import AppKit

/// Entry point used by `main.swift`. Kept in the library so tests can import everything else.
public enum App {
    @MainActor
    public static func run() -> Never {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate()
        app.run()
        exit(0)
    }
}
