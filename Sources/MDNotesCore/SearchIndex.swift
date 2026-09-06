import Darwin
import Foundation

/// An immutable, in-memory snapshot of every note's searchable text (S-2, S-3, S-4, ADR-0003).
///
/// Snapshots are values: build one with `SearchIndex.Builder`, hand it to the main thread, and
/// query it there without locks (PF-6). Titles and bodies are stored case-folded once at build
/// time so a query only lowercases its own words.
public struct SearchIndex: Sendable {
    /// One indexed note. `title` and `body` are lowercase; the note's display title is `id.title`.
    public struct Entry: Hashable, Sendable {
        public let id: NoteID
        public let modifiedAt: Date
        /// The title (L-5), case-folded.
        public let title: String
        /// The body text, case-folded. Empty when the file is unreadable (L-7): such a note is
        /// indexed by title only.
        public let body: String
    }

    /// Accumulates notes and produces a snapshot. Adding an id twice keeps the last version.
    public struct Builder: Sendable {
        private var entries: [NoteID: Entry] = [:]

        public init() {}

        /// Number of distinct notes added so far.
        public var count: Int { entries.count }

        /// Adds or replaces a note. The title is taken from `id` (L-5); `body` is the file's text,
        /// or empty for a note whose body cannot be read yet (L-7, L-8).
        public mutating func add(id: NoteID, modifiedAt: Date, body: String = "") {
            entries[id] = Entry(
                id: id, modifiedAt: modifiedAt, title: SearchIndex.fold(id.title), body: SearchIndex.fold(body))
        }

        /// Freezes the accumulated notes into a snapshot.
        public func build() -> SearchIndex {
            SearchIndex(unsorted: Array(entries.values))
        }
    }

    /// A snapshot with no notes.
    public static let empty = SearchIndex(unsorted: [])

    /// Every note, most recently modified first.
    public let entries: [Entry]

    private init(unsorted: [Entry]) {
        entries = unsorted.sorted(by: SearchIndex.isOrderedBefore)
    }

    /// Number of notes in the snapshot.
    public var count: Int { entries.count }

    /// The entry for `id`, if the note is indexed.
    public func entry(for id: NoteID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Runs a query (S-2, S-3, S-4).
    ///
    /// The text is split on whitespace into words. A note matches when every word is a
    /// case-insensitive substring of its title or its body, in any order. Notes whose title
    /// contains every word come first, then the remaining matches; each group is ordered most
    /// recently modified first. An empty or blank query returns every note by modified date.
    /// `#tag` is an ordinary word: it matches wherever those characters occur.
    public func query(_ text: String) -> [Entry] {
        let words = SearchIndex.words(of: text)
        if words.isEmpty { return entries }

        var titleMatches: [Entry] = []
        var bodyMatches: [Entry] = []
        for entry in entries {
            if words.allSatisfy({ SearchIndex.contains(entry.title, $0) }) {
                titleMatches.append(entry)
            } else if words.allSatisfy({
                SearchIndex.contains(entry.title, $0) || SearchIndex.contains(entry.body, $0)
            }) {
                bodyMatches.append(entry)
            }
        }
        return titleMatches + bodyMatches
    }

    // MARK: - Folding and matching

    /// The case folding applied to indexed text and query words alike.
    static func fold(_ text: String) -> String {
        text.lowercased()
    }

    /// Splits a query into case-folded words on whitespace (S-2), as UTF-8 bytes.
    static func words(of text: String) -> [[UInt8]] {
        fold(text).split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
    }

    /// Byte-wise substring test on the UTF-8 of `haystack`; both sides are already folded.
    static func contains(_ haystack: String, _ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        let found = haystack.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            guard let base = bytes.baseAddress, bytes.count >= needle.count else { return false }
            return needle.withUnsafeBufferPointer { pattern in
                memmem(base, bytes.count, pattern.baseAddress, pattern.count) != nil
            }
        }
        return found ?? (haystack.utf8.firstRange(of: needle) != nil)
    }

    /// Most recently modified first; ties are broken by relative path so the order is stable.
    private static func isOrderedBefore(_ a: Entry, _ b: Entry) -> Bool {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
        return a.id.relativePath < b.id.relativePath
    }
}
