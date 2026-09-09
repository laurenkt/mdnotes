import Foundation
import MDNotesCore
import XCTest

/// `TemplateStore` over a temp library: which files are templates and what they are called
/// (TP-1), how the list is ordered, and reading one through `TemplateParser` (TP-2).
final class TemplateStoreTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    private var store = TemplateStore(root: FileManager.default.temporaryDirectory)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-templates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TemplateStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `body` at `relativePath` under the root, creating folders as needed.
    private func write(_ relativePath: String, _ body: String = "---\npath: x\n---\n") throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
    }

    // MARK: TP-1 what is a template, and what it is called

    func testTP1_listsMDFilesDirectlyInsideTemplatesByName() throws {
        try write("templates/daily.md")
        try write("templates/Meeting notes.md")
        try write("templates/readme.txt")
        try write("templates/.hidden.md")
        try write("templates/.md")
        try write("templates/nested/deeper.md")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("templates/folder.md"), withIntermediateDirectories: true)
        try write("daily.md")
        try write("Trash/old.md")
        XCTAssertEqual(try store.names(), ["daily", "Meeting notes"])
    }

    func testTP1_namesAreSortedCaseInsensitively() throws {
        // Names that fold to the same thing are one file on a case-insensitive volume, so the
        // spelling tie-breaker cannot be exercised here; the fold itself can.
        for name in ["zeta", "Alpha", "beta", "Gamma", "delta"] { try write("templates/\(name).md") }
        XCTAssertEqual(try store.names(), ["Alpha", "beta", "delta", "Gamma", "zeta"])
    }

    func testTP1_libraryWithoutTemplatesFolderHasNoTemplates() throws {
        XCTAssertEqual(try store.names(), [])
        try write("note.md")
        XCTAssertEqual(try store.names(), [])
    }

    func testTP1_nameForRelativePath() {
        XCTAssertEqual(TemplateStore.name(forRelativePath: "templates/daily.md"), "daily")
        XCTAssertEqual(TemplateStore.name(forRelativePath: "templates/Meeting notes.md"), "Meeting notes")
        XCTAssertNil(TemplateStore.name(forRelativePath: "templates/nested/deeper.md"), "not directly inside")
        XCTAssertNil(TemplateStore.name(forRelativePath: "templates/readme.txt"), "not .md")
        XCTAssertNil(TemplateStore.name(forRelativePath: "templates/.hidden.md"), "hidden")
        XCTAssertNil(TemplateStore.name(forRelativePath: "templates/.md"), "no name")
        XCTAssertNil(TemplateStore.name(forRelativePath: "templates"), "the folder itself")
        XCTAssertNil(TemplateStore.name(forRelativePath: "daily.md"), "a note")
        XCTAssertNil(TemplateStore.name(forRelativePath: "Templates/daily.md"), "the folder name is exact")
        XCTAssertNil(TemplateStore.name(forRelativePath: "notes/templates/daily.md"), "not under the root")
    }

    func testTP1_templatesAreNeverNotes() throws {
        try write("templates/daily.md")
        try write("note.md")
        XCTAssertEqual(try LibraryScanner.scan(root: root).map(\.id.relativePath), ["note.md"])
        XCTAssertNil(LibraryScanner.noteID(forRelativePath: "templates/daily.md"))
        XCTAssertEqual(TemplateStore.folderName, "templates")
        XCTAssertTrue(LibraryScanner.skippedRootFolders.contains(TemplateStore.folderName))
    }

    // MARK: TP-2 reading a template through the parser

    func testTP2_readParsesTheFileOrReportsWhyItIsRefused() throws {
        try write("templates/daily.md", "---\npath: daily/{{date:yyyy-MM-dd}}\n---\n# {{title}}\n{{cursor}}")
        try write("templates/headless.md", "no header here")
        try write("templates/pathless.md", "---\nkind: note\n---\nbody")
        XCTAssertEqual(store.url(for: "daily"), root.appendingPathComponent("templates/daily.md"))
        XCTAssertEqual(
            try store.read("daily"),
            .success(TemplateParser.Template(path: "daily/{{date:yyyy-MM-dd}}", body: "# {{title}}\n{{cursor}}")))
        XCTAssertEqual(try store.read("headless"), .failure(.missingHeader))
        XCTAssertEqual(try store.read("pathless"), .failure(.missingPath))
        XCTAssertThrowsError(try store.read("missing"))
    }
}
