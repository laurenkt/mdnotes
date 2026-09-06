import Foundation
import MDNotesTestSupport
import XCTest

final class SyntheticLibraryTests: XCTestCase {
    func testGeneratesRequestedNumberOfNotes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-synth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try SyntheticLibrary.generate(
            at: root, options: .init(noteCount: 50, largeNoteCount: 1, largeNoteBytes: 10_000))
        XCTAssertEqual(paths.count, 50)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(paths[0]).path))
    }

    func testIsDeterministic() throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("mdnotes-a-\(UUID().uuidString)")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("mdnotes-b-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let opts = SyntheticLibrary.Options(noteCount: 20, largeNoteCount: 0)
        let pa = try SyntheticLibrary.generate(at: a, options: opts)
        let pb = try SyntheticLibrary.generate(at: b, options: opts)
        XCTAssertEqual(pa, pb)
        let ca = try String(contentsOf: a.appendingPathComponent(pa[3]), encoding: .utf8)
        let cb = try String(contentsOf: b.appendingPathComponent(pb[3]), encoding: .utf8)
        XCTAssertEqual(ca, cb)
    }
}
