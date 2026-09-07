import Foundation
import MDNotesCore
import XCTest

/// `ImageStore`: where a pasted or dropped image goes and what it is called (I-1), and which
/// file an embed names (I-2). The bytes here are arbitrary; the store never looks at them.
final class ImageStoreTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    private var store = ImageStore(root: FileManager.default.temporaryDirectory)

    /// 7 September 2026, 15:30:12 local time.
    private static let noon: Date = {
        let components = DateComponents(year: 2026, month: 9, day: 7, hour: 15, minute: 30, second: 12)
        return Calendar.current.date(from: components) ?? Date()
    }()

    private let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ImageStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func contents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func write(_ text: String, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: I-1 the name is <yyyyMMdd-HHmmss>.<ext>

    func testI1_fileNameIsTheLocalTimestampAndTheExtension() {
        XCTAssertEqual(ImageStore.fileName(at: Self.noon, extension: "png"), "20260907-153012.png")
        XCTAssertEqual(ImageStore.timestamp(for: Self.noon), "20260907-153012")
    }

    func testI1_theExtensionIsLowercasedAndStrippedOfDots() {
        XCTAssertEqual(ImageStore.fileName(at: Self.noon, extension: ".PNG"), "20260907-153012.png")
        XCTAssertEqual(ImageStore.fileName(at: Self.noon, extension: "Jpg"), "20260907-153012.jpg")
        XCTAssertEqual(ImageStore.normalizedExtension("..TIFF"), "tiff")
        XCTAssertEqual(ImageStore.normalizedExtension(""), "")
    }

    func testI1_theTimestampUsesTheLocalTimeZone() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HHmmss"
        let now = Date()
        XCTAssertTrue(ImageStore.timestamp(for: now).hasSuffix(formatter.string(from: now)))
    }

    // MARK: I-1 the file goes under i/ at the root

    func testI1_writeCreatesTheFolderAndTheFileAndReturnsTheName() throws {
        XCTAssertEqual(store.folder, root.appendingPathComponent("i", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.path))

        let name = try store.write(bytes, extension: "png", at: Self.noon)
        XCTAssertEqual(name, "20260907-153012.png")
        XCTAssertEqual(try contents(of: store.folder), [name], "the file, and no temp file beside it")
        XCTAssertEqual(Array(try Data(contentsOf: store.folder.appendingPathComponent(name))), bytes, "byte for byte")
        XCTAssertEqual(try contents(of: root), ["i"])
    }

    func testI1_writeKeepsAnExistingFolderAndItsFiles() throws {
        try write("keep", at: "i/older.png")
        let name = try store.write(bytes, extension: "jpg", at: Self.noon)
        XCTAssertEqual(try contents(of: store.folder), [name, "older.png"])
        XCTAssertEqual(
            try String(contentsOf: store.folder.appendingPathComponent("older.png"), encoding: .utf8), "keep")
    }

    func testI1_aSecondImageInTheSameSecondGetsASuffixAndOverwritesNothing() throws {
        let first = try store.write(bytes, extension: "png", at: Self.noon)
        let second = try store.write([9, 9, 9], extension: "png", at: Self.noon)
        let third = try store.write([7], extension: "png", at: Self.noon)
        XCTAssertEqual(first, "20260907-153012.png")
        XCTAssertEqual(second, "20260907-153012-2.png")
        XCTAssertEqual(third, "20260907-153012-3.png")
        XCTAssertEqual(Array(try Data(contentsOf: store.folder.appendingPathComponent(first))), bytes)
        XCTAssertEqual(Array(try Data(contentsOf: store.folder.appendingPathComponent(second))), [9, 9, 9])
        XCTAssertEqual(Array(try Data(contentsOf: store.folder.appendingPathComponent(third))), [7])
    }

    func testI1_anotherExtensionInTheSameSecondIsAnotherName() throws {
        let png = try store.write(bytes, extension: "png", at: Self.noon)
        let jpg = try store.write(bytes, extension: "jpg", at: Self.noon)
        XCTAssertEqual([png, jpg], ["20260907-153012.png", "20260907-153012.jpg"])
    }

    func testI1_anEmptyExtensionIsRefused() {
        XCTAssertThrowsError(try store.write(bytes, extension: "", at: Self.noon)) { error in
            XCTAssertEqual(error as? ImageStore.Failure, .emptyExtension)
        }
        XCTAssertThrowsError(try store.write(bytes, extension: ".", at: Self.noon))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.path), "nothing was made")
    }

    func testI1_aFileWhereTheFolderShouldBeFailsTheWrite() throws {
        try write("in the way", at: "i")
        XCTAssertThrowsError(try store.write(bytes, extension: "png", at: Self.noon))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("i"), encoding: .utf8), "in the way")
    }

    // MARK: I-2 an embed names a file under i/ or relative to the root

    func testI2_aBareNameIsLookedForUnderI() throws {
        try write("pic", at: "i/pic.png")
        XCTAssertEqual(
            store.url(forEmbed: "pic.png"), store.folder.appendingPathComponent("pic.png", isDirectory: false))
        XCTAssertEqual(store.url(forEmbed: " pic.png\n"), store.url(forEmbed: "pic.png"), "trimmed")
    }

    func testI2_aBareNameNotUnderIIsLookedForAtTheRoot() throws {
        try write("root pic", at: "pic.png")
        XCTAssertEqual(store.url(forEmbed: "pic.png"), root.appendingPathComponent("pic.png", isDirectory: false))
        try write("i pic", at: "i/pic.png")
        XCTAssertEqual(
            store.url(forEmbed: "pic.png"), store.folder.appendingPathComponent("pic.png", isDirectory: false),
            "i/ wins when both exist")
    }

    func testI2_aPathIsRelativeToTheRoot() throws {
        try write("other", at: "assets/other.png")
        try write("in i", at: "i/other.png")
        XCTAssertEqual(
            store.url(forEmbed: "assets/other.png"), root.appendingPathComponent("assets/other.png", isDirectory: false)
        )
        XCTAssertEqual(
            store.url(forEmbed: "i/other.png"), store.folder.appendingPathComponent("other.png", isDirectory: false))
        XCTAssertNil(store.url(forEmbed: "assets/missing.png"))
    }

    func testI2_theNameOfAStoredImageResolvesToIt() throws {
        let name = try store.write(bytes, extension: "png", at: Self.noon)
        XCTAssertEqual(store.url(forEmbed: name), store.folder.appendingPathComponent(name, isDirectory: false))
    }

    func testI2_missingFilesFoldersAndEscapingPathsAreNil() throws {
        try write("pic", at: "i/pic.png")
        try write("secret", at: "../outside-\(root.lastPathComponent).txt")
        defer {
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent("../outside-\(root.lastPathComponent).txt"))
        }
        XCTAssertNil(store.url(forEmbed: "missing.png"))
        XCTAssertNil(store.url(forEmbed: ""))
        XCTAssertNil(store.url(forEmbed: "   "))
        XCTAssertNil(store.url(forEmbed: "i"), "a folder is not a file")
        XCTAssertNil(store.url(forEmbed: "i/"), "an empty segment")
        XCTAssertNil(store.url(forEmbed: "../outside-\(root.lastPathComponent).txt"), "never above the root")
        XCTAssertNil(store.url(forEmbed: "i/../i/pic.png"))
        XCTAssertNil(store.url(forEmbed: "./pic.png"))
    }
}
