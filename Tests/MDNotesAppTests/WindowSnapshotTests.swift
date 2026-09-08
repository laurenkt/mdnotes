import AppKit
import MDNotesApp
import XCTest

/// The V-1 helper itself: the main window renders to `build/snapshots/main-window-light.png`
/// and `-dark.png`, at 2x, and the window is left as it was.
@MainActor
final class WindowSnapshotTests: XCTestCase {
    func testV1_mainWindowRendersLightAndDarkAt2x() throws {
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 480, height: 320))
        controller.mainView.layoutSubtreeIfNeeded()
        let bounds = try XCTUnwrap(window.contentView).bounds

        let written = try writeWindowSnapshots(of: controller, named: "main-window")

        XCTAssertEqual(written.map(\.lastPathComponent), ["main-window-light.png", "main-window-dark.png"])
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/snapshots", isDirectory: true).standardizedFileURL
        var pngs: [Data] = []
        for url in written {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory, url.path)
            let data = try Data(contentsOf: url)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data), url.path)
            XCTAssertEqual(rep.pixelsWide, Int(bounds.width) * 2, "\(url.lastPathComponent) is 2x wide")
            XCTAssertEqual(rep.pixelsHigh, Int(bounds.height) * 2, "\(url.lastPathComponent) is 2x high")
            pngs.append(data)
        }
        XCTAssertNotEqual(pngs[0], pngs[1], "light and dark appearances render differently")
        XCTAssertNil(window.appearance, "the window follows the system appearance again afterwards")
    }
}
