import Foundation
import Synchronization

/// Keeps a download request outstanding for every evicted note in the library (L-9, ADR-0009).
///
/// Given the scanner's note list, asks iCloud to download each note that is dataless, at most
/// once per note per 60 s. The rate limit is per eviction: a note that is seen readable drops
/// its record, so when it is evicted again the request is repeated at once. Notes no longer
/// in the list drop their records too, so the ledger never outgrows the library.
///
/// The ledger doubles as the count of dataless notes for the eviction bar (L-10):
/// `outstandingCount` is how many notes the last pass found dataless, and
/// `refreshOutstanding()` re-probes just those, so the count can follow downloads as they
/// land without walking the whole library.
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

    /// What one `refreshOutstanding()` pass found.
    public struct Refresh: Hashable, Sendable {
        /// Notes that were recorded as dataless and are readable now, dropped from the ledger.
        public let becameReadable: [NoteID]
        /// Notes still dataless after the pass: `outstandingCount` as the pass left it.
        public let datalessCount: Int

        public init(becameReadable: [NoteID], datalessCount: Int) {
            self.becameReadable = becameReadable
            self.datalessCount = datalessCount
        }
    }

    /// Requests a download for every note in `notes` that is dataless and has not been
    /// requested in the last `minimumInterval`. Returns the ids requested on this pass.
    /// Synchronous file I/O: call off the main thread (PF-6).
    @discardableResult
    public func requestDownloads(for notes: [ScannedNote]) -> [NoteID] {
        requestDownloads(forIDs: notes.map(\.id))
    }

    /// Probes only the notes recorded as dataless (L-10): one that is readable now drops out
    /// of the ledger, one still dataless is requested again once `minimumInterval` has passed
    /// (L-9). Cheap for any library size, since a readable note has no record. Synchronous
    /// file I/O: call off the main thread (PF-6).
    public func refreshOutstanding() -> Refresh {
        let recorded = lastRequested.withLock { Array($0.keys) }
        requestDownloads(forIDs: recorded)
        let still = lastRequested.withLock { $0 }
        let readable = recorded.filter { still[$0] == nil }
        return Refresh(becameReadable: readable, datalessCount: still.count)
    }

    @discardableResult
    private func requestDownloads(forIDs ids: [NoteID]) -> [NoteID] {
        let now = clock()
        var dataless: [NoteID] = []
        for id in ids where !store.isAvailable(id) {
            dataless.append(id)
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

    /// `refreshOutstanding()` on the requester's own serial queue, after any pass enqueued
    /// before it (PF-6).
    public func enqueueRefresh(completion: @escaping @Sendable (Refresh) -> Void) {
        queue.async {
            completion(self.refreshOutstanding())
        }
    }

    /// How many notes are recorded as dataless and requested.
    public var outstandingCount: Int {
        lastRequested.withLock { $0.count }
    }
}
