import Foundation
import Synchronization

/// The writes this process has made to the library, kept so the file-system watcher can tell
/// them from external changes and ignore them (E-6).
///
/// Each write is recorded as the note's id and the modification date the write left on the
/// file (E-5). A watcher event for that id whose file still carries that date is the echo of
/// our own write. A later write to the same note replaces the record, so the ledger never
/// grows past the number of notes written this session. Safe from any thread.
public final class OwnWrites: Sendable {
    private let dates = Mutex<[NoteID: Date]>([:])

    public init() {}

    /// Records that this process wrote `id`, leaving it with modification date `modifiedAt`.
    public func record(_ id: NoteID, modifiedAt: Date) {
        dates.withLock { $0[id] = modifiedAt }
    }

    /// True if the last write this process made to `id` left it with exactly `modifiedAt`.
    public func contains(_ id: NoteID, modifiedAt: Date) -> Bool {
        dates.withLock { $0[id] == modifiedAt }
    }

    /// The modification date of the last write recorded for `id`, or nil if this process has
    /// not written it.
    public func lastWrite(of id: NoteID) -> Date? {
        dates.withLock { $0[id] }
    }

    /// Drops the record for `id`, for a watcher that has matched its event.
    public func forget(_ id: NoteID) {
        dates.withLock { $0[id] = nil }
    }

    /// How many notes have a recorded write.
    public var count: Int {
        dates.withLock { $0.count }
    }
}
