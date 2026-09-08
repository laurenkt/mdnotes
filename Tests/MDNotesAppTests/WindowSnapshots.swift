import AppKit
import MDNotesApp
import XCTest

extension XCTestCase {
    /// Renders the window's content view at 2x in light and dark appearance to
    /// `build/snapshots/<name>-<appearance>.png` (V-1) and returns the files written. The
    /// implementing agent opens these and compares them with the spec and the design canvas
    /// (ADR-0013, ADR-0015); they are build products and never committed.
    @MainActor
    func writeWindowSnapshots(of controller: MainWindowController, named name: String) throws -> [URL] {
        guard let window = controller.window, let view = window.contentView else {
            throw CocoaError(.fileNoSuchFile)
        }
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
            let scale = 2
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(bounds.width) * scale,
                    pixelsHigh: Int(bounds.height) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { throw CocoaError(.fileWriteUnknown) }
            rep.size = bounds.size
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
}
