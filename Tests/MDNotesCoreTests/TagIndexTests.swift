import Foundation
import MDNotesCore
import XCTest

/// The tag index maintained with the link index (T-2, K-5): tags to notes, notes to tags,
/// case-insensitive with the library's own spelling, and updated incrementally.
final class TagIndexTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ minutes: Int) -> Date { epoch.addingTimeInterval(Double(minutes) * 60) }

    private func id(_ path: String) -> NoteID { NoteID(relativePath: path) }

    private func index(_ notes: [(path: String, minutes: Int, body: String)]) -> SearchIndex {
        var builder = SearchIndex.Builder()
        for note in notes {
            builder.add(id: id(note.path), modifiedAt: at(note.minutes), body: note.body)
        }
        return builder.build()
    }

    private func paths(_ ids: [NoteID]) -> [String] { ids.map(\.relativePath) }

    /// A stand-in for disk: the current date and body of each note, keyed by path.
    private func disk(_ notes: [String: (minutes: Int, body: String)]) -> (NoteID) -> (modifiedAt: Date, body: String)?
    {
        { id in notes[id.relativePath].map { (self.at($0.minutes), $0.body) } }
    }

    private var base: SearchIndex {
        index([
            ("a.md", 1, "#swift and #appkit notes"),
            ("b.md", 2, "#Swift only"),
            ("nested/c.md", 3, "#Swift #swift twice, and #project/mdnotes"),
            ("d.md", 4, "no tags, just a #hash in `#code` and\n```\n#fenced\n```\n"),
        ])
    }

    // MARK: T-2 mapping

    func testT2_tagsMapToNotesAndNotesToTags() {
        XCTAssertEqual(paths(base.tags.notes(tagged: "appkit")), ["a.md"])
        XCTAssertEqual(paths(base.tags.notes(tagged: "project/mdnotes")), ["nested/c.md"])
        XCTAssertEqual(paths(base.tags.notes(tagged: "hash")), ["d.md"])
        XCTAssertEqual(base.tags.notes(tagged: "missing"), [])
        XCTAssertEqual(base.tags.tags(in: id("a.md")), ["swift", "appkit"])
        XCTAssertEqual(base.tags.tags(in: id("nested/c.md")), ["Swift", "swift", "project/mdnotes"])
        XCTAssertEqual(base.tags.tags(in: id("missing.md")), [])
    }

    func testT2_tagsCompareCaseInsensitivelyAndKeepTheLibrarySpelling() {
        XCTAssertEqual(paths(base.tags.notes(tagged: "swift")), ["a.md", "b.md", "nested/c.md"])
        XCTAssertEqual(paths(base.tags.notes(tagged: "SWIFT")), ["a.md", "b.md", "nested/c.md"])
        XCTAssertEqual(
            paths(base.tags.notes(tagged: "#Swift")), ["a.md", "b.md", "nested/c.md"], "a leading # is accepted")
        XCTAssertEqual(base.tags.count, 4)
        // `Swift` is spelled that way in two notes, `swift` in two as well: the tie goes to
        // the alphabetically first spelling, which is the capitalised one.
        XCTAssertEqual(base.tags.allTags, ["appkit", "hash", "project/mdnotes", "Swift"])
    }

    func testT1_tagsInsideCodeAreNotTags() {
        XCTAssertEqual(base.tags.notes(tagged: "code"), [])
        XCTAssertEqual(base.tags.notes(tagged: "fenced"), [])
        XCTAssertEqual(base.tags.tags(in: id("d.md")), ["hash"])
    }

    // MARK: T-2 incremental

    func testT2_modifiedNoteMovesItsTags() {
        let updated = base.applying(
            changes: LibraryChanges(modified: [id("a.md")]),
            contents: disk(["a.md": (5, "now #golang")]))
        XCTAssertEqual(updated.tags.tags(in: id("a.md")), ["golang"])
        XCTAssertEqual(paths(updated.tags.notes(tagged: "appkit")), [])
        XCTAssertEqual(paths(updated.tags.notes(tagged: "golang")), ["a.md"])
        XCTAssertEqual(paths(updated.tags.notes(tagged: "swift")), ["b.md", "nested/c.md"])
        XCTAssertEqual(updated.tags.allTags, ["golang", "hash", "project/mdnotes", "Swift"])
        XCTAssertEqual(paths(base.tags.notes(tagged: "appkit")), ["a.md"], "the old snapshot is unchanged")
    }

    func testT2_removedNoteLeavesNoTraces() {
        let updated = base.applying(changes: LibraryChanges(removed: [id("b.md"), id("nested/c.md")])) { _ in nil }
        XCTAssertEqual(paths(updated.tags.notes(tagged: "swift")), ["a.md"])
        XCTAssertEqual(updated.tags.notes(tagged: "project/mdnotes"), [])
        XCTAssertEqual(updated.tags.tags(in: id("b.md")), [])
        XCTAssertEqual(
            updated.tags.allTags, ["appkit", "hash", "swift"], "the surviving spelling is the lowercase one")
    }

    func testT2_addedNoteAppears() {
        let updated = base.applying(
            changes: LibraryChanges(added: [id("e.md")]),
            contents: disk(["e.md": (6, "#AppKit and #new-tag_1")]))
        XCTAssertEqual(paths(updated.tags.notes(tagged: "appkit")), ["a.md", "e.md"])
        XCTAssertEqual(paths(updated.tags.notes(tagged: "new-tag_1")), ["e.md"])
        XCTAssertEqual(updated.tags.count, 5)
    }

    func testT2_titlesOnlySnapshotHasNoTagsUntilBodiesAreRead() {
        let titles = SearchIndex.titlesOnly([ScannedNote(id: id("a.md"), modifiedAt: at(1))])
        XCTAssertEqual(titles.tags.count, 0)
        let filled = titles.applying(
            changes: LibraryChanges(modified: [id("a.md")]), contents: disk(["a.md": (1, "#swift")]))
        XCTAssertEqual(paths(filled.tags.notes(tagged: "swift")), ["a.md"])
    }

    func testT2_standaloneIndexAppliesUpsertsAndRemovals() {
        let tags = TagIndex.empty.applying(
            upserts: [(id("a.md"), ["Swift", "swift", "Swift"]), (id("b.md"), ["swift"])], removing: [])
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags.tags(in: id("a.md")), ["Swift", "swift"], "a spelling counts once per note")
        XCTAssertEqual(tags.allTags, ["swift"], "the spelling used by more notes wins")

        let replaced = tags.applying(upserts: [(id("a.md"), ["appkit"])], removing: [id("a.md")])
        XCTAssertEqual(replaced.tags(in: id("a.md")), ["appkit"], "an id both removed and upserted is upserted")
        XCTAssertEqual(replaced.allTags, ["appkit", "swift"])
        XCTAssertEqual(TagIndex.empty.count, 0)
    }
}
