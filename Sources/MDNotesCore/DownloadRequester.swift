import Foundation
import Synchronization

/// Keeps a download request outstanding for every evicted note in the library (L-9, ADR-0009).
///
/// Given the scanner's note list, asks iCloud to download each note that is dataless, at most
/// once per note per 60 s. The rate limit is per eviction: a note that is seen readable drops
/// its record, so when it is evicted again the request is repeated at once. Notes no longer
/// in the list drop their records too, so the ledger never outgrows the library.
///
/// Probing each note is file I/O. `requestDownloads(for:)` does it synchronously and must be
/// called off the main thread (PF-6); `enqueue(_:)` does it on the requester's own serial
/// queue. The clock and the request itself are injected so tests can drive time and observe
/// requests without an iCloud container. Safe from any thread.
public final class DownloadRequester: Sendable {
    public typealias Clock = @Sendable () -> Date
    public typealias Request = @Sendable (NoteID) -> Void

    /// The least time between two requests for the same note while it stays dataless (L-9).
    public static let minimumInterval: TimeInterval = 60

    private let store: NoteStore
    private let clock: Clock
    private let request: Request
    private let queue = DispatchQueue(label: "MDNotes.DownloadRequester", qos: .utility)
    /// When each dataless note was last requested. A note that is readable, or gone, has no entry.
    private let lastRequested = Mutex<[NoteID: Date]>([:])

    /// - Parameters:
    ///   - store: answers whether a note is dataless and, by default, makes the request.
    ///   - clock: the current time; defaults to `Date()`.
    ///   - request: the download request; defaults to `store.requestDownload(of:)`.
    public init(store: NoteStore, clock: @escaping Clock = { Date() }, request: Request? = nil) {
        self.store = store
        self.clock = clock
        self.request = request ?? { store.requestDownload(of: $0) }
    }

    /// Requests a download for every note in `notes` that is dataless and has not been
    /// requested in the last `minimumInterval`. Returns the ids requested on this pass.
    /// Synchronous file I/O: call off the main thread (PF-6).
    @discardableResult
    public func requestDownloads(for notes: [ScannedNote]) -> [NoteID] {
        let now = clock()
        var dataless: [NoteID] = []
        for note in notes where !store.isAvailable(note.id) {
            dataless.append(note.id)
        }
        let due = lastRequested.withLock { ledger -> [NoteID] in
            var due: [NoteID] = []
            var kept: [NoteID: Date] = [:]
            kept.reserveCapacity(dataless.count)
            for id in dataless {
                if let last = ledger[id], now.timeIntervalSince(last) < DownloadRequester.minimumInterval {
                    kept[id] = last
                } else {
                    kept[id] = now
                    due.append(id)
                }
            }
            ledger = kept
            return due
        }
        for id in due {
            request(id)
        }
        return due
    }

    /// `requestDownloads(for:)` on the requester's own serial queue, so a caller on the main
    /// thread never waits for the probe (PF-6). Passes are made in the order enqueued.
    public func enqueue(_ notes: [ScannedNote], completion: (@Sendable ([NoteID]) -> Void)? = nil) {
        queue.async {
            let requested = self.requestDownloads(for: notes)
            completion?(requested)
        }
    }

    /// How many notes are recorded as dataless and requested.
    public var outstandingCount: Int {
        lastRequested.withLock { $0.count }
    }
}
