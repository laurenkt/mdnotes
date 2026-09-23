import Foundation
import MDNotesCore
import XCTest

/// The link index built alongside the search snapshot (K-5): outgoing targets, incoming notes,
/// and resolution of a target to a note by unique title, ambiguous title, or path (K-2, K-1).
final class LinkIndexTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Minutes after `epoch`, so tests can spell out relative modification order.
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

    /// Two notes titled `foo`, both in folders so neither wins by root path (ADR-0023), the
    /// `daily` one newer, plus notes that link to them each way.
    private var ambiguous: SearchIndex {
        index([
            ("notes/foo.md", 1, "the older foo"),
            ("daily/2026/foo.md", 2, "the newer foo"),
            ("bare.md", 3, "see [[foo]]"),
            ("qualified.md", 4, "see [[daily/2026/foo]]"),
            ("root-path.md", 5, "see [[Foo]] and [[daily/2026/FOO]]"),
        ])
    }

    // MARK: K-2 unique

    func testK2_uniqueTitleResolvesToThatNote() {
        let snapshot = index([
            ("Alpha.md", 1, "links to [[Beta]]"),
            ("nested/Beta.md", 2, ""),
        ])
        XCTAssertEqual(snapshot.links.resolve("Beta"), .unique(id("nested/Beta.md")))
        XCTAssertEqual(
            snapshot.links.resolve("beta"), .unique(id("nested/Beta.md")), "titles compare case-insensitively")
        XCTAssertEqual(
            snapshot.links.resolve("  Beta "), .unique(id("nested/Beta.md")), "surrounding whitespace is ignored")
        XCTAssertEqual(snapshot.links.resolve("Beta").target, id("nested/Beta.md"))
        XCTAssertFalse(snapshot.links.resolve("Beta").isAmbiguous)
    }

    func testK2_unknownTitleIsUnresolved() {
        let snapshot = index([("Alpha.md", 1, "[[Gamma]]")])
        XCTAssertEqual(snapshot.links.resolve("Gamma"), .unresolved)
        XCTAssertEqual(snapshot.links.resolve("nested/Gamma"), .unresolved)
        XCTAssertEqual(snapshot.links.resolve(""), .unresolved)
        XCTAssertNil(snapshot.links.resolve("Gamma").target)
    }

    // MARK: K-2 ambiguous

    func testK2_ambiguousTitleResolvesToMostRecentlyModifiedAndIsFlagged() {
        let resolution = ambiguous.links.resolve("foo")
        XCTAssertEqual(
            resolution, .ambiguous(id("daily/2026/foo.md"), candidates: [id("daily/2026/foo.md"), id("notes/foo.md")]))
        XCTAssertTrue(resolution.isAmbiguous)
        XCTAssertEqual(resolution.target, id("daily/2026/foo.md"))
    }

    func testK2_ambiguityFollowsModificationDates() {
        // The older note is touched and becomes the newer one: bare links now open it.
        let touched = ambiguous.applying(
            changes: LibraryChanges(modified: [id("notes/foo.md")]),
            contents: disk(["notes/foo.md": (9, "the older foo, edited")]))
        XCTAssertEqual(
            touched.links.resolve("foo"),
            .ambiguous(id("notes/foo.md"), candidates: [id("notes/foo.md"), id("daily/2026/foo.md")]))
    }

    func testK2_ambiguityWithEqualDatesIsDeterministic() {
        let snapshot = index([
            ("b/foo.md", 1, ""),
            ("a/foo.md", 1, ""),
        ])
        XCTAssertEqual(
            snapshot.links.resolve("foo"), .ambiguous(id("a/foo.md"), candidates: [id("a/foo.md"), id("b/foo.md")]))
    }

    // MARK: K-2 path-qualified

    func testK2_pathQualifiedTargetResolvesUniquely() {
        XCTAssertEqual(ambiguous.links.resolve("daily/2026/foo"), .unique(id("daily/2026/foo.md")))
        XCTAssertEqual(
            ambiguous.links.resolve("DAILY/2026/Foo"), .unique(id("daily/2026/foo.md")), "paths fold case too")
        XCTAssertEqual(ambiguous.links.resolve("daily/2027/foo"), .unresolved, "a path names exactly one place")
        XCTAssertEqual(ambiguous.links.resolve("daily/foo"), .unresolved, "a path is not matched by title")
    }

    func testK2_pathQualifiedTargetWorksForUniqueNotesToo() {
        let snapshot = index([("nested/Beta.md", 1, ""), ("Alpha.md", 2, "")])
        XCTAssertEqual(snapshot.links.resolve("nested/Beta"), .unique(id("nested/Beta.md")))
        XCTAssertEqual(snapshot.links.resolve("Beta"), .unique(id("nested/Beta.md")))
    }

    // MARK: K-2 a root note wins its bare path (ADR-0023)

    func testK2_rootNoteWinsBareTitle() {
        let snapshot = index([
            ("foo.md", 2, "the root foo"),
            ("daily/foo.md", 1, "an older nested foo"),
        ])
        XCTAssertEqual(snapshot.links.resolve("foo"), .unique(id("foo.md")))
        XCTAssertEqual(snapshot.links.resolve(" FOO "), .unique(id("foo.md")), "folded and trimmed like any target")
        XCTAssertEqual(snapshot.links.resolve("daily/foo"), .unique(id("daily/foo.md")), "the other needs its path")
    }

    func testK2_rootNoteWinsWhenOtherNewer() {
        let snapshot = index([
            ("foo.md", 1, "the older root foo"),
            ("daily/foo.md", 2, "a newer foo"),
            ("archive/foo.md", 3, "the newest foo"),
        ])
        XCTAssertEqual(snapshot.links.resolve("foo"), .unique(id("foo.md")), "modification times do not matter")

        // Touching the nested notes again changes nothing; removing the root note hands the
        // bare title back to the title rules.
        let touched = snapshot.applying(
            changes: LibraryChanges(modified: [id("daily/foo.md")]), contents: disk(["daily/foo.md": (9, "edited")]))
        XCTAssertEqual(touched.links.resolve("foo"), .unique(id("foo.md")))
        let rootless = touched.applying(changes: LibraryChanges(removed: [id("foo.md")])) { _ in nil }
        XCTAssertEqual(
            rootless.links.resolve("foo"),
            .ambiguous(id("daily/foo.md"), candidates: [id("daily/foo.md"), id("archive/foo.md")]))
    }

    func testK2_noRootNoteFallsBackToNewest() {
        let snapshot = index([
            ("archive/foo.md", 1, "older"),
            ("daily/foo.md", 2, "newer"),
            ("nested/Beta.md", 3, ""),
        ])
        XCTAssertEqual(
            snapshot.links.resolve("foo"),
            .ambiguous(id("daily/foo.md"), candidates: [id("daily/foo.md"), id("archive/foo.md")]))
        XCTAssertEqual(snapshot.links.resolve("Beta"), .unique(id("nested/Beta.md")), "one candidate is unique")
    }

    func testK2_rootNoteLinkNotStyledAmbiguous() {
        // Styling reads `isAmbiguous` (ED-11): a bare title a root note owns is a plain link.
        let snapshot = index([
            ("daily/foo.md", 2, ""),
            ("foo.md", 1, ""),
        ])
        XCTAssertFalse(snapshot.links.resolve("foo").isAmbiguous)
        XCTAssertFalse(snapshot.links.resolve("Foo").isAmbiguous)
    }

    func testK6_backlinksFollowRootResolution() {
        let snapshot = index([
            ("foo.md", 1, "the root foo"),
            ("daily/foo.md", 2, "a newer foo"),
            ("bare.md", 3, "see [[foo]]"),
            ("qualified.md", 4, "see [[daily/foo]]"),
            ("both.md", 5, "see [[Foo]] and [[DAILY/foo]]"),
        ])
        XCTAssertEqual(paths(snapshot.links.backlinks(to: id("foo.md"))), ["both.md", "bare.md"])
        XCTAssertEqual(paths(snapshot.links.backlinks(to: id("daily/foo.md"))), ["both.md", "qualified.md"])
    }

    // MARK: K-1 embeds

    func testK1_embedsAreRecordedButNeverResolveToANote() {
        let snapshot = index([
            ("Alpha.md", 1, "![[Beta]] and ![[diagram.png]]"),
            ("Beta.md", 2, ""),
        ])
        let outgoing = snapshot.links.outgoing(of: id("Alpha.md"))
        XCTAssertEqual(
            outgoing, [LinkTarget(text: "Beta", isEmbed: true), LinkTarget(text: "diagram.png", isEmbed: true)])
        XCTAssertEqual(snapshot.links.resolve(outgoing[0]), .unresolved, "an embed links to a non-note file (L-6)")
        XCTAssertEqual(snapshot.links.resolve("Beta"), .unique(id("Beta.md")), "the title itself still resolves")
        XCTAssertEqual(snapshot.links.backlinks(to: id("Beta.md")), [], "an embed is not a backlink")
    }

    // MARK: K-5 outgoing

    func testK5_outgoingTargetsInOrderOfFirstAppearanceWithoutDuplicates() {
        let snapshot = index([
            ("Alpha.md", 1, "[[Beta]] then [[Gamma|a label]] then [[beta]] and [[ Delta ]]")
        ])
        XCTAssertEqual(
            snapshot.links.outgoing(of: id("Alpha.md")),
            [LinkTarget(text: "Beta"), LinkTarget(text: "Gamma"), LinkTarget(text: "Delta")])
        XCTAssertEqual(snapshot.links.outgoing(of: id("Beta.md")), [], "an unindexed note has no links")
    }

    func testK5_linksInsideCodeAreNotLinks() {
        let snapshot = index([
            ("Alpha.md", 1, "`[[Beta]]` and\n```\n[[Gamma]]\n```\nbut [[Delta]]"),
            ("Beta.md", 2, ""),
        ])
        XCTAssertEqual(snapshot.links.outgoing(of: id("Alpha.md")), [LinkTarget(text: "Delta")])
        XCTAssertEqual(snapshot.links.backlinks(to: id("Beta.md")), [])
    }

    // MARK: K-5 incoming

    func testK5_backlinksFollowResolution() {
        // Bare `[[foo]]` belongs to the newer candidate alone; the path form belongs to the
        // note it names; a note linking both ways is listed once for the nested note.
        XCTAssertEqual(
            paths(ambiguous.links.backlinks(to: id("daily/2026/foo.md"))), ["root-path.md", "qualified.md", "bare.md"])
        XCTAssertEqual(paths(ambiguous.links.backlinks(to: id("notes/foo.md"))), [])
    }

    func testK5_backlinksAreMostRecentlyModifiedFirst() {
        let snapshot = index([
            ("Target.md", 1, ""),
            ("old.md", 2, "[[Target]]"),
            ("new.md", 4, "[[target]]"),
            ("mid.md", 3, "[[Target|see]]"),
            ("unrelated.md", 5, "nothing"),
        ])
        XCTAssertEqual(paths(snapshot.links.backlinks(to: id("Target.md"))), ["new.md", "mid.md", "old.md"])
        XCTAssertEqual(snapshot.links.backlinks(to: id("unrelated.md")), [])
        XCTAssertEqual(snapshot.links.backlinks(to: id("missing.md")), [], "an unindexed note has no backlinks")
    }

    // MARK: K-5 incremental

    func testK5_modifiedNoteMovesItsLinks() {
        let base = index([
            ("Alpha.md", 1, "[[Beta]]"),
            ("Beta.md", 2, ""),
            ("Gamma.md", 3, ""),
        ])
        XCTAssertEqual(paths(base.links.backlinks(to: id("Beta.md"))), ["Alpha.md"])

        let updated = base.applying(
            changes: LibraryChanges(modified: [id("Alpha.md")]),
            contents: disk(["Alpha.md": (4, "now [[Gamma]]")]))
        XCTAssertEqual(updated.links.outgoing(of: id("Alpha.md")), [LinkTarget(text: "Gamma")])
        XCTAssertEqual(paths(updated.links.backlinks(to: id("Beta.md"))), [])
        XCTAssertEqual(paths(updated.links.backlinks(to: id("Gamma.md"))), ["Alpha.md"])
        XCTAssertEqual(paths(base.links.backlinks(to: id("Beta.md"))), ["Alpha.md"], "the old snapshot is unchanged")
    }

    func testK5_removedNoteLeavesNoTraces() {
        let base = ambiguous
        let updated = base.applying(changes: LibraryChanges(removed: [id("daily/2026/foo.md"), id("bare.md")])) { _ in
            nil
        }
        XCTAssertEqual(updated.links.count, 3)
        XCTAssertEqual(
            updated.links.resolve("foo"), .unique(id("notes/foo.md")), "one candidate left: no longer ambiguous")
        XCTAssertEqual(updated.links.resolve("daily/2026/foo"), .unresolved)
        XCTAssertEqual(updated.links.outgoing(of: id("bare.md")), [])
        XCTAssertEqual(
            paths(updated.links.backlinks(to: id("notes/foo.md"))), ["root-path.md"],
            "bare links now belong to the survivor")
    }

    func testK5_addedNoteCanMakeATitleAmbiguous() {
        let base = index([
            ("notes/foo.md", 1, ""),
            ("Alpha.md", 2, "[[foo]]"),
        ])
        XCTAssertEqual(base.links.resolve("foo"), .unique(id("notes/foo.md")))
        XCTAssertEqual(paths(base.links.backlinks(to: id("notes/foo.md"))), ["Alpha.md"])

        let updated = base.applying(
            changes: LibraryChanges(added: [id("daily/foo.md")]),
            contents: disk(["daily/foo.md": (3, "")]))
        XCTAssertEqual(
            updated.links.resolve("foo"),
            .ambiguous(id("daily/foo.md"), candidates: [id("daily/foo.md"), id("notes/foo.md")]))
        XCTAssertEqual(paths(updated.links.backlinks(to: id("daily/foo.md"))), ["Alpha.md"])
        XCTAssertEqual(paths(updated.links.backlinks(to: id("notes/foo.md"))), [])
    }

    func testK5_renameMovesTheNoteUnderItsNewTitle() {
        let base = index([
            ("Alpha.md", 1, "[[Beta]] and [[Gamma]]"),
            ("Beta.md", 2, "[[Alpha]]"),
        ])
        let renamed = base.applying(
            changes: LibraryChanges(added: [id("Gamma.md")], removed: [id("Beta.md")]),
            contents: disk(["Gamma.md": (2, "[[Alpha]]")]))
        XCTAssertEqual(renamed.links.resolve("Beta"), .unresolved)
        XCTAssertEqual(renamed.links.resolve("Gamma"), .unique(id("Gamma.md")))
        XCTAssertEqual(paths(renamed.links.backlinks(to: id("Gamma.md"))), ["Alpha.md"])
        XCTAssertEqual(paths(renamed.links.backlinks(to: id("Alpha.md"))), ["Gamma.md"])
        XCTAssertEqual(renamed.links.outgoing(of: id("Beta.md")), [])
    }

    func testK5_titlesOnlySnapshotResolvesBeforeBodiesAreRead() {
        // The launch snapshot (PF-7) knows every title and path, so links resolve at once;
        // outgoing links and backlinks appear as bodies are folded in.
        let notes = [
            ScannedNote(id: id("Alpha.md"), modifiedAt: at(1)),
            ScannedNote(id: id("daily/foo.md"), modifiedAt: at(2)),
            ScannedNote(id: id("notes/foo.md"), modifiedAt: at(3)),
        ]
        let titles = SearchIndex.titlesOnly(notes)
        XCTAssertEqual(titles.links.count, 3)
        XCTAssertEqual(titles.links.resolve("Alpha"), .unique(id("Alpha.md")))
        XCTAssertEqual(
            titles.links.resolve("foo"),
            .ambiguous(id("notes/foo.md"), candidates: [id("notes/foo.md"), id("daily/foo.md")]))
        XCTAssertEqual(titles.links.resolve("daily/foo"), .unique(id("daily/foo.md")))
        XCTAssertEqual(titles.links.outgoing(of: id("Alpha.md")), [])

        let filled = titles.applying(
            changes: LibraryChanges(modified: [id("Alpha.md")]),
            contents: disk(["Alpha.md": (1, "[[foo]] [[daily/foo]]")]))
        XCTAssertEqual(
            filled.links.outgoing(of: id("Alpha.md")), [LinkTarget(text: "foo"), LinkTarget(text: "daily/foo")])
        XCTAssertEqual(paths(filled.links.backlinks(to: id("notes/foo.md"))), ["Alpha.md"])
        XCTAssertEqual(paths(filled.links.backlinks(to: id("daily/foo.md"))), ["Alpha.md"])
    }

    func testK5_standaloneIndexAppliesUpsertsAndRemovals() {
        let base = LinkIndex.empty.applying(
            upserts: [
                (id("Alpha.md"), at(1), [LinkTarget(text: "Beta")]),
                (id("Beta.md"), at(2), []),
            ], removing: [])
        XCTAssertEqual(base.count, 2)
        XCTAssertEqual(paths(base.links(to: "Beta")), ["Alpha.md"])

        let sameBatch = base.applying(
            upserts: [(id("Beta.md"), at(3), [LinkTarget(text: "Alpha")])], removing: [id("Beta.md")])
        XCTAssertEqual(sameBatch.count, 2, "an id both removed and upserted is upserted")
        XCTAssertEqual(paths(sameBatch.links(to: "Alpha")), ["Beta.md"])
        XCTAssertEqual(LinkIndex.empty.count, 0)
    }
}

extension LinkIndex {
    /// The notes linking to the note `target` resolves to, for tests that speak in targets.
    fileprivate func links(to target: String) -> [NoteID] {
        resolve(target).target.map(backlinks(to:)) ?? []
    }
}
