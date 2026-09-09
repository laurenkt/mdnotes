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

    /// I-7: a window whose content view paints no background (Settings, PR-1) still writes an
    /// opaque PNG in both appearances, filled with `windowBackgroundColor` as the window renders it.
    func testV1_transparentContentViewIsRenderedOnTheWindowBackground() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))

        let written = try writeWindowSnapshots(ofWindow: window, named: "transparent-content")

        var corners: [NSColor] = []
        for url in written {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)), url.path)
            let corner = try XCTUnwrap(rep.colorAt(x: 1, y: 1), url.path)
            XCTAssertEqual(corner.alphaComponent, 1, accuracy: 0.001, "\(url.lastPathComponent) is opaque")
            corners.append(corner)
        }
        XCTAssertNotEqual(corners[0], corners[1], "light and dark backgrounds differ")
    }

    /// I-9: a row selected on the same run-loop turn as the capture is highlighted in both
    /// files. The light capture came first and showed no band while the dark one, drawn after
    /// the appearance change, did.
    func testV1_aSelectionMadeJustBeforeTheCaptureShowsInBothAppearances() throws {
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 480, height: 320))
        controller.mainView.layoutSubtreeIfNeeded()
        controller.listController.show(templates: [
            NoteListController.TemplateRow(name: "one", snippet: "1"),
            NoteListController.TemplateRow(name: "two", snippet: "2"),
            NoteListController.TemplateRow(name: "three", snippet: "3"),
        ])
        let table = controller.mainView.tableView
        let contentView = try XCTUnwrap(window.contentView)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        let written = try writeWindowSnapshots(of: controller, named: "selected-row")

        // A pixel near the right edge of a row, clear of its text, in image coordinates.
        func pixel(ofRow row: Int, in rep: NSBitmapImageRep) throws -> NSColor {
            let rect = contentView.convert(table.rect(ofRow: row), from: table)
            let x = Int((rect.maxX - 10) * 2)
            let y = Int((contentView.bounds.height - rect.midY) * 2)
            return try XCTUnwrap(rep.colorAt(x: x, y: y), "pixel at \(x),\(y)")
        }
        for url in written {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)), url.path)
            let unselected = try pixel(ofRow: 0, in: rep)
            let selected = try pixel(ofRow: 1, in: rep)
            XCTAssertNotEqual(selected, unselected, "\(url.lastPathComponent) shows the selected row's band")
        }
    }
}
