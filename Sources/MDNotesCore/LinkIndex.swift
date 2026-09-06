import Foundation

/// Maps each note to its outgoing wikilink targets and each target to the notes that link to it
/// (K-5), and resolves a target to a note (K-2, ADR-0005).
///
/// An immutable value, like `SearchIndex`: it is built alongside the search snapshot and
/// replaced, never mutated, so the main thread reads it without locks (PF-6). `applying(upserts:removing:)`
/// produces the next value by touching only the notes named, so a save or a watcher batch costs
/// the changed notes, not the library (K-5).
///
/// Notes are keyed two ways for resolution: by case-folded title (L-5), with every note that
/// shares the title as a candidate, and by case-folded path without extension (L-4). Incoming
/// links are keyed by the folded target text as written, because which note a text resolves to
/// depends on the whole library and changes when a note is added or renamed: `backlinks(to:)`
/// resolves at query time, so it is always consistent with `resolve(_:)`.
public struct LinkIndex: Sendable {
    /// What a link target names (K-2).
    public enum Resolution: Hashable, Sendable {
        /// Exactly one note has the title, or the path names a note.
        case unique(NoteID)
        /// Several notes share the bare title. The link opens the most recently modified one
        /// and is styled as ambiguous; `candidates` lists every note with the title, most
        /// recently modified first.
        case ambiguous(NoteID, candidates: [NoteID])
        /// No note has the title or path. Opening the link creates one (K-3).
        case unresolved

        /// The note the link opens, if any.
        public var target: NoteID? {
            switch self {
            case .unique(let id), .ambiguous(let id, _): return id
            case .unresolved: return nil
            }
        }

        public var isAmbiguous: Bool {
            if case .ambiguous = self { return true }
            return false
        }
    }

    /// One indexed note.
    struct Record: Sendable {
        let modifiedAt: Date
        /// The folded title (L-5).
        let title: String
        /// The folded path without extension (L-4); equals `title` for a note at the root.
        let path: String
        let links: [LinkTarget]
    }

    private var records: [NoteID: Record] = [:]
    /// Folded title to every note with that title.
    private var byTitle: [String: Set<NoteID>] = [:]
    /// Folded path without extension to the one note at that path.
    private var byPath: [String: NoteID] = [:]
    /// Folded target text of a link (not an embed) to the notes containing such a link.
    private var incoming: [String: Set<NoteID>] = [:]

    /// An index with no notes.
    public init() {}

    public static let empty = LinkIndex()

    /// Number of indexed notes.
    public var count: Int { records.count }

    /// The key a note's path is filed under: `NoteCreation.queryForm(of:)`, folded.
    static func pathKey(of id: NoteID) -> String { CaseFolding.fold(NoteCreation.queryForm(of: id)) }

    // MARK: - Reading (K-2, K-5)

    /// The targets of every wikilink and embed in `id`, in order of first appearance; empty for
    /// a note that is not indexed or has no links.
    public func outgoing(of id: NoteID) -> [LinkTarget] {
        records[id]?.links ?? []
    }

    /// The note `target` names (K-2). `target` is the text between the brackets: leading and
    /// trailing whitespace is ignored and the comparison is case-insensitive. A target with a
    /// `/` is a path relative to the root without extension (K-1, L-4) and names the one note
    /// at that path. Any other target is a title: it is unique when one note has it, and when
    /// several do it resolves to the most recently modified of them and is flagged ambiguous.
    public func resolve(_ target: String) -> Resolution {
        let key = CaseFolding.fold(target.trimmingCharacters(in: .whitespacesAndNewlines))
        if key.isEmpty { return .unresolved }
        if key.contains("/") {
            return byPath[key].map(Resolution.unique) ?? .unresolved
        }
        guard let candidates = byTitle[key], let only = candidates.first else { return .unresolved }
        if candidates.count == 1 { return .unique(only) }
        let ordered = candidates.sorted(by: precedesInList)
        return .ambiguous(ordered[0], candidates: ordered)
    }

    /// The note `target` names, or nil for an embed, which links to a non-note file (K-1, L-6).
    public func resolve(_ target: LinkTarget) -> Resolution {
        target.isEmbed ? .unresolved : resolve(target.text)
    }

    /// The notes with a wikilink that resolves to `id` (K-5, K-6), most recently modified first.
    /// A link by title counts only when the title resolves to `id`: when the title is ambiguous,
    /// bare links belong to the most recently modified candidate alone (K-2). A link by path
    /// always counts. A note linking to itself is its own backlink.
    public func backlinks(to id: NoteID) -> [NoteID] {
        guard let record = records[id] else { return [] }
        var sources: Set<NoteID> = []
        if let byTitle = incoming[record.title], resolve(record.title).target == id {
            sources.formUnion(byTitle)
        }
        if record.path != record.title, let byPath = incoming[record.path] {
            sources.formUnion(byPath)
        }
        return sources.sorted(by: precedesInList)
    }

    /// List order (S-3) over indexed notes: most recently modified first, then by path.
    private func precedesInList(_ a: NoteID, _ b: NoteID) -> Bool {
        let first = records[a]?.modifiedAt.timeIntervalSinceReferenceDate ?? -.infinity
        let second = records[b]?.modifiedAt.timeIntervalSinceReferenceDate ?? -.infinity
        if first != second { return first > second }
        return a.relativePath < b.relativePath
    }

    // MARK: - Updating (K-5)

    /// A new index with `upserts` inserted or replaced and `removing` dropped. An id in both is
    /// upserted; later upserts of the same id win. Only the notes named are touched.
    public func applying(
        upserts: [(id: NoteID, modifiedAt: Date, links: [LinkTarget])], removing: Set<NoteID>
    ) -> LinkIndex {
        if upserts.isEmpty && removing.isEmpty { return self }
        var next = self
        // A full build arrives as one batch of upserts (PF-4): size the tables once up front.
        let capacity = records.count + upserts.count
        next.records.reserveCapacity(capacity)
        next.byTitle.reserveCapacity(capacity)
        next.byPath.reserveCapacity(capacity)
        for id in removing { next.remove(id) }
        for upsert in upserts {
            next.remove(upsert.id)
            next.insert(upsert.id, modifiedAt: upsert.modifiedAt, links: upsert.links)
        }
        return next
    }

    private mutating func insert(_ id: NoteID, modifiedAt: Date, links: [LinkTarget]) {
        let record = Record(
            modifiedAt: modifiedAt, title: CaseFolding.fold(id.title), path: LinkIndex.pathKey(of: id), links: links)
        records[id] = record
        byTitle[record.title, default: []].insert(id)
        byPath[record.path] = id
        for link in links where !link.isEmbed {
            incoming[link.key, default: []].insert(id)
        }
    }

    private mutating func remove(_ id: NoteID) {
        guard let record = records.removeValue(forKey: id) else { return }
        if var notes = byTitle[record.title] {
            notes.remove(id)
            if notes.isEmpty { byTitle.removeValue(forKey: record.title) } else { byTitle[record.title] = notes }
        }
        if byPath[record.path] == id { byPath.removeValue(forKey: record.path) }
        for link in record.links where !link.isEmbed {
            guard var sources = incoming[link.key] else { continue }
            sources.remove(id)
            if sources.isEmpty { incoming.removeValue(forKey: link.key) } else { incoming[link.key] = sources }
        }
    }
}
