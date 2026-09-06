import Foundation

/// Maps tags to the notes that carry them and notes to their tags (T-2). Built and updated
/// alongside `LinkIndex` from the same `NoteReferences` (K-5): an immutable value, replaced on
/// every change by `applying(upserts:removing:)`, which touches only the notes named.
///
/// Tags compare case-insensitively (`CaseFolding`): `#Swift` and `#swift` are one tag. The
/// index remembers how each tag is spelled in the notes so completion (T-3) can offer the
/// spelling the library actually uses: the most common one, the alphabetically first on a tie.
public struct TagIndex: Sendable {
    /// One tag: the notes carrying it and how often each spelling of it occurs, one count per
    /// note that uses that spelling.
    struct Entry: Sendable {
        var notes: Set<NoteID> = []
        var spellings: [String: Int] = [:]

        var isEmpty: Bool { notes.isEmpty }

        /// The spelling shown for this tag.
        var displayName: String {
            var best: (name: String, count: Int)?
            for (name, count) in spellings where count > 0 {
                if let current = best, current.count > count || (current.count == count && current.name < name) {
                    continue
                }
                best = (name, count)
            }
            return best?.name ?? ""
        }
    }

    /// A note's tags as written, distinct spellings, in order of first appearance.
    private var byNote: [NoteID: [String]] = [:]
    /// Folded tag name to its entry.
    private var byTag: [String: Entry] = [:]

    /// An index with no tags.
    public init() {}

    public static let empty = TagIndex()

    /// Number of distinct tags, ignoring case.
    public var count: Int { byTag.count }

    // MARK: - Reading (T-2)

    /// The tags in `id` as written there, without the `#`, in order of first appearance; empty
    /// for a note that is not indexed or has none.
    public func tags(in id: NoteID) -> [String] {
        byNote[id] ?? []
    }

    /// The notes carrying `tag`, in any spelling and with or without a leading `#`, sorted by
    /// path. Empty when no note has it.
    public func notes(tagged tag: String) -> [NoteID] {
        guard let entry = byTag[TagIndex.key(of: tag)] else { return [] }
        return entry.notes.sorted { $0.relativePath < $1.relativePath }
    }

    /// Every known tag, one display spelling each, sorted case-insensitively (T-3).
    public var allTags: [String] {
        byTag.sorted { $0.key < $1.key }.map(\.value.displayName)
    }

    /// The key a tag is filed under: folded, without a leading `#`.
    static func key(of tag: String) -> String {
        CaseFolding.fold(tag.hasPrefix("#") ? tag.dropFirst() : tag[...])
    }

    // MARK: - Updating (T-2)

    /// A new index with `upserts` inserted or replaced and `removing` dropped. An id in both is
    /// upserted; later upserts of the same id win. Only the notes named are touched.
    public func applying(upserts: [(id: NoteID, tags: [String])], removing: Set<NoteID>) -> TagIndex {
        if upserts.isEmpty && removing.isEmpty { return self }
        var next = self
        for id in removing { next.remove(id) }
        for upsert in upserts {
            next.remove(upsert.id)
            next.insert(upsert.id, tags: upsert.tags)
        }
        return next
    }

    private mutating func insert(_ id: NoteID, tags: [String]) {
        var distinct: [String] = []
        var seen: Set<String> = []
        for tag in tags where seen.insert(tag).inserted { distinct.append(tag) }
        // A note is listed under a tag once however it spells it; each spelling counts once.
        byNote[id] = distinct
        for tag in distinct {
            var entry = byTag[TagIndex.key(of: tag), default: Entry()]
            entry.notes.insert(id)
            entry.spellings[tag, default: 0] += 1
            byTag[TagIndex.key(of: tag)] = entry
        }
    }

    private mutating func remove(_ id: NoteID) {
        guard let tags = byNote.removeValue(forKey: id) else { return }
        for tag in tags {
            let key = TagIndex.key(of: tag)
            guard var entry = byTag[key] else { continue }
            entry.notes.remove(id)
            if let count = entry.spellings[tag] {
                if count <= 1 { entry.spellings.removeValue(forKey: tag) } else { entry.spellings[tag] = count - 1 }
            }
            if entry.isEmpty { byTag.removeValue(forKey: key) } else { byTag[key] = entry }
        }
    }
}
