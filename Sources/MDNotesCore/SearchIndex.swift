import Darwin
import Foundation

/// An immutable, in-memory snapshot of every note's searchable text (S-2, S-3, S-4, ADR-0003).
///
/// Snapshots are values: build one with `SearchIndex.Builder`, hand it to the main thread, and
/// query it there without locks (PF-6). Titles and bodies are stored case-folded once at build
/// time so a query only lowercases its own words. All folded text lives in one contiguous byte
/// arena, packed in list order, so a query is a single sweep over memory (PF-2, PF-5).
public struct SearchIndex: Sendable {
    /// The packed, case-folded UTF-8 of every indexed note, plus how often each byte value occurs
    /// (used to pick the rarest byte of a query word as its search anchor).
    final class Arena: Sendable {
        let bytes: [UInt8]
        let byteFrequency: [Int]

        init(bytes: [UInt8]) {
            self.bytes = bytes
            var frequency = [Int](repeating: 0, count: 256)
            for byte in bytes { frequency[Int(byte)] += 1 }
            byteFrequency = frequency
        }

        static let empty = Arena(bytes: [])
    }

    /// One indexed note. `title` and `body` are lowercase; the note's display title is `id.title`.
    public struct Entry: Hashable, Sendable {
        public let id: NoteID
        public let modifiedAt: Date
        let titleRange: Range<Int>
        let bodyRange: Range<Int>
        let arena: Arena

        /// The title (L-5), case-folded.
        public var title: String { String(decoding: arena.bytes[titleRange], as: UTF8.self) }

        /// The body text, case-folded. Empty when the file is unreadable (L-7): such a note is
        /// indexed by title only.
        public var body: String { String(decoding: arena.bytes[bodyRange], as: UTF8.self) }

        public static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id && lhs.modifiedAt == rhs.modifiedAt && lhs.title == rhs.title && lhs.body == rhs.body
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(modifiedAt)
        }
    }

    /// The notes matching a query, in list order (S-3). A lightweight view onto the snapshot:
    /// building one records positions only, so a 20k-note result costs no per-entry copying.
    public struct Results: RandomAccessCollection, Sendable {
        public let index: SearchIndex
        let positions: [Int32]

        public var startIndex: Int { 0 }
        public var endIndex: Int { positions.count }
        public subscript(position: Int) -> Entry { index.entries[Int(positions[position])] }
    }

    /// A note's folded text before it is packed into a snapshot.
    struct FoldedNote: Sendable {
        let modifiedAt: Date
        let title: [UInt8]
        let body: [UInt8]

        init(id: NoteID, modifiedAt: Date, body: String) {
            self.modifiedAt = modifiedAt
            title = Array(SearchIndex.fold(id.title).utf8)
            self.body = Array(SearchIndex.fold(body).utf8)
        }
    }

    /// Accumulates notes and produces a snapshot. Adding an id twice keeps the last version.
    public struct Builder: Sendable {
        private var notes: [NoteID: FoldedNote] = [:]

        public init() {}

        /// Number of distinct notes added so far.
        public var count: Int { notes.count }

        /// Adds or replaces a note. The title is taken from `id` (L-5); `body` is the file's text,
        /// or empty for a note whose body cannot be read yet (L-7, L-8).
        public mutating func add(id: NoteID, modifiedAt: Date, body: String = "") {
            notes[id] = FoldedNote(id: id, modifiedAt: modifiedAt, body: body)
        }

        /// Adds notes that were folded elsewhere (for example on a worker thread).
        mutating func add(folded: [(id: NoteID, note: FoldedNote)]) {
            for (id, note) in folded { notes[id] = note }
        }

        /// Freezes the accumulated notes into a snapshot.
        public func build() -> SearchIndex {
            SearchIndex(ordered: notes.map { Item(id: $0.key, note: $0.value) }.sorted(by: SearchIndex.precedesInList))
        }
    }

    /// A snapshot with no notes.
    public static let empty = SearchIndex(ordered: [])

    /// Every note, most recently modified first.
    public let entries: [Entry]

    /// Where each entry's folded text sits in the arena, in `entries` order. A plain-value copy
    /// of the ranges in `Entry` so the query loop never touches reference counts.
    struct Span {
        let titleStart: Int32
        let bodyStart: Int32
        let end: Int32
    }
    let spans: [Span]

    /// A note's folded text about to be packed into a snapshot. The slices borrow their storage,
    /// from a `FoldedNote` or from an older snapshot's arena, so packing copies each byte once.
    struct Item {
        let id: NoteID
        let modifiedAt: Date
        let title: ArraySlice<UInt8>
        let body: ArraySlice<UInt8>

        init(id: NoteID, note: FoldedNote) {
            self.id = id
            modifiedAt = note.modifiedAt
            title = note.title[...]
            body = note.body[...]
        }

        init(entry: Entry) {
            id = entry.id
            modifiedAt = entry.modifiedAt
            title = entry.arena.bytes[entry.titleRange]
            body = entry.arena.bytes[entry.bodyRange]
        }
    }

    /// List order (S-3): most recently modified first, ties broken by path so the order is
    /// deterministic.
    static func precedesInList(_ a: Item, _ b: Item) -> Bool {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
        return a.id.relativePath < b.id.relativePath
    }

    /// Packs `items`, which must already be in list order, into a fresh arena.
    private init(ordered items: [Item]) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(items.reduce(0) { $0 + $1.title.count + $1.body.count })
        var ranges: [(title: Range<Int>, body: Range<Int>)] = []
        ranges.reserveCapacity(items.count)
        for item in items {
            let titleStart = bytes.count
            bytes.append(contentsOf: item.title)
            let bodyStart = bytes.count
            bytes.append(contentsOf: item.body)
            ranges.append((titleStart..<bodyStart, bodyStart..<bytes.count))
        }
        let arena = items.isEmpty ? Arena.empty : Arena(bytes: bytes)
        entries = zip(items, ranges).map { item, range in
            Entry(
                id: item.id, modifiedAt: item.modifiedAt, titleRange: range.title, bodyRange: range.body, arena: arena)
        }
        spans = ranges.map { range in
            Span(
                titleStart: Int32(range.title.lowerBound), bodyStart: Int32(range.body.lowerBound),
                end: Int32(range.body.upperBound))
        }
    }

    /// A new snapshot with `upserts` inserted or replaced and `removing` dropped, without
    /// touching disk. Untouched notes are carried over from this snapshot's arena; the whole
    /// arena is repacked so a query stays a single contiguous sweep (PF-2). An id in both lists
    /// is upserted. Later upserts of the same id win.
    func applying(upserts: [(id: NoteID, note: FoldedNote)], removing: Set<NoteID>) -> SearchIndex {
        var fresh: [NoteID: FoldedNote] = [:]
        for (id, note) in upserts { fresh[id] = note }
        var touched = removing
        for id in fresh.keys { touched.insert(id) }
        if touched.isEmpty { return self }

        let incoming = fresh.map { Item(id: $0.key, note: $0.value) }.sorted(by: SearchIndex.precedesInList)
        var merged: [Item] = []
        merged.reserveCapacity(entries.count + incoming.count)
        var next = incoming.startIndex
        for entry in entries where !touched.contains(entry.id) {
            let kept = Item(entry: entry)
            while next < incoming.endIndex, SearchIndex.precedesInList(incoming[next], kept) {
                merged.append(incoming[next])
                next += 1
            }
            merged.append(kept)
        }
        merged.append(contentsOf: incoming[next...])
        return SearchIndex(ordered: merged)
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
    public func query(_ text: String) -> Results {
        guard let first = entries.first else { return Results(index: self, positions: []) }
        let words = SearchIndex.words(of: text)
        if words.isEmpty { return Results(index: self, positions: (0..<Int32(entries.count)).map { $0 }) }

        let arena = first.arena
        // Search the rarest word first so a non-matching note is rejected as early as possible.
        let needles = words.map { Needle(word: $0, frequency: arena.byteFrequency) }
            .sorted { $0.anchorFrequency < $1.anchorFrequency }

        var titleMatches: [Int32] = []
        var bodyMatches: [Int32] = []
        needles.withUnsafeBufferPointer { needles in
            arena.bytes.withUnsafeBufferPointer { buffer in
                spans.withUnsafeBufferPointer { spans in
                    guard let base = buffer.baseAddress else { return }
                    for position in spans.indices {
                        let span = spans[position]
                        let title = UnsafeBufferPointer(
                            start: base + Int(span.titleStart), count: Int(span.bodyStart - span.titleStart))
                        let body = UnsafeBufferPointer(
                            start: base + Int(span.bodyStart), count: Int(span.end - span.bodyStart))
                        var inTitle = true
                        var inEither = true
                        for needle in needles {
                            if needle.isFound(in: title) { continue }
                            inTitle = false
                            if needle.isFound(in: body) { continue }
                            inEither = false
                            break
                        }
                        if inTitle {
                            titleMatches.append(Int32(position))
                        } else if inEither {
                            bodyMatches.append(Int32(position))
                        }
                    }
                }
            }
        }
        return Results(index: self, positions: titleMatches + bodyMatches)
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

    /// A query word prepared for byte-wise search: `memchr` for its rarest byte, then `memcmp`
    /// the whole word at each candidate. Far faster than `memmem` on prose, where the anchor
    /// byte is missed by the SIMD scan far more often than it is hit.
    final class Needle {
        let length: Int
        /// Offset within the word of the byte that occurs least often in the arena.
        let anchor: Int
        let anchorFrequency: Int
        private let bytes: UnsafeMutablePointer<UInt8>

        init(word: [UInt8], frequency: [Int]) {
            length = word.count
            bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, word.count))
            bytes.initialize(from: word, count: word.count)
            var best = 0
            for (offset, byte) in word.enumerated() where frequency[Int(byte)] < frequency[Int(word[best])] {
                best = offset
            }
            anchor = best
            anchorFrequency = word.isEmpty ? 0 : frequency[Int(word[best])]
        }

        deinit {
            bytes.deallocate()
        }

        @inline(__always)
        func isFound(in haystack: UnsafeBufferPointer<UInt8>) -> Bool {
            if length == 0 { return true }
            guard let hay = haystack.baseAddress, haystack.count >= length else { return false }
            let wanted = Int32(bytes[anchor])
            var cursor = hay + anchor
            var remaining = haystack.count - length + 1
            while remaining > 0 {
                guard let hit = memchr(cursor, wanted, remaining) else { return false }
                let candidate = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self))
                if memcmp(candidate - anchor, bytes, length) == 0 { return true }
                remaining -= candidate - cursor + 1
                cursor = candidate + 1
            }
            return false
        }
    }
}
