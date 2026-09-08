import AppKit
import MDNotesApp
import XCTest

extension XCTestCase {
    /// Renders the main window's content view at 2x in light and dark appearance to
    /// `build/snapshots/<name>-<appearance>.png` (V-1) and returns the files written. The
    /// implementing agent opens these and compares them with the spec and the design canvas
    /// (ADR-0013, ADR-0015); they are build products and never committed.
    @MainActor
    func writeWindowSnapshots(of controller: MainWindowController, named name: String) throws -> [URL] {
        guard let window = controller.window else { throw CocoaError(.fileNoSuchFile) }
        return try writeWindowSnapshots(ofWindow: window, named: name)
    }

    /// The same for any window, such as Settings (PR-1).
    @MainActor
    func writeWindowSnapshots(ofWindow window: NSWindow, named name: String) throws -> [URL] {
        guard let view = window.contentView else { throw CocoaError(.fileNoSuchFile) }
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bounds = view.bounds
            let rep = try Self.cachingRep(for: view, in: bounds, scale: 2)
            Self.fillWindowBackground(of: window, into: rep, in: bounds)
            view.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = directory.appendingPathComponent("\(name)-\(suffix).png")
            try png.write(to: url)
            written.append(url)
        }
        window.appearance = nil
        return written
    }

    /// A content view that paints no background (Settings, PR-1) caches as transparent pixels,
    /// so the window's own background is painted behind it first, resolved in the appearance
    /// the window is currently rendering (I-7).
    @MainActor
    private static func fillWindowBackground(of window: NSWindow, into rep: NSBitmapImageRep, in bounds: NSRect) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            (window.backgroundColor ?? NSColor.windowBackgroundColor).setFill()
            bounds.fill()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `bitmapImageRepForCachingDisplay` sized by the window's backing scale, which is what V-1
    /// names; a headless window may report 1x, so a rep at `scale` is built by hand then.
    @MainActor
    private static func cachingRep(for view: NSView, in bounds: NSRect, scale: Int) throws -> NSBitmapImageRep {
        let wide = Int(bounds.width) * scale
        let high = Int(bounds.height) * scale
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds), rep.pixelsWide == wide, rep.pixelsHigh == high {
            return rep
        }
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        rep.size = bounds.size
        return rep
    }
}
