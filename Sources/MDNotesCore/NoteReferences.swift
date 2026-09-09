import Foundation

/// The target of one wikilink in a note, as the link index records it (K-1, K-5).
public struct LinkTarget: Hashable, Sendable {
    /// The target as written between the brackets, trimmed of whitespace: a title, or a
    /// `/`-separated path relative to the root without the `.md` extension (K-1, L-4).
    public let text: String
    /// True for `![[target]]`, which links to a non-note file and never resolves to a note
    /// (K-1, L-6).
    public let isEmbed: Bool

    public init(text: String, isEmbed: Bool = false) {
        self.text = text
        self.isEmbed = isEmbed
    }

    /// The case-folded text, which is what resolution compares against titles and paths (K-2).
    public var key: String { CaseFolding.fold(text) }
}

/// What the link and tag indexes take from one note's body (K-5, T-2): its outgoing wikilink
/// targets and its tags, each found with `MarkdownScanner` so a `[[link]]` or `#tag` inside a
/// code span or fenced block is not one (T-1). Computed once per body read, alongside the
/// search text, so a body is never scanned twice.
public struct NoteReferences: Hashable, Sendable {
    /// Outgoing targets in order of first appearance. Two links to the same target, ignoring
    /// case, are listed once; a link and an embed of the same text are distinct.
    public let links: [LinkTarget]
    /// Tags as written, without the `#`, in order of first appearance, each spelling once.
    public let tags: [String]

    /// No links, no tags: an empty or unreadable body (L-7, L-8).
    public static let none = NoteReferences(links: [], tags: [])

    public init(links: [LinkTarget], tags: [String]) {
        self.links = links
        self.tags = tags
    }

    /// Scans `body` for wikilinks (K-1) and tags (T-1).
    public init(scanning body: String) {
        if body.isEmpty {
            self = .none
            return
        }
        let text = body as NSString
        var links: [LinkTarget] = []
        var seenLinks: Set<LinkTarget> = []
        var tags: [String] = []
        var seenTags: Set<String> = []
        for token in MarkdownScanner.scan(body) {
            switch token.kind {
            case .wikilink(let target, _, let isEmbed):
                let link = LinkTarget(text: text.substring(with: target), isEmbed: isEmbed)
                if seenLinks.insert(LinkTarget(text: link.key, isEmbed: isEmbed)).inserted { links.append(link) }
            case .tag(let name):
                let tag = text.substring(with: name)
                if seenTags.insert(tag).inserted { tags.append(tag) }
            case .heading, .inlineCode, .fencedCode, .emphasis, .link, .autolink, .bareURL, .listItem, .taskBox,
                .blockquote, .tableRow, .tableSeparator, .thematicBreak:
                break
            }
        }
        self.links = links
        self.tags = tags
    }
}
