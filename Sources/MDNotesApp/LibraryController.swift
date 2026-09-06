import Foundation
import MDNotesCore
import Synchronization

/// Owns one library: its root, the `NoteStore` that reads it, and the `SearchIndex` snapshot the
/// window shows. Scanning, reading and index building all run on a private serial background
/// queue (PF-6); each new snapshot is handed to the main thread, where the list and search read
/// it without locks. Only `snapshot`, `phase` and `onSnapshotChange` change on the main thread.
///
/// Launch is progressive (PF-7): the root is walked once and a titles-only snapshot of every
/// note is published at once, so the list is complete and title-searchable before any body has
/// been read. Bodies are then read in batches, most recently modified first, and each batch
/// publishes a fuller snapshot until `phase` is `.ready`.
@MainActor
public final class LibraryController {
    /// Where the controller is in populating the index.
    public enum Phase: Hashable, Sendable {
        /// `start()` has not been called, or `stop()` has.
        case idle
        /// The root is being walked; no snapshot has been published yet.
        case scanning
        /// Every title is in the snapshot; bodies are being read in batches (PF-7).
        case indexing(bodiesRead: Int, of: Int)
        /// Every readable body is in the snapshot.
        case ready
        /// The root could not be listed. The snapshot is empty.
        case failed(String)
    }

    /// The library root used until Preferences say otherwise (L-1).
    nonisolated public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("MDnotes", isDirectory: true)
    }

    /// Bodies read per batch during the initial population. Each batch repacks the whole
    /// snapshot, so this trades repack count against how soon the first snippets appear.
    nonisolated public static let defaultBatchSize = 2048

    public let root: URL
    public let store: NoteStore

    /// Every write this process has made to the library, for the watcher to ignore (E-6).
    public let ownWrites = OwnWrites()

    /// The latest snapshot. Replaced, never mutated; safe to hold across a reload.
    public private(set) var snapshot: SearchIndex = .empty
    public private(set) var phase: Phase = .idle

    /// Called on the main thread after `snapshot` and `phase` have been replaced.
    public var onSnapshotChange: (@MainActor (SearchIndex) -> Void)?

    private let batchSize: Int
    private let queue = DispatchQueue(label: "MDNotes.LibraryController", qos: .userInitiated)
    private let worker: Worker
    /// Bumped by `start()` and `stop()`; results tagged with an older generation are dropped.
    private var generation = 0

    public init(root: URL, batchSize: Int = LibraryController.defaultBatchSize) {
        precondition(batchSize > 0)
        self.root = root
        self.batchSize = batchSize
        store = NoteStore(root: root)
        worker = Worker()
    }

    // MARK: - Lifecycle

    /// Scans the root and populates the index in the background. Calling it again restarts
    /// from an empty snapshot; results from the earlier run are discarded.
    public func start() {
        generation += 1
        let generation = generation
        snapshot = .empty
        phase = .scanning
        worker.reset(generation: generation)

        let root = root
        queue.async { [self] in
            guard worker.isCurrent(generation) else { return }
            let titlesOnly: SearchIndex
            do {
                titlesOnly = SearchIndex.titlesOnly(try LibraryScanner.scan(root: root))
            } catch {
                publish(.empty, phase: .failed(error.localizedDescription), generation: generation)
                return
            }
            // Bodies are read in list order, most recently modified first, so the rows at the
            // top of the list, the ones on screen at launch, get their snippets first (S-3, PF-7).
            let notes = titlesOnly.entries.map { ScannedNote(id: $0.id, modifiedAt: $0.modifiedAt) }
            let phase: Phase = notes.isEmpty ? .ready : .indexing(bodiesRead: 0, of: notes.count)
            worker.replace(titlesOnly, phase: phase)
            publish(titlesOnly, phase: phase, generation: generation)
            enqueueBatch(of: notes, from: 0, generation: generation)
        }
    }

    /// Discards the index and any work in flight. The snapshot is empty afterwards.
    public func stop() {
        generation += 1
        worker.reset(generation: generation)
        snapshot = .empty
        phase = .idle
    }

    /// Folds file-system changes into the index (X-1), reading only the notes named, and
    /// publishes the result. Safe to call while the initial population is still running: a
    /// batch never overwrites a note that a change has touched since the scan.
    public func apply(_ changes: LibraryChanges) {
        if changes.isEmpty { return }
        let generation = generation
        let store = store
        queue.async { [self] in
            guard worker.isCurrent(generation) else { return }
            let (index, phase, _) = worker.update { state in
                state.touchedSinceScan.formUnion(changes.added)
                state.touchedSinceScan.formUnion(changes.modified)
                state.touchedSinceScan.formUnion(changes.removed)
                state.index = state.index.applying(changes: changes, store: store)
            }
            publish(index, phase: phase, generation: generation)
        }
    }

    // MARK: - Creation (C-2)

    /// Creates the empty file for `id` on the background queue (PF-6), folds the new note
    /// into the snapshot without rereading disk, publishes it, and then calls `completion` on
    /// the main thread. By the time `completion` runs the published snapshot already lists
    /// the note, so the caller can select it at once (C-4). A file that already exists is left
    /// untouched and still reported as a success (C-1 opens it instead). If the library is
    /// stopped or restarted before the write lands, `completion` is never called.
    public func create(_ id: NoteID, completion: @escaping @MainActor (Result<NoteStore.Creation, any Error>) -> Void) {
        let generation = generation
        let store = store
        queue.async { [self] in
            guard worker.isCurrent(generation) else { return }
            let outcome: Result<NoteStore.Creation, any Error>
            do {
                let creation = try store.create(id)
                if creation.created { ownWrites.record(id, modifiedAt: creation.modifiedAt) }
                let changes = LibraryChanges(added: [id])
                let (index, phase, _) = worker.update { state in
                    state.touchedSinceScan.insert(id)
                    if creation.created {
                        // The body is known to be empty; no need to read the file back.
                        state.index = state.index.applying(changes: changes) { _ in
                            (modifiedAt: creation.modifiedAt, body: "")
                        }
                    } else {
                        state.index = state.index.applying(changes: changes, store: store)
                    }
                }
                publish(index, phase: phase, generation: generation)
                outcome = .success(creation)
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else { return }
                    completion(outcome)
                }
            }
        }
    }

    // MARK: - Saving (E-4, E-5, E-6)

    /// Writes `text` over the file backing `id`, atomically (E-5), records the write in
    /// `ownWrites` (E-6), and folds the new body and modification date into the snapshot
    /// without rereading the file. The write happens synchronously on the calling thread, which
    /// must not be the main thread (PF-6), so a caller that reads the note afterwards on the
    /// same queue sees what it wrote; the fold and publish follow on the library's queue.
    /// Returns the file's new modification date. A stopped library still writes the file but
    /// leaves its empty snapshot alone.
    nonisolated public func save(_ text: String, to id: NoteID) throws -> Date {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let modifiedAt = try AtomicWriter().write(text, to: store.url(for: id))
        ownWrites.record(id, modifiedAt: modifiedAt)
        queue.async { [self] in
            let (index, phase, generation) = worker.update { state in
                guard state.phase != .idle else { return }
                state.touchedSinceScan.insert(id)
                state.index = state.index.applying(changes: LibraryChanges(modified: [id])) { _ in
                    (modifiedAt: modifiedAt, body: text)
                }
            }
            if phase != .idle { publish(index, phase: phase, generation: generation) }
        }
        return modifiedAt
    }

    // MARK: - Progressive population (PF-7)

    /// Reads one batch of bodies on the queue, publishes, and queues the next batch. Each batch
    /// is its own queue block so `apply(_:)` can interleave instead of waiting for the whole
    /// population to finish.
    nonisolated private func enqueueBatch(of notes: [ScannedNote], from start: Int, generation: Int) {
        guard start < notes.count else { return }
        let end = min(start + batchSize, notes.count)
        let store = store
        queue.async { [self] in
            guard worker.isCurrent(generation) else { return }
            let (index, phase, _) = worker.update { state in
                let batch = notes[start..<end].filter { !state.touchedSinceScan.contains($0.id) }
                state.index = state.index.applying(reading: batch, store: store)
                state.phase = end < notes.count ? .indexing(bodiesRead: end, of: notes.count) : .ready
            }
            publish(index, phase: phase, generation: generation)
            enqueueBatch(of: notes, from: end, generation: generation)
        }
    }

    // MARK: - Publishing (PF-6)

    /// Hands a snapshot to the main thread. Publishes are queued in order, and one tagged with a
    /// stale generation is dropped there.
    nonisolated private func publish(_ index: SearchIndex, phase: Phase, generation: Int) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.receive(index, phase: phase, generation: generation)
            }
        }
    }

    private func receive(_ index: SearchIndex, phase: Phase, generation: Int) {
        guard generation == self.generation else { return }
        snapshot = index
        self.phase = phase
        onSnapshotChange?(index)
    }

    // MARK: - Background state

    /// The index as the background queue sees it. Every mutation happens on the serial queue,
    /// so the lock never contends; it exists so the state can cross into `@Sendable` blocks.
    private final class Worker: Sendable {
        struct State {
            var generation = 0
            var index: SearchIndex = .empty
            var phase: Phase = .idle
            /// Ids named by `apply(_:)` since the last scan. A population batch skips these,
            /// since the change already indexed them from a fresher read.
            var touchedSinceScan: Set<NoteID> = []
        }

        private let state = Mutex(State())

        func reset(generation: Int) {
            state.withLock { $0 = State(generation: generation) }
        }

        func isCurrent(_ generation: Int) -> Bool {
            state.withLock { $0.generation == generation }
        }

        func replace(_ index: SearchIndex, phase: Phase) {
            state.withLock {
                $0.index = index
                $0.phase = phase
            }
        }

        /// Mutates the state and returns the index and phase to publish, with the generation
        /// they belong to, read under the same lock so a `reset` in between cannot mislabel them.
        func update(_ body: (inout State) -> Void) -> (SearchIndex, Phase, Int) {
            state.withLock {
                body(&$0)
                return ($0.index, $0.phase, $0.generation)
            }
        }
    }
}
