import Foundation
import MDNotesCore
import XCTest

/// First-image resolution (S-11): the first `![[target]]` in a body that names an existing image
/// file, found through the embed resolver (K-1, I-2) and stored on the index snapshot as a
/// root-relative path. The image bytes are arbitrary: only the file's existence and extension
/// are looked at.
final class FirstImageTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    private var store = ImageStore(root: FileManager.default.temporaryDirectory)
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-first-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ImageStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Writes a small file at `relativePath` under the root, creating folders.
    private func write(_ text: String, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func firstImage(in body: String) -> String? {
        store.firstImage(in: NoteReferences(scanning: body).links)
    }

    private func id(_ path: String) -> NoteID { NoteID(relativePath: path) }

    // MARK: S-11 the resolver

    func testS11_bodyWithoutEmbedsHasNoImage() throws {
        try write("png", at: "i/photo.png")
        XCTAssertNil(firstImage(in: ""))
        XCTAssertNil(firstImage(in: "Just prose, and a [[photo.png]] link that is not an embed."))
    }

    func testS11_oneEmbedResolvesToTheFileUnderI() throws {
        try write("png", at: "i/photo.png")
        XCTAssertEqual(firstImage(in: "Look:\n\n![[photo.png]]\n"), "i/photo.png")
    }

    func testS11_firstOfSeveralEmbedsWins() throws {
        try write("png", at: "i/first.png")
        try write("jpg", at: "i/second.jpg")
        try write("gif", at: "assets/third.gif")
        let body = "![[first.png]] then ![[second.jpg]] and ![[assets/third.gif]]"
        XCTAssertEqual(firstImage(in: body), "i/first.png")
        XCTAssertEqual(firstImage(in: "![[assets/third.gif]] before ![[first.png]]"), "assets/third.gif")
    }

    func testS11_unresolvableEmbedGivesNoImage() throws {
        XCTAssertNil(firstImage(in: "![[missing.png]]"))
        try write("not an image", at: "i/notes.txt")
        XCTAssertNil(firstImage(in: "![[notes.txt]]"), "a file that exists but is not an image does not count")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("i/folder.png"), withIntermediateDirectories: true)
        XCTAssertNil(firstImage(in: "![[folder.png]]"), "a folder is not a file")
        XCTAssertNil(firstImage(in: "![[../outside.png]]"), "a target that leaves the root never resolves")
    }

    func testS11_unresolvableFirstEmbedIsSkippedForTheFirstThatResolves() throws {
        try write("png", at: "i/real.png")
        XCTAssertEqual(firstImage(in: "![[gone.png]] ![[real.png]]"), "i/real.png")
        XCTAssertEqual(firstImage(in: "![[notes.txt]] ![[real.png]]"), "i/real.png")
    }

    func testK1_embedInsideCodeIsNotAnEmbed() throws {
        try write("png", at: "i/photo.png")
        XCTAssertNil(firstImage(in: "`![[photo.png]]`"))
        XCTAssertNil(firstImage(in: "```\n![[photo.png]]\n```"))
    }

    func testS11_imageFilesAreDecidedByExtension() {
        for path in ["a.png", "a.jpg", "a.jpeg", "a.gif", "a.tiff", "a.heic", "i/a.PNG"] {
            XCTAssertTrue(ImageStore.isImageFile(path), path)
        }
        for path in ["a.txt", "a.md", "a.pdf", "a", "i/a.json"] {
            XCTAssertFalse(ImageStore.isImageFile(path), path)
        }
    }

    // MARK: S-11 stored on the snapshot

    func testS11_snapshotBuiltFromDiskCarriesEachNotesFirstImage() throws {
        try write("png", at: "i/photo.png")
        try write("Text and ![[photo.png]]", at: "with.md")
        try write("Text and ![[missing.png]]", at: "broken.md")
        try write("Text only", at: "plain.md")
        let index = SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: NoteStore(root: root))
        XCTAssertEqual(index.entry(for: id("with.md"))?.firstImagePath, "i/photo.png")
        XCTAssertNil(index.entry(for: id("broken.md"))?.firstImagePath)
        XCTAssertNil(index.entry(for: id("plain.md"))?.firstImagePath)
    }

    func testS11_builderResolvesOnlyWhenGivenAStore() throws {
        try write("png", at: "i/photo.png")
        var builder = SearchIndex.Builder()
        builder.add(id: id("a.md"), modifiedAt: epoch, body: "![[photo.png]]", images: store)
        builder.add(id: id("b.md"), modifiedAt: epoch, body: "![[photo.png]]")
        let index = builder.build()
        XCTAssertEqual(index.entry(for: id("a.md"))?.firstImagePath, "i/photo.png")
        XCTAssertNil(index.entry(for: id("b.md"))?.firstImagePath)
    }

    func testS11_incrementalUpdateFromDiskAndFromMemoryKeepsTheImage() throws {
        try write("png", at: "i/photo.png")
        try write("nothing yet", at: "a.md")
        let store = NoteStore(root: root)
        let initial = SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: store)
        XCTAssertNil(initial.entry(for: id("a.md"))?.firstImagePath)

        try write("now ![[photo.png]]", at: "a.md")
        let fromDisk = initial.applying(changes: LibraryChanges(modified: [id("a.md")]), store: store)
        XCTAssertEqual(fromDisk.entry(for: id("a.md"))?.firstImagePath, "i/photo.png")

        let fromMemory = fromDisk.applying(changes: LibraryChanges(modified: [id("a.md")]), images: self.store) { _ in
            (modifiedAt: self.epoch, body: "edited, still ![[photo.png]]")
        }
        XCTAssertEqual(fromMemory.entry(for: id("a.md"))?.firstImagePath, "i/photo.png")

        let removed = fromMemory.applying(changes: LibraryChanges(modified: [id("a.md")]), images: self.store) { _ in
            (modifiedAt: self.epoch, body: "embed gone")
        }
        XCTAssertNil(removed.entry(for: id("a.md"))?.firstImagePath)
        XCTAssertNotEqual(fromMemory.entry(for: id("a.md")), removed.entry(for: id("a.md")))
    }

    // MARK: S-11 with X-1: an image that arrives, changes or goes without its note changing

    func testS11_anImageArrivingOrGoingReResolvesTheNotesEmbeddingItWithoutRereadingThem() throws {
        try write("png", at: "i/photo.png")
        try write("![[late.png]] then ![[photo.png]]", at: "a.md")
        try write("only ![[late.png]]", at: "b.md")
        try write("![[assets/pic.gif]] by path", at: "c.md")
        try write("no embeds, a [[late.png]] link only", at: "d.md")
        let store = NoteStore(root: root)
        let initial = SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: store)
        XCTAssertEqual(initial.entry(for: id("a.md"))?.firstImagePath, "i/photo.png")
        XCTAssertNil(initial.entry(for: id("b.md"))?.firstImagePath)
        XCTAssertNil(initial.entry(for: id("c.md"))?.firstImagePath)

        // The images arrive. The notes' files are rewritten too, so a reread would show.
        try write("png", at: "i/late.png")
        try write("gif", at: "assets/pic.gif")
        for note in ["a.md", "b.md", "c.md", "d.md"] { try write("rewritten on disk", at: note) }
        let arrived = initial.applying(changes: LibraryChanges(images: ["i/late.png", "assets/pic.gif"]), store: store)
        XCTAssertEqual(arrived.entry(for: id("a.md"))?.firstImagePath, "i/late.png", "the earlier embed now resolves")
        XCTAssertEqual(arrived.entry(for: id("b.md"))?.firstImagePath, "i/late.png")
        XCTAssertEqual(arrived.entry(for: id("c.md"))?.firstImagePath, "assets/pic.gif", "an embed by path")
        XCTAssertEqual(arrived.entry(for: id("a.md"))?.body, "![[late.png]] then ![[photo.png]]", "not reread")
        XCTAssertEqual(arrived.entry(for: id("b.md"))?.body, "only ![[late.png]]")
        XCTAssertEqual(arrived.entry(for: id("d.md")), initial.entry(for: id("d.md")), "a link is not an embed")
        XCTAssertEqual(arrived.entries.map(\.id), initial.entries.map(\.id), "list order is kept (S-3)")
        XCTAssertEqual(arrived.entries.map(\.modifiedAt), initial.entries.map(\.modifiedAt))

        // One goes: the note falls back to its next embed, or to none.
        try FileManager.default.removeItem(at: root.appendingPathComponent("i/late.png"))
        let gone = arrived.applying(changes: LibraryChanges(images: ["i/late.png"]), store: store)
        XCTAssertEqual(gone.entry(for: id("a.md"))?.firstImagePath, "i/photo.png")
        XCTAssertNil(gone.entry(for: id("b.md"))?.firstImagePath)
        XCTAssertEqual(gone.entry(for: id("c.md")), arrived.entry(for: id("c.md")), "untouched")

        // A change to an image no note embeds changes nothing.
        let unrelated = gone.applying(changes: LibraryChanges(images: ["i/other.png"]), store: store)
        XCTAssertEqual(unrelated.entries, gone.entries)
    }

    func testS11_imageChangesReResolveThroughTheInMemoryUpdateOnlyWhenGivenAStore() throws {
        try write("![[late.png]]", at: "a.md")
        let store = NoteStore(root: root)
        let initial = SearchIndex.build(notes: try LibraryScanner.scan(root: root), store: store)
        XCTAssertNil(initial.entry(for: id("a.md"))?.firstImagePath)
        try write("png", at: "i/late.png")

        let unresolved = initial.applying(changes: LibraryChanges(images: ["i/late.png"])) { _ in nil }
        XCTAssertNil(unresolved.entry(for: id("a.md"))?.firstImagePath, "no store to resolve against")
        let resolved = initial.applying(changes: LibraryChanges(images: ["i/late.png"]), images: self.store) { _ in nil
        }
        XCTAssertEqual(resolved.entry(for: id("a.md"))?.firstImagePath, "i/late.png")
        XCTAssertEqual(resolved.count, 1, "nothing was reread or dropped")

        // A note whose body is not indexed yet has no embeds to re-resolve; its body read does.
        let titlesOnly = SearchIndex.titlesOnly(try LibraryScanner.scan(root: root))
        let untouched = titlesOnly.applying(imageChanges: ["i/late.png"], images: self.store)
        XCTAssertEqual(untouched.entries, titlesOnly.entries)
        XCTAssertEqual(
            untouched.applying(reading: try LibraryScanner.scan(root: root), store: store).entry(for: id("a.md"))?
                .firstImagePath, "i/late.png")
    }
}
