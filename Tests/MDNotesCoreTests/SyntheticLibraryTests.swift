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

    func testImageFractionOfNotesEmbedAGeneratedPNGOfTheirOwn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-synth-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try SyntheticLibrary.generate(
            at: root, options: .init(noteCount: 400, largeNoteCount: 1, largeNoteBytes: 10_000, imageFraction: 0.1))
        var embedding = 0
        for (i, path) in paths.enumerated() {
            let body = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let name = SyntheticLibrary.imageName(forNoteAt: i)
            guard body.contains("![[\(name)]]") else {
                XCTAssertFalse(body.contains("![["), "\(path) embeds nothing else")
                continue
            }
            embedding += 1
            let image = root.appendingPathComponent("i/\(name)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "\(name) exists under i/")
            let data = try Data(contentsOf: image)
            XCTAssertEqual(data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "PNG signature")
        }
        XCTAssertGreaterThan(embedding, 20, "about a tenth of 400 notes embed an image")
        XCTAssertLessThan(embedding, 60)
        let images = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("i").path)
        XCTAssertEqual(images.count, embedding, "one image per embedding note, nothing else in i/")
    }

    func testImageFractionZeroEmbedsNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-synth-noimages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try SyntheticLibrary.generate(
            at: root, options: .init(noteCount: 100, largeNoteCount: 0, imageFraction: 0))
        for path in paths {
            let body = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(body.contains("![["), path)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("i").path), [])
    }

    func testPNGDataIsDeterministicAndDiffersBySeed() {
        let a = SyntheticLibrary.pngData(seed: 1, width: 16, height: 8)
        XCTAssertEqual(a, SyntheticLibrary.pngData(seed: 1, width: 16, height: 8))
        XCTAssertNotEqual(a, SyntheticLibrary.pngData(seed: 2, width: 16, height: 8))
        XCTAssertEqual(a.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        // The IEND chunk: zero length, its type, and the CRC every PNG ends with.
        XCTAssertEqual(
            Array(a.suffix(12)), [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
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
