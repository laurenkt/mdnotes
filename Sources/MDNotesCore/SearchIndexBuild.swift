import Foundation
import Synchronization

extension SearchIndex {
    /// Builds a snapshot of every scanned note by reading and folding bodies on all cores
    /// (PF-4). A note whose body cannot be read (evicted, undecodable, or gone) is indexed by
    /// title only (L-7, L-8). Synchronous file I/O: call it off the main thread (PF-6).
    public static func build(notes: [ScannedNote], store: NoteStore) -> SearchIndex {
        var builder = Builder()
        builder.add(folded: fold(notes: notes, store: store))
        return builder.build()
    }

    /// A snapshot indexing `notes` by title only, every body empty: what the list shows while
    /// bodies are still being read (PF-7). Packed straight into list order (S-3) without the
    /// `Builder`'s per-note dictionary or a sort of the packed items, which together cost more
    /// than the directory walk at 20k notes (PF-1). A scan lists each note once, so `notes`
    /// must not repeat an id.
    public static func titlesOnly(_ notes: [ScannedNote]) -> SearchIndex {
        // The order `precedesInList` defines, computed over indices and plain seconds so the
        // sort moves integers rather than reference-counted notes.
        let seconds = notes.map(\.modifiedAt.timeIntervalSinceReferenceDate)
        let order = Array(notes.indices).sorted { a, b in
            if seconds[a] != seconds[b] { return seconds[a] > seconds[b] }
            return notes[a].id.relativePath < notes[b].id.relativePath
        }
        // Every note is filed by title and path so links resolve before bodies are read (K-2);
        // there are no links or tags yet to record.
        return SearchIndex(
            ordered: order.map { position in
                let note = notes[position]
                return Item(id: note.id, note: FoldedNote(id: note.id, modifiedAt: note.modifiedAt, body: ""))
            },
            links: LinkIndex.empty.applying(upserts: notes.map { ($0.id, $0.modifiedAt, []) }, removing: []),
            tags: .empty)
    }

    /// A new snapshot with the bodies of `notes` read from `store` and folded in, replacing any
    /// entry with the same id; modification dates are taken from `notes` as scanned. This is
    /// how a titles-only launch snapshot fills in progressively (PF-7). A body that cannot be
    /// read is indexed by title only (L-7, L-8). Synchronous file I/O: call it off the main
    /// thread (PF-6). This snapshot is unchanged.
    public func applying(reading notes: [ScannedNote], store: NoteStore) -> SearchIndex {
        if notes.isEmpty { return self }
        return applying(upserts: SearchIndex.fold(notes: notes, store: store), removing: [])
    }

    /// Reads and folds the bodies of `notes` on all cores. Order of the result is unspecified.
    /// A body that cannot be read folds to empty (L-7, L-8). Synchronous file I/O (PF-6).
    static func fold(notes: [ScannedNote], store: NoteStore) -> [(id: NoteID, note: FoldedNote)] {
        if notes.isEmpty { return [] }
        let chunkCount = max(1, min(64, notes.count / 128))
        let folded = Mutex<[(id: NoteID, note: FoldedNote)]>([])
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let range = notes.count * chunk / chunkCount..<notes.count * (chunk + 1) / chunkCount
            let out = autoreleasepool {
                var out: [(id: NoteID, note: FoldedNote)] = []
                out.reserveCapacity(range.count)
                for note in notes[range] {
                    let body = (try? store.read(note.id))?.indexedText ?? ""
                    out.append((note.id, FoldedNote(id: note.id, modifiedAt: note.modifiedAt, body: body)))
                }
                return out
            }
            folded.withLock { $0.append(contentsOf: out) }
        }
        return folded.withLock { $0 }
    }
}

extension NoteBody {
    /// The text the search index sees: the body for a valid file, nothing otherwise (L-7, L-8).
    var indexedText: String {
        if case .text(let text) = self { return text }
        return ""
    }
}
