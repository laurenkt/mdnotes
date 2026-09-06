import Foundation

/// A batch of file-system changes to a library, as the watcher reports them (X-1): note ids
/// that were added, modified, or removed since the last snapshot. A rename is a removal of the
/// old id plus an addition of the new one.
public struct LibraryChanges: Hashable, Sendable {
    public var added: Set<NoteID>
    public var modified: Set<NoteID>
    public var removed: Set<NoteID>

    public init(added: Set<NoteID> = [], modified: Set<NoteID> = [], removed: Set<NoteID> = []) {
        self.added = added
        self.modified = modified
        self.removed = removed
    }

    public var isEmpty: Bool { added.isEmpty && modified.isEmpty && removed.isEmpty }

    /// Ids whose current state on disk decides what happens: added and modified are treated
    /// alike, since a coalesced batch cannot tell a create-then-edit from an edit.
    var reread: Set<NoteID> { added.union(modified) }

    /// Ids dropped without looking at disk. An id that is both removed and re-added (a delete
    /// followed by a recreate within one batch) is reread instead.
    var dropped: Set<NoteID> { removed.subtracting(reread) }
}

extension SearchIndex {
    /// A new snapshot with `changes` folded in, reading only the added and modified notes from
    /// `store` (X-1); nothing else is rescanned. Each reread note's modification date and body
    /// come from the file as it is now: a note that has vanished by then is dropped, and one
    /// whose body cannot be read is indexed by title only (L-7, L-8). Synchronous file I/O:
    /// call it off the main thread (PF-6). This snapshot is unchanged.
    public func applying(changes: LibraryChanges, store: NoteStore) -> SearchIndex {
        if changes.isEmpty { return self }
        var present: [ScannedNote] = []
        var gone = changes.dropped
        for id in changes.reread {
            if let modifiedAt = try? store.modificationDate(of: id) {
                present.append(ScannedNote(id: id, modifiedAt: modifiedAt))
            } else {
                gone.insert(id)
            }
        }
        return applying(upserts: SearchIndex.fold(notes: present, store: store), removing: gone)
    }

    /// The same update with note contents supplied by `contents` instead of disk. It is asked
    /// once per added or modified id and answers the note's current modification date and body,
    /// or nil for a note that no longer exists, which is then dropped.
    public func applying(
        changes: LibraryChanges, contents: (NoteID) -> (modifiedAt: Date, body: String)?
    ) -> SearchIndex {
        if changes.isEmpty { return self }
        var upserts: [(id: NoteID, note: FoldedNote)] = []
        var gone = changes.dropped
        for id in changes.reread {
            if let current = contents(id) {
                upserts.append((id, FoldedNote(id: id, modifiedAt: current.modifiedAt, body: current.body)))
            } else {
                gone.insert(id)
            }
        }
        return applying(upserts: upserts, removing: gone)
    }
}
