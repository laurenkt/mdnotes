import Foundation
import Synchronization

/// The writes this process has made to the library, kept so the file-system watcher can tell
/// them from external changes and ignore them (E-6).
///
/// Each write is recorded as the note's id and the modification date the write left on the
/// file (E-5). A watcher event for that id whose file still carries that date is the echo of
/// our own write. A later write to the same note replaces the record, so the ledger never
/// grows past the number of notes written this session. Safe from any thread.
///
/// A removal this process made (a note moved to the Trash, D-1) is recorded too: a watcher
/// event saying that note was removed, while its file is indeed gone, is our echo. A note that
/// is back on disk afterwards is someone else's doing, and its removal record goes with it.
///
/// The record is kept after its event has been matched: FSEvents may deliver the echo of one
/// write in more than one callback, and every one of them must be recognised. It goes away
/// when the next write to the same note replaces it.
public final class OwnWrites: Sendable {
    /// The last thing this process did to a note's file.
    private enum Entry: Hashable {
        case wrote(modifiedAt: Date)
        case removed
    }

    private let entries = Mutex<[NoteID: Entry]>([:])

    public init() {}

    /// Records that this process wrote `id`, leaving it with modification date `modifiedAt`.
    public func record(_ id: NoteID, modifiedAt: Date) {
        entries.withLock { $0[id] = .wrote(modifiedAt: modifiedAt) }
    }

    /// Records that this process removed `id`'s file from the library (D-1).
    public func recordRemoval(_ id: NoteID) {
        entries.withLock { $0[id] = .removed }
    }

    /// True if the last write this process made to `id` left it with exactly `modifiedAt`.
    public func contains(_ id: NoteID, modifiedAt: Date) -> Bool {
        entries.withLock { $0[id] == .wrote(modifiedAt: modifiedAt) }
    }

    /// The modification date of the last write recorded for `id`, or nil if this process has
    /// not written it, or has removed it since.
    public func lastWrite(of id: NoteID) -> Date? {
        entries.withLock {
            if case .wrote(let modifiedAt) = $0[id] { return modifiedAt }
            return nil
        }
    }

    /// True if the last thing this process did to `id`'s file was remove it.
    public func removed(_ id: NoteID) -> Bool {
        entries.withLock { $0[id] == .removed }
    }

    /// Drops the record for `id`, for a watcher that has matched its event.
    public func forget(_ id: NoteID) {
        entries.withLock { $0[id] = nil }
    }

    /// How many notes have a recorded write or removal.
    public var count: Int {
        entries.withLock { $0.count }
    }

    // MARK: - Suppression (E-6)

    /// `changes` with the echoes of this process's own writes taken out: an added or modified
    /// id whose file now carries exactly the modification date recorded for it was last
    /// written by us, and is dropped. An id with no record, a different date on disk, or no
    /// file at all is someone else's change and stays. A removed id we recorded removing, whose
    /// file is still gone, is our echo and is dropped too; every other removal stays. An id
    /// recorded as removed that has turned up on disk again was recreated by someone else: the
    /// change stays and the record is dropped, so its next removal is reported. `modificationDate`
    /// reads the file, so call this off the main thread (PF-6).
    public func suppressing(
        _ changes: LibraryChanges, modificationDate: (NoteID) throws -> Date
    ) -> LibraryChanges {
        if changes.isEmpty || count == 0 { return changes }
        var external = changes
        for id in changes.added.union(changes.modified) {
            if removed(id) {
                if (try? modificationDate(id)) != nil { forget(id) }
                continue
            }
            guard let recorded = lastWrite(of: id), let onDisk = try? modificationDate(id), onDisk == recorded
            else { continue }
            external.added.remove(id)
            external.modified.remove(id)
        }
        for id in changes.removed where removed(id) && (try? modificationDate(id)) == nil {
            external.removed.remove(id)
        }
        return external
    }

    /// `suppressing(_:modificationDate:)` reading dates from `store`.
    public func suppressing(_ changes: LibraryChanges, store: NoteStore) -> LibraryChanges {
        suppressing(changes) { try store.modificationDate(of: $0) }
    }
}
