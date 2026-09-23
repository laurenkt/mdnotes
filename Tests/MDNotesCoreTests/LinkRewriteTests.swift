import Foundation
import MDNotesCore
import XCTest

/// The pure half of R-3: which links in which notes a rename must rewrite, and how one body
/// is rewritten.
final class LinkRewriteTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ minutes: Int) -> Date { epoch.addingTimeInterval(Double(minutes) * 60) }

    private func id(_ path: String) -> NoteID { NoteID(relativePath: path) }

    private func links(_ notes: [(path: String, minutes: Int, body: String)]) -> LinkIndex {
        var builder = SearchIndex.Builder()
        for note in notes {
            builder.add(id: id(note.path), modifiedAt: at(note.minutes), body: note.body)
        }
        return builder.build().links
    }

    private let beta = NoteID(relativePath: "daily/Beta.md")
    private let delta = NoteID(relativePath: "daily/Delta.md")

    // MARK: R-3 plan

    func testR3_planNamesEveryOtherNoteWhoseLinkResolvesToTheNote() {
        let index = links([
            ("daily/Beta.md", 1, "me: [[Beta]] links to itself"),
            ("One.md", 2, "see [[Beta]] and [[beta|the note]]"),
            ("Two.md", 3, "by path [[daily/Beta]] and title [[BETA]]"),
            ("nested/Three.md", 4, "[[ Beta ]] with spacing"),
            ("Alpha.md", 5, "unrelated [[Gamma]] and `[[Beta]]` in code"),
            ("Embed.md", 6, "![[Beta]] is an embed, not a link"),
            ("Gamma.md", 7, ""),
        ])
        let plan = LinkRewrite.plan(renaming: beta, to: delta, in: index)
        XCTAssertEqual(
            plan,
            [
                id("One.md"): ["beta": "Delta"],
                id("Two.md"): ["daily/beta": "daily/Delta", "beta": "Delta"],
                id("nested/Three.md"): ["beta": "Delta"],
            ])
        XCTAssertNil(plan[beta], "the renamed note's own links are left to it (R-3 rewrites other notes)")
        XCTAssertNil(plan[id("Alpha.md")], "a link in a code span is not a link")
        XCTAssertNil(plan[id("Embed.md")], "an embed never resolves to a note (K-1)")
    }

    func testR3_planKeepsALinkByPathQualifiedAndALinkByTitleBare() {
        let index = links([
            ("daily/Beta.md", 1, ""),
            ("path.md", 2, "[[daily/Beta]]"),
            ("title.md", 3, "[[Beta]]"),
        ])
        let plan = LinkRewrite.plan(renaming: beta, to: delta, in: index)
        XCTAssertEqual(plan[id("path.md")], ["daily/beta": "daily/Delta"])
        XCTAssertEqual(plan[id("title.md")], ["beta": "Delta"])

        // A note at the root has no folder in its path form.
        let root = links([("Beta.md", 1, ""), ("title.md", 2, "[[Beta]]")])
        XCTAssertEqual(
            LinkRewrite.plan(renaming: id("Beta.md"), to: id("Delta.md"), in: root),
            [id("title.md"): ["beta": "Delta"]])
    }

    func testR3_planLeavesBareLinksThatResolveToAnotherCandidateOfAnAmbiguousTitle() {
        // Two notes titled Beta, neither at the root; the daily one is newer, so a bare
        // [[Beta]] is its (K-2).
        let index = links([
            ("archive/Beta.md", 1, ""),
            ("daily/Beta.md", 2, ""),
            ("bare.md", 3, "[[Beta]]"),
            ("qualified.md", 4, "[[daily/Beta]] and [[Beta]]"),
        ])
        let older = id("archive/Beta.md")
        XCTAssertEqual(
            LinkRewrite.plan(renaming: older, to: id("archive/Omega.md"), in: index), [:],
            "no link resolves to the older Beta, so nothing is rewritten for it")
        XCTAssertEqual(
            LinkRewrite.plan(renaming: beta, to: delta, in: index),
            [
                id("bare.md"): ["beta": "Delta"],
                id("qualified.md"): ["daily/beta": "daily/Delta", "beta": "Delta"],
            ])
    }

    func testR3_planIsEmptyWithNoLinksOrNoRename() {
        let index = links([("daily/Beta.md", 1, ""), ("Alpha.md", 2, "[[Gamma]]")])
        XCTAssertEqual(LinkRewrite.plan(renaming: beta, to: delta, in: index), [:])
        let linked = links([("daily/Beta.md", 1, ""), ("Alpha.md", 2, "[[Beta]]")])
        XCTAssertEqual(LinkRewrite.plan(renaming: beta, to: beta, in: linked), [:])
        XCTAssertEqual(LinkRewrite.plan(renaming: id("Missing.md"), to: delta, in: linked), [:])
    }

    // MARK: R-3 rewriting one body

    func testR3_rewritingReplacesOnlyTheTargetKeepingLabelAndSpacing() {
        let body = "see [[Beta]], [[ Beta | the note ]] and [[daily/Beta|path]]\nend\n"
        let rewritten = LinkRewrite.rewriting(body, replacing: ["beta": "Delta", "daily/beta": "daily/Delta"])
        XCTAssertEqual(rewritten, "see [[Delta]], [[ Delta | the note ]] and [[daily/Delta|path]]\nend\n")
    }

    func testR3_rewritingMatchesTheTargetIgnoringCase() {
        XCTAssertEqual(
            LinkRewrite.rewriting("[[beta]] [[BETA]] [[Beta]]", replacing: ["beta": "Delta"]),
            "[[Delta]] [[Delta]] [[Delta]]")
    }

    func testR3_rewritingLeavesEmbedsCodeAndOtherLinksAlone() {
        let body = "![[Beta]] `[[Beta]]` [[Gamma]]\n```\n[[Beta]]\n```\n[[Beta]]"
        XCTAssertEqual(
            LinkRewrite.rewriting(body, replacing: ["beta": "Delta"]),
            "![[Beta]] `[[Beta]]` [[Gamma]]\n```\n[[Beta]]\n```\n[[Delta]]")
    }

    func testR3_rewritingIsNilWhenNothingChanges() {
        XCTAssertNil(LinkRewrite.rewriting("[[Gamma]] and ![[Beta]]", replacing: ["beta": "Delta"]))
        XCTAssertNil(LinkRewrite.rewriting("[[Beta]]", replacing: [:]))
        XCTAssertNil(LinkRewrite.rewriting("", replacing: ["beta": "Delta"]))
        XCTAssertNil(LinkRewrite.rewriting("[[Delta]]", replacing: ["delta": "Delta"]), "already spelled that way")
    }

    func testR3_rewritingKeepsEverythingElseByteForByte() {
        let body = "\u{FEFF}# Heading\r\n\ttabs and  spaces [[Beta]] émoji 🙂 [[Beta|é]]\r\n"
        let rewritten = LinkRewrite.rewriting(body, replacing: ["beta": "Delta"])
        XCTAssertEqual(rewritten, "\u{FEFF}# Heading\r\n\ttabs and  spaces [[Delta]] émoji 🙂 [[Delta|é]]\r\n")
    }
}
