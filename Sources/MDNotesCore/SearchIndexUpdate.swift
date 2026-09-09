import Foundation

/// A batch of file-system changes to a library, as the watcher reports them (X-1): note ids
/// that were added, modified, or removed since the last snapshot, the image files that
/// arrived, changed or went, and the templates that did (TP-7). A rename is a removal of the
/// old id plus an addition of the new one.
public struct LibraryChanges: Hashable, Sendable {
    public var added: Set<NoteID>
    public var modified: Set<NoteID>
    public var removed: Set<NoteID>
    /// Root-relative paths of image files (`ImageStore.isImageFile`) that were added, changed
    /// or removed, whatever else they were before: an image is not a note (L-6), so nothing is
    /// reread or listed for it, but a note whose embed names it is re-resolved (S-11) and a
    /// thumbnail of it on show is refreshed (E-9).
    public var images: Set<String>
    /// Names (`TemplateStore.name(forRelativePath:)`) of templates whose file arrived, changed
    /// or went, whatever else they were before (TP-7). A template is not a note (TP-1): the
    /// index ignores these, and the owner re-lists `templates/` when there are any.
    public var templates: Set<String>

    public init(
        added: Set<NoteID> = [], modified: Set<NoteID> = [], removed: Set<NoteID> = [], images: Set<String> = [],
        templates: Set<String> = []
    ) {
        self.added = added
        self.modified = modified
        self.removed = removed
        self.images = images
        self.templates = templates
    }

    public var isEmpty: Bool { !affectsIndex && templates.isEmpty }

    /// True when the snapshot has anything to fold: a note or an image changed. A batch that
    /// names only templates leaves the index alone.
    public var affectsIndex: Bool { !(added.isEmpty && modified.isEmpty && removed.isEmpty && images.isEmpty) }

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
    /// whose body cannot be read is indexed by title only (L-7, L-8). The notes whose embeds
    /// name one of `changes.images` have their first image resolved again against the store's
    /// root without being reread (S-11). Synchronous file I/O: call it off the main thread
    /// (PF-6). This snapshot is unchanged.
    public func applying(changes: LibraryChanges, store: NoteStore) -> SearchIndex {
        if !changes.affectsIndex { return self }
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
            .applying(imageChanges: changes.images, images: ImageStore(root: store.root))
    }

    /// The same update with note contents supplied by `contents` instead of disk. It is asked
    /// once per added or modified id and answers the note's current modification date and body,
    /// or nil for a note that no longer exists, which is then dropped. With `images`, each
    /// body's first embedded image is resolved against the library (S-11), and the notes whose
    /// embeds name one of `changes.images` are re-resolved; that stats files: call it off the
    /// main thread then (PF-6). Without it, `changes.images` is ignored.
    public func applying(
        changes: LibraryChanges, images: ImageStore? = nil,
        contents: (NoteID) -> (modifiedAt: Date, body: String)?
    ) -> SearchIndex {
        if !changes.affectsIndex { return self }
        var upserts: [(id: NoteID, note: FoldedNote)] = []
        var gone = changes.dropped
        for id in changes.reread {
            if let current = contents(id) {
                upserts.append(
                    (id, FoldedNote(id: id, modifiedAt: current.modifiedAt, body: current.body, images: images)))
            } else {
                gone.insert(id)
            }
        }
        let updated = applying(upserts: upserts, removing: gone)
        guard let images else { return updated }
        return updated.applying(imageChanges: changes.images, images: images)
    }

    /// A new snapshot in which every note with an embed that `images` would look for at one
    /// of `paths`, root-relative image files that arrived, changed or went (X-1), has its first
    /// image resolved again (S-11): a note whose embed now names a file on disk gains the
    /// path, one whose image is gone falls back to its next embed or to none. The embeds come
    /// from the link index, so no note is reread; a note whose body has not been read yet has
    /// none and is left alone, as is every note not embedding one of the paths. Stats the
    /// affected notes' embeds: call it off the main thread (PF-6). This snapshot is returned
    /// unchanged when no note's image changes.
    public func applying(imageChanges paths: Set<String>, images: ImageStore) -> SearchIndex {
        if paths.isEmpty || entries.isEmpty { return self }
        var items: [Item] = []
        items.reserveCapacity(entries.count)
        var changed = false
        for entry in entries {
            let outgoing = links.outgoing(of: entry.id)
            let affected = outgoing.contains { link in
                link.isEmbed && ImageStore.candidatePaths(forEmbed: link.text).contains(where: paths.contains)
            }
            guard affected else {
                items.append(Item(entry: entry))
                continue
            }
            let resolved = images.firstImage(in: outgoing)
            if resolved != entry.firstImagePath { changed = true }
            items.append(Item(entry: entry, firstImage: resolved))
        }
        return changed ? SearchIndex(ordered: items, links: links, tags: tags) : self
    }
}
