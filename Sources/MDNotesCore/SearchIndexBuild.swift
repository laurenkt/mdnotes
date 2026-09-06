import Foundation
import Synchronization

extension SearchIndex {
    /// Builds a snapshot of every scanned note by reading and folding bodies on all cores
    /// (PF-4). A note whose body cannot be read (evicted, undecodable, or gone) is indexed by
    /// title only (L-7, L-8). Synchronous file I/O: call it off the main thread (PF-6).
    public static func build(notes: [ScannedNote], store: NoteStore) -> SearchIndex {
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
        var builder = Builder()
        builder.add(folded: folded.withLock { $0 })
        return builder.build()
    }
}

extension NoteBody {
    /// The text the search index sees: the body for a valid file, nothing otherwise (L-7, L-8).
    var indexedText: String {
        if case .text(let text) = self { return text }
        return ""
    }
}
