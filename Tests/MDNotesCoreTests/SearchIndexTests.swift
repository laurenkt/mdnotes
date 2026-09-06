import Foundation
import MDNotesCore
import XCTest

final class SearchIndexTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Minutes after `epoch`, so tests can spell out relative modification order.
    private func at(_ minutes: Int) -> Date { epoch.addingTimeInterval(Double(minutes) * 60) }

    private func index(_ notes: [(path: String, minutes: Int, body: String)]) -> SearchIndex {
        var builder = SearchIndex.Builder()
        for note in notes {
            builder.add(id: NoteID(relativePath: note.path), modifiedAt: at(note.minutes), body: note.body)
        }
        return builder.build()
    }

    private func paths<Entries: Collection<SearchIndex.Entry>>(_ results: Entries) -> [String] {
        results.map(\.id.relativePath)
    }

    // MARK: S-2 matching

    func testS2_wordOrderIsIrrelevant() {
        let index = self.index([("notes.md", 1, "the kubernetes operator pattern")])
        XCTAssertEqual(paths(index.query("kubernetes operator")), ["notes.md"])
        XCTAssertEqual(paths(index.query("operator kubernetes")), ["notes.md"])
        XCTAssertEqual(paths(index.query("pattern the operator")), ["notes.md"])
    }

    func testS2_matchIsCaseInsensitive() {
        let index = self.index([("Meeting Notes.md", 1, "Discussed the Guggenheim Trip")])
        XCTAssertEqual(paths(index.query("MEETING")), ["Meeting Notes.md"])
        XCTAssertEqual(paths(index.query("meeting")), ["Meeting Notes.md"])
        XCTAssertEqual(paths(index.query("guggenheim TRIP")), ["Meeting Notes.md"])
        XCTAssertEqual(paths(index.query("GuGgEnHeIm")), ["Meeting Notes.md"])
    }

    func testS2_everyWordMustMatch() {
        let index = self.index([
            ("london.md", 1, "trip to deptford"),
            ("paris.md", 2, "trip to the louvre"),
        ])
        XCTAssertEqual(paths(index.query("trip")), ["paris.md", "london.md"])
        XCTAssertEqual(paths(index.query("trip deptford")), ["london.md"])
        XCTAssertEqual(paths(index.query("trip deptford louvre")), [])
        XCTAssertEqual(paths(index.query("nowhere")), [])
    }

    func testS2_wordsAreSubstringsNotTokens() {
        let index = self.index([("Master plan.md", 1, "flashcards for airfoils")])
        XCTAssertEqual(paths(index.query("aster")), ["Master plan.md"])
        XCTAssertEqual(paths(index.query("card foil")), ["Master plan.md"])
        XCTAssertEqual(paths(index.query("masterplan")), [])
    }

    func testS2_eachWordMayMatchTitleOrBody() {
        // "golang" is only in the title, "socket" only in the body: still one match.
        let index = self.index([("golang.md", 1, "socket programming")])
        XCTAssertEqual(paths(index.query("golang socket")), ["golang.md"])
        XCTAssertEqual(paths(index.query("socket golang")), ["golang.md"])
    }

    func testS2_anyWhitespaceSeparatesWords() {
        let index = self.index([("a.md", 1, "alpha beta")])
        XCTAssertEqual(paths(index.query("  alpha\t\tbeta \n")), ["a.md"])
        XCTAssertEqual(paths(index.query("alpha   beta")), ["a.md"])
    }

    func testS2_nestedPathsMatchOnTitleOnly() {
        // L-4/L-5: the identity is the path but the title is the filename; folders are not searched.
        let index = self.index([("daily/2026/06-sunday.md", 1, "rest")])
        XCTAssertEqual(paths(index.query("sunday")), ["daily/2026/06-sunday.md"])
        XCTAssertEqual(paths(index.query("daily")), [])
        XCTAssertEqual(paths(index.query("2026")), [])
    }

    func testS2_nonASCIIMatchesCaseInsensitively() {
        let index = self.index([("kupka.md", 1, "František Kupka, painter")])
        XCTAssertEqual(paths(index.query("frantiŠek")), ["kupka.md"])
        XCTAssertEqual(paths(index.query("františek painter")), ["kupka.md"])
    }

    // MARK: S-3 ordering

    func testS3_titleMatchesSortFirst() {
        let index = self.index([
            ("body only.md", 3, "mentions swift once"),
            ("swift notes.md", 1, "nothing relevant"),
            ("unrelated.md", 2, "nothing at all"),
        ])
        XCTAssertEqual(paths(index.query("swift")), ["swift notes.md", "body only.md"])
    }

    func testS3_titleGroupNeedsEveryWordInTheTitle() {
        // "swift" is in the title but "actor" only in the body: this is a body match and sorts
        // after a newer note that carries both words in its title.
        let index = self.index([
            ("swift.md", 5, "actor isolation"),
            ("swift actor.md", 1, ""),
            ("misc.md", 9, "swift actor"),
        ])
        XCTAssertEqual(paths(index.query("swift actor")), ["swift actor.md", "misc.md", "swift.md"])
    }

    func testS3_withinGroupMostRecentlyModifiedFirst() {
        let index = self.index([
            ("swift old.md", 1, ""),
            ("swift new.md", 3, ""),
            ("swift mid.md", 2, ""),
            ("body old.md", 4, "swift"),
            ("body new.md", 6, "swift"),
            ("body mid.md", 5, "swift"),
        ])
        XCTAssertEqual(
            paths(index.query("swift")),
            ["swift new.md", "swift mid.md", "swift old.md", "body new.md", "body mid.md", "body old.md"])
    }

    func testS3_emptyQueryListsAllByModifiedDate() {
        let index = self.index([
            ("b.md", 2, "two"),
            ("c.md", 3, "three"),
            ("a.md", 1, "one"),
        ])
        XCTAssertEqual(paths(index.query("")), ["c.md", "b.md", "a.md"])
        XCTAssertEqual(paths(index.query("   \t\n")), ["c.md", "b.md", "a.md"])
        XCTAssertEqual(paths(index.entries), ["c.md", "b.md", "a.md"])
    }

    func testS3_emptyIndexReturnsNothing() {
        XCTAssertEqual(SearchIndex.empty.count, 0)
        XCTAssertEqual(paths(SearchIndex.empty.query("")), [])
        XCTAssertEqual(paths(SearchIndex.empty.query("anything")), [])
        XCTAssertEqual(paths(SearchIndex.Builder().build().query("")), [])
    }

    // MARK: S-4 tags

    func testS4_tagIsAnOrdinaryWord() {
        let index = self.index([
            ("tagged.md", 2, "learning #swift today"),
            ("untagged.md", 1, "learning swift today"),
        ])
        XCTAssertEqual(paths(index.query("#swift")), ["tagged.md"])
        XCTAssertEqual(paths(index.query("swift")), ["tagged.md", "untagged.md"])
        XCTAssertEqual(paths(index.query("#swift learning")), ["tagged.md"])
    }

    func testS4_tagQueryIsASubstringMatch() {
        let index = self.index([
            ("ui.md", 2, "#swiftui layout"),
            ("nested.md", 1, "#dev/swift notes"),
        ])
        XCTAssertEqual(paths(index.query("#swift")), ["ui.md"])
        XCTAssertEqual(paths(index.query("#dev/swift")), ["nested.md"])
        XCTAssertEqual(paths(index.query("#SWIFTUI")), ["ui.md"])
    }

    func testS4_tagInTitleCountsAsTitleMatch() {
        let index = self.index([
            ("#inbox.md", 1, ""),
            ("later.md", 2, "filed under #inbox"),
        ])
        XCTAssertEqual(paths(index.query("#inbox")), ["#inbox.md", "later.md"])
    }

    // MARK: builder and snapshot

    func testBuilderStoresLowercaseTitleAndBody() {
        let index = self.index([("Daily/Meeting Notes.md", 1, "Hello WORLD")])
        let entry = index.entry(for: NoteID(relativePath: "Daily/Meeting Notes.md"))
        XCTAssertEqual(entry?.title, "meeting notes")
        XCTAssertEqual(entry?.body, "hello world")
        XCTAssertEqual(entry?.modifiedAt, at(1))
        XCTAssertNil(index.entry(for: NoteID(relativePath: "missing.md")))
    }

    func testBuilderKeepsTheLastVersionOfANote() {
        var builder = SearchIndex.Builder()
        let id = NoteID(relativePath: "n.md")
        builder.add(id: id, modifiedAt: at(1), body: "first")
        builder.add(id: id, modifiedAt: at(2), body: "second")
        XCTAssertEqual(builder.count, 1)
        let index = builder.build()
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(paths(index.query("second")), ["n.md"])
        XCTAssertEqual(paths(index.query("first")), [])
        XCTAssertEqual(index.entry(for: id)?.modifiedAt, at(2))
    }

    func testL7_unreadableNoteIsIndexedByTitleOnly() {
        var builder = SearchIndex.Builder()
        builder.add(id: NoteID(relativePath: "evicted.md"), modifiedAt: at(1))
        let index = builder.build()
        XCTAssertEqual(paths(index.query("evicted")), ["evicted.md"])
        XCTAssertEqual(paths(index.query("")), ["evicted.md"])
        XCTAssertEqual(index.entry(for: NoteID(relativePath: "evicted.md"))?.body, "")
    }

    func testSnapshotIsUnaffectedByLaterBuilderChanges() {
        var builder = SearchIndex.Builder()
        builder.add(id: NoteID(relativePath: "a.md"), modifiedAt: at(1), body: "alpha")
        let snapshot = builder.build()
        builder.add(id: NoteID(relativePath: "b.md"), modifiedAt: at(2), body: "beta")
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(paths(snapshot.query("beta")), [])
        XCTAssertEqual(builder.build().count, 2)
    }

    // MARK: PF-7 titles-only launch snapshot

    func testPF7_titlesOnlySnapshotMatchesTheBuilderWithEmptyBodies() {
        // Two notes share a modification date so the path tie-break is exercised.
        let scanned = [
            ScannedNote(id: NoteID(relativePath: "b.md"), modifiedAt: at(2)),
            ScannedNote(id: NoteID(relativePath: "daily/2026/Kupka.md"), modifiedAt: at(5)),
            ScannedNote(id: NoteID(relativePath: "a.md"), modifiedAt: at(2)),
            ScannedNote(id: NoteID(relativePath: "Zebra.md"), modifiedAt: at(1)),
        ]
        let titlesOnly = SearchIndex.titlesOnly(scanned)
        let built = index(scanned.map { ($0.id.relativePath, Int($0.modifiedAt.timeIntervalSince(epoch) / 60), "") })

        XCTAssertEqual(titlesOnly.count, 4)
        XCTAssertEqual(paths(titlesOnly.entries), ["daily/2026/Kupka.md", "a.md", "b.md", "Zebra.md"])
        XCTAssertEqual(titlesOnly.entries, built.entries, "same entries, same order, same folded text")
        XCTAssertEqual(titlesOnly.entries.map(\.title), ["kupka", "a", "b", "zebra"])
        XCTAssertTrue(titlesOnly.entries.allSatisfy { $0.body.isEmpty && $0.preview.isEmpty })
        XCTAssertEqual(paths(titlesOnly.query("kupka")), ["daily/2026/Kupka.md"])
        XCTAssertEqual(paths(titlesOnly.query("ZEB")), ["Zebra.md"])
        XCTAssertEqual(SearchIndex.titlesOnly([]).count, 0)
    }
}
