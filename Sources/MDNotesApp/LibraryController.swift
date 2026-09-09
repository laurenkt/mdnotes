import AppKit
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
///
/// Once the root has been walked an `FSEventsWatcher` covers it (X-1). Every batch it reports
/// is first stripped of the echoes of this controller's own writes (E-6): an added or modified
/// note whose file carries exactly the modification date `save` or `create` recorded in
/// `ownWrites` was written by us and is not reread, and a removed note that `delete` moved to
/// the Trash, or that `rename` gave another name, is not reported. What remains is external,
/// is folded into the snapshot like `apply(_:)` does, and is then reported through
/// `onExternalChanges`.
///
/// The templates (TP-1) are listed by name once the root has been walked and again after
/// every batch that names one, so `templateNames` follows `templates/` on disk the way the
/// snapshot follows the notes (TP-7). A template is never in the snapshot.
///
/// Evicted notes are asked for without anyone opening them (L-9, ADR-0009): after the scan
/// `start()` makes, which is also the full rescan a restart makes, and after every watcher
/// batch, `downloadRequester` runs one pass over every note in the library on its own queue
/// and requests a download for each that is dataless, rate-limited per note.
///
/// Every pass leaves behind how many notes are dataless, and while that is more than none
/// the requester re-probes just those notes every `evictionRefreshInterval` (L-10), so a
/// download that lands is noticed within 2 s without a watcher event: the count drops, the
/// note's body is read into the snapshot as an external modification (L-7), and once nothing
/// is dataless the polling stops. The count and, while it is more than none, the boot
/// volume's free space are published together as `evictionStatus` for the window's bar.
@MainActor
public final class LibraryController {
    /// What the eviction bar shows (L-10): how many notes are dataless as of the last requester
    /// pass, and the boot volume's free space in bytes, read on the same pass, or nil when
    /// nothing is dataless or the volume did not say.
    public struct EvictionStatus: Hashable, Sendable {
        public let datalessCount: Int
        public let freeBytes: Int64?

        public init(datalessCount: Int, freeBytes: Int64?) {
            self.datalessCount = datalessCount
            self.freeBytes = freeBytes
        }

        /// Nothing dataless: the state before the first pass and after the last download lands.
        public static let none = EvictionStatus(datalessCount: 0, freeBytes: nil)
    }

    /// Answers the boot volume's free space in bytes, or nil when it cannot be read.
    public typealias FreeSpaceProbe = @Sendable () -> Int64?

    /// How often the requester re-probes the dataless notes while there are any (L-10). Half
    /// the 2 s the bar has to disappear after the last download lands, leaving the other half
    /// for the probe and the hop to the main thread.
    nonisolated public static let evictionRefreshInterval: TimeInterval = 1

    /// The default `FreeSpaceProbe`: what the boot volume can spare for the user's own files,
    /// `volumeAvailableCapacityForImportantUsage` of `/`, which counts purgeable space as free
    /// the way Storage Settings does. File I/O; the requester's queue calls it (PF-6).
    nonisolated public static let bootVolumeFreeSpace: FreeSpaceProbe = {
        autoreleasepool {
            let values = try? URL(fileURLWithPath: "/", isDirectory: true)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
    }
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

    /// Keeps a download request outstanding for every dataless note (L-9). Its passes run on
    /// its own queue, so neither the scan nor the watcher waits for the probe.
    public let downloadRequester: DownloadRequester

    /// The latest snapshot. Replaced, never mutated; safe to hold across a reload.
    public private(set) var snapshot: SearchIndex = .empty
    public private(set) var phase: Phase = .idle

    /// Called on the main thread after `snapshot` and `phase` have been replaced.
    public var onSnapshotChange: (@MainActor (SearchIndex) -> Void)?

    /// Called on the main thread with each batch of file-system changes that were not this
    /// process's own writes (E-6, X-1), after the snapshot reflecting them has been published.
    /// Never called for an autosave, a `create` or a `delete` of ours. Also called with a
    /// modification for each dataless note the eviction poll finds readable (L-7, L-10), and
    /// with the image files that arrived, changed or went, ours included, in `images` (S-11),
    /// and the templates that did in `templates` (TP-7).
    public var onExternalChanges: (@MainActor (LibraryChanges) -> Void)?

    /// The `templates/` folder under the root (TP-1). Reads disk: use it off the main thread.
    public let templates: TemplateStore

    /// The templates by name, as `TemplateStore.names()` last listed them (TP-1): listed on
    /// the background queue when `start()` has walked the root, and again after every batch,
    /// the watcher's or `apply(_:)`'s, that names a template (TP-7). Empty before that and
    /// after `stop()`. Replaced on the main thread.
    public private(set) var templateNames: [String] = []

    /// Called on the main thread after `templateNames` has been replaced, once per listing:
    /// after a batch that only changed a template's contents too, with the same names, since
    /// what the template would create may have changed (TP-2, TP-5).
    public var onTemplateNamesChange: (@MainActor ([String]) -> Void)?

    /// How many notes are dataless, with the boot volume's free space while any are (L-10).
    /// Replaced on the main thread after each requester pass whose findings differ; `.none`
    /// before the first pass of a `start()` and after `stop()`.
    public private(set) var evictionStatus: EvictionStatus = .none

    /// Called on the main thread after `evictionStatus` has been replaced.
    public var onEvictionStatusChange: (@MainActor (EvictionStatus) -> Void)?

    private let batchSize: Int
    nonisolated private let freeSpace: FreeSpaceProbe
    /// True while a re-probe of the dataless notes is due, so passes that overlap, a watcher
    /// batch during the poll, say, do not each start their own.
    private var evictionRefreshPending = false
    private let watchesFileSystem: Bool
    private let queue = DispatchQueue(label: "MDNotes.LibraryController", qos: .userInitiated)
    /// Serialises this controller's writes with the watcher's check of them, so an event can
    /// never be judged before the write that caused it is on record in `ownWrites` (E-6).
    private let writes = DispatchQueue(label: "MDNotes.LibraryController.writes", qos: .userInitiated)
    private let worker: Worker
    /// The watcher for the current `start()`, set on the background queue once the scan is done.
    private let watcher = Mutex<FSEventsWatcher?>(nil)
    /// Bumped by `start()` and `stop()`; results tagged with an older generation are dropped.
    private var generation = 0
    /// Where one-line reports of the library's doings go (R-3). Called from any thread.
    nonisolated private let log: @Sendable (String) -> Void

    /// The default `log`: one line on stderr, prefixed like every other message of the app.
    nonisolated public static let standardErrorLog: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data("MDNotes: \(line)\n".utf8))
    }

    /// - Parameters:
    ///   - root: the library root (L-1).
    ///   - batchSize: bodies read per batch during the initial population (PF-7).
    ///   - watchesFileSystem: whether `start()` also watches the root for changes (X-1). Tests
    ///     that feed changes through `apply(_:)` by hand turn it off so the real watcher does not
    ///     report the same changes a second time.
    ///   - log: takes each line the library reports, such as the count of notes whose links
    ///     a rename rewrote (R-3). The default writes it to stderr; tests capture it.
    ///   - availability: the `NoteStore` probe that says whether a note is dataless (L-7). The
    ///     default asks the file; tests inject one to simulate eviction, which cannot be
    ///     fabricated outside an iCloud container.
    ///   - requestDownload: what `downloadRequester` calls for each dataless note (L-9). The
    ///     default asks iCloud through the store; tests inject one to observe the requests.
    ///   - freeSpace: answers the boot volume's free space for `evictionStatus` (L-10). The
    ///     default asks the volume; tests inject one to fill or empty the disk.
    public init(
        root: URL, batchSize: Int = LibraryController.defaultBatchSize, watchesFileSystem: Bool = true,
        log: @escaping @Sendable (String) -> Void = LibraryController.standardErrorLog,
        availability: NoteStore.AvailabilityProbe? = nil, requestDownload: DownloadRequester.Request? = nil,
        freeSpace: @escaping FreeSpaceProbe = LibraryController.bootVolumeFreeSpace
    ) {
        precondition(batchSize > 0)
        self.root = root
        self.batchSize = batchSize
        self.watchesFileSystem = watchesFileSystem
        self.log = log
        self.freeSpace = freeSpace
        let store = availability.map { NoteStore(root: root, isAvailable: $0) } ?? NoteStore(root: root)
        self.store = store
        templates = TemplateStore(root: root)
        downloadRequester = DownloadRequester(store: store, request: requestDownload)
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
        stopWatching()
        resetEvictionStatus()
        resetTemplateNames()

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
            // The stream is live before the titles are published, so a change made while the
            // bodies are still being read is not lost (X-1). The templates are listed after it
            // for the same reason (TP-7).
            if watchesFileSystem {
                startWatching(knownNotes: Set(titlesOnly.entries.map(\.id)), generation: generation)
            }
            // Bodies are read in list order, most recently modified first, so the rows at the
            // top of the list, the ones on screen at launch, get their snippets first (S-3, PF-7).
            let notes = titlesOnly.entries.map { ScannedNote(id: $0.id, modifiedAt: $0.modifiedAt) }
            let phase: Phase = notes.isEmpty ? .ready : .indexing(bodiesRead: 0, of: notes.count)
            worker.replace(titlesOnly, phase: phase)
            publish(titlesOnly, phase: phase, generation: generation)
            listTemplates(generation: generation)
            requestDownloads(for: notes, generation: generation)
            enqueueBatch(of: notes, from: 0, generation: generation)
        }
    }

    /// Discards the index and any work in flight. The snapshot is empty afterwards.
    public func stop() {
        generation += 1
        worker.reset(generation: generation)
        snapshot = .empty
        phase = .idle
        stopWatching()
        resetEvictionStatus()
        resetTemplateNames()
    }

    /// Folds file-system changes into the index (X-1), reading only the notes named, and
    /// publishes the result; a batch that names a template has `templates/` listed again and
    /// `templateNames` published (TP-7). Safe to call while the initial population is still
    /// running: a batch never overwrites a note that a change has touched since the scan.
    public func apply(_ changes: LibraryChanges) {
        fold(changes, generation: generation)
    }

    /// `apply(_:)` for any thread, with the generation the changes belong to. Returns without
    /// queueing anything when there is nothing to fold or the generation is stale. The snapshot
    /// is touched, and published, only when a note or an image changed.
    nonisolated private func fold(
        _ changes: LibraryChanges, generation: Int, then completion: (@Sendable () -> Void)? = nil
    ) {
        if changes.isEmpty { return }
        let store = store
        queue.async { [self] in
            guard worker.isCurrent(generation) else { return }
            if changes.affectsIndex {
                let (index, phase, _) = worker.update { state in
                    state.touchedSinceScan.formUnion(changes.added)
                    state.touchedSinceScan.formUnion(changes.modified)
                    state.touchedSinceScan.formUnion(changes.removed)
                    state.index = state.index.applying(changes: changes, store: store)
                }
                publish(index, phase: phase, generation: generation)
            }
            if !changes.templates.isEmpty { listTemplates(generation: generation) }
            completion?()
        }
    }

    // MARK: - Templates (TP-1, TP-7)

    /// Lists `templates/` on the calling queue and hands the names to the main thread, where
    /// they are published unless `generation` is stale by then. A folder that cannot be listed
    /// is reported on the log and leaves the names as they were.
    nonisolated private func listTemplates(generation: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        let names: [String]
        do {
            names = try templates.names()
        } catch {
            log("could not list \(templates.directory.path): \(error)")
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard generation == self.generation else { return }
                self.publishTemplateNames(names)
            }
        }
    }

    private func publishTemplateNames(_ names: [String]) {
        templateNames = names
        onTemplateNamesChange?(names)
    }

    /// `start()` and `stop()`: no templates are known until the next listing says otherwise.
    private func resetTemplateNames() {
        guard !templateNames.isEmpty else { return }
        publishTemplateNames([])
    }

    // MARK: - Watching (X-1, E-6)

    /// True while a watcher started by `start()` is running. Exposed for tests.
    public var isWatching: Bool {
        watcher.withLock { $0?.isRunning ?? false }
    }

    /// Starts a watcher over the root on the background queue. A watcher that cannot be started
    /// is reported on stderr and the library goes on without one: everything else still works,
    /// only external changes go unnoticed until the next `start()`.
    nonisolated private func startWatching(knownNotes: Set<NoteID>, generation: Int) {
        // Weak: the watcher lives as long as the controller, so a strong capture here would be
        // a cycle that kept both alive after the last outside reference was dropped. The strong
        // reference taken for the call is handed to the main queue afterwards, so if it turns
        // out to be the last one the controller, and the watcher it owns, are released there
        // and not inside the watcher's own callback, where stopping it would deadlock.
        let watcher = FSEventsWatcher(root: root, knownNotes: knownNotes) { [weak self] changes in
            guard let self else { return }
            watcherDidReport(changes, generation: generation)
            DispatchQueue.main.async { withExtendedLifetime(self) {} }
        }
        do {
            try watcher.start()
        } catch {
            FileHandle.standardError.write(Data("MDNotes: not watching \(root.path): \(error)\n".utf8))
            return
        }
        let superseded = self.watcher.withLock { current -> FSEventsWatcher? in
            defer { current = watcher }
            return current
        }
        superseded?.stop()
    }

    /// Stops the current watcher, off the main thread: stopping waits for a callback in flight,
    /// which may be reading the disk.
    private func stopWatching() {
        guard
            let watcher = watcher.withLock({ current -> FSEventsWatcher? in
                defer { current = nil }
                return current
            })
        else { return }
        queue.async { watcher.stop() }
    }

    /// The watcher's handler, on its queue. Drops the echoes of our own writes (E-6), folds
    /// the rest into the snapshot (X-1) and, once that snapshot has been published, hands the
    /// external changes to `onExternalChanges` on the main thread.
    nonisolated private func watcherDidReport(_ changes: LibraryChanges, generation: Int) {
        guard worker.isCurrent(generation) else { return }
        let external = writes.sync { ownWrites.suppressing(changes, store: store) }
        if external.isEmpty {
            requestDownloads(forIndexedNotes: generation)
            return
        }
        foldExternal(external, generation: generation) {
            self.requestDownloads(forIndexedNotes: generation)
        }
    }

    /// Folds changes that were not ours into the snapshot (X-1) and, once that snapshot has
    /// been published, hands them to `onExternalChanges` on the main thread. `then` runs on
    /// the queue after the fold, before the hop.
    nonisolated private func foldExternal(
        _ external: LibraryChanges, generation: Int, then: (@Sendable () -> Void)? = nil
    ) {
        fold(external, generation: generation) {
            then?()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else { return }
                    self.onExternalChanges?(external)
                }
            }
        }
    }

    // MARK: - Proactive download (L-9) and the eviction count (L-10)

    /// One requester pass over `notes`, on the requester's queue, unless `generation` is stale.
    /// What the pass leaves dataless becomes the eviction status.
    nonisolated private func requestDownloads(for notes: [ScannedNote], generation: Int) {
        guard worker.isCurrent(generation) else { return }
        downloadRequester.enqueue(notes) { _ in
            self.evictionPassDidFinish(becameReadable: [], generation: generation)
        }
    }

    /// A requester pass has ended, on its queue: `downloadRequester.outstandingCount` is the
    /// dataless count it found. The boot volume's free space is read here too, off the main
    /// thread, while anything is dataless. A note the pass found readable again is read into
    /// the snapshot as an external modification (L-7), which reloads it in the editor if it
    /// is open there (X-2). The status then goes to the main thread, where it is published
    /// if it differs and, while anything is dataless, the next re-probe is scheduled.
    nonisolated private func evictionPassDidFinish(becameReadable: [NoteID], generation: Int) {
        guard worker.isCurrent(generation) else { return }
        let count = downloadRequester.outstandingCount
        let status = EvictionStatus(datalessCount: count, freeBytes: count > 0 ? freeSpace() : nil)
        if !becameReadable.isEmpty {
            foldExternal(LibraryChanges(modified: Set(becameReadable)), generation: generation)
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard generation == self.generation else { return }
                self.publishEvictionStatus(status)
                if count > 0 { self.scheduleEvictionRefresh(generation: generation) }
            }
        }
    }

    private func publishEvictionStatus(_ status: EvictionStatus) {
        guard status != evictionStatus else { return }
        evictionStatus = status
        onEvictionStatusChange?(status)
    }

    /// `start()` and `stop()`: nothing is known to be dataless until the next pass says so.
    private func resetEvictionStatus() {
        publishEvictionStatus(.none)
    }

    /// Re-probes the dataless notes `evictionRefreshInterval` from now, unless a re-probe is
    /// already due. A `start()` or `stop()` in between makes the timer a no-op.
    private func scheduleEvictionRefresh(generation: Int) {
        guard !evictionRefreshPending else { return }
        evictionRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.evictionRefreshInterval) {
            MainActor.assumeIsolated {
                self.evictionRefreshPending = false
                guard generation == self.generation else { return }
                self.downloadRequester.enqueueRefresh { refresh in
                    self.evictionPassDidFinish(becameReadable: refresh.becameReadable, generation: generation)
                }
            }
        }
    }

    /// One requester pass over every note the background index lists right now. A watcher
    /// batch calls it after its fold, so a note the batch added is probed too and one it
    /// removed drops out of the requester's ledger.
    nonisolated private func requestDownloads(forIndexedNotes generation: Int) {
        let notes = worker.index().entries.map { ScannedNote(id: $0.id, modifiedAt: $0.modifiedAt) }
        requestDownloads(for: notes, generation: generation)
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
                let creation = try writes.sync {
                    let creation = try store.create(id)
                    if creation.created { ownWrites.record(id, modifiedAt: creation.modifiedAt) }
                    return creation
                }
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

    // MARK: - Deletion (D-1, D-2)

    /// Moves the file backing `id` to the macOS Trash through `NSWorkspace.recycle` (D-1). The
    /// move runs asynchronously; once it has landed the note is dropped from the snapshot without
    /// waiting for the watcher (D-2), the result is published, and then `completion` runs on the
    /// main thread with the file's new location in the Trash. By the time it runs the published
    /// snapshot no longer lists the note. The removal is recorded in `ownWrites` first, so the
    /// watcher's report of it, which may arrive before the completion handler, is recognised as
    /// ours and not reported as external (E-6). If the move fails the record is dropped, the
    /// snapshot is left alone, and `completion` gets the error. If the library is stopped or
    /// restarted before the move lands, `completion` is never called.
    public func delete(_ id: NoteID, completion: @escaping @MainActor (Result<URL, any Error>) -> Void) {
        let generation = generation
        let url = store.url(for: id)
        ownWrites.recordRemoval(id)
        // Called on the queue that made the call: the main one.
        NSWorkspace.shared.recycle([url]) { [self] trashed, error in
            let outcome: Result<URL, any Error>
            if let trashedURL = trashed[url] {
                outcome = .success(trashedURL)
            } else {
                ownWrites.forget(id)
                outcome = .failure(error ?? CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]))
            }
            queue.async { [self] in
                guard worker.isCurrent(generation) else { return }
                if case .success = outcome {
                    let (index, phase, _) = worker.update { state in
                        state.touchedSinceScan.insert(id)
                        state.index = state.index.applying(changes: LibraryChanges(removed: [id])) { _ in nil }
                    }
                    publish(index, phase: phase, generation: generation)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard generation == self.generation else { return }
                        completion(outcome)
                    }
                }
            }
        }
    }

    // MARK: - Rename (R-2, R-3, D-2)

    /// Renames the file backing `id` to `newID`'s path on the background queue (PF-6), never
    /// over another file (R-2), then rewrites the links to it in other notes (R-3). Once the
    /// rename has landed the note moves to its new id in the snapshot without waiting for the
    /// watcher (D-2): the old id is dropped and the new one indexed from the file, and the
    /// result is published before `completion` runs on the main thread with the file's
    /// modification date, which a rename leaves unchanged. The rename is recorded in
    /// `ownWrites` as a removal of the old id and a write of the new one, so the watcher's
    /// report of it is recognised as ours (E-6). A failure leaves the snapshot alone and hands
    /// `completion` the error; a collision is `CocoaError.fileWriteFileExists`. If the library
    /// is stopped or restarted before the rename lands, `completion` is never called.
    ///
    /// R-3: every other note with a wikilink that resolved to `id` in the index as it stood
    /// before the rename (`LinkRewrite.plan`) is read from disk, its links to the note are
    /// rewritten to the new title, or the new path where the link was by path, and the file is
    /// written back atomically (E-5) and recorded as ours (E-6). A note whose file no longer
    /// holds such a link, or cannot be written back (L-7, L-8), is left as it is; a write that
    /// fails is logged and the rest go on. Files that were not affected are never opened. The
    /// rewritten bodies join the snapshot in the same publish as the rename, and one line
    /// naming the rename and the count of notes rewritten goes to `log` when there were any.
    public func rename(
        _ id: NoteID, to newID: NoteID, completion: @escaping @MainActor (Result<Date, any Error>) -> Void
    ) {
        let generation = generation
        let store = store
        queue.async { [self] in
            guard worker.isCurrent(generation) else { return }
            let outcome: Result<Date, any Error>
            do {
                let plan = LinkRewrite.plan(renaming: id, to: newID, in: worker.index().links)
                let (modifiedAt, rewritten) = try writes.sync {
                    let modifiedAt = try store.rename(id, to: newID)
                    if id != newID {
                        ownWrites.recordRemoval(id)
                        ownWrites.record(newID, modifiedAt: modifiedAt)
                    }
                    return (modifiedAt, rewriteLinks(plan, from: id, to: newID))
                }
                if id != newID {
                    let changes = LibraryChanges(added: [newID], removed: [id])
                    let (index, phase, _) = worker.update { state in
                        state.touchedSinceScan.insert(id)
                        state.touchedSinceScan.insert(newID)
                        state.touchedSinceScan.formUnion(rewritten.keys)
                        state.index = state.index.applying(changes: changes, store: store)
                        state.index = state.index.applying(
                            changes: LibraryChanges(modified: Set(rewritten.keys)), images: ImageStore(root: root)
                        ) { rewritten[$0] }
                    }
                    publish(index, phase: phase, generation: generation)
                }
                outcome = .success(modifiedAt)
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

    /// Applies a `LinkRewrite.plan` to the files it names (R-3): each is read, rewritten and,
    /// when a link changed, written back atomically and recorded in `ownWrites`. Returns the
    /// new modification date and body of every note written, for the snapshot. Must run on
    /// the `writes` queue, after the rename it follows.
    nonisolated private func rewriteLinks(
        _ plan: [NoteID: LinkRewrite.Replacements], from id: NoteID, to newID: NoteID
    ) -> [NoteID: (modifiedAt: Date, body: String)] {
        dispatchPrecondition(condition: .onQueue(writes))
        if plan.isEmpty { return [:] }
        var written: [NoteID: (modifiedAt: Date, body: String)] = [:]
        for (source, replacements) in plan.sorted(by: { $0.key.relativePath < $1.key.relativePath }) {
            do {
                guard case .text(let body) = try store.read(source),
                    let rewritten = LinkRewrite.rewriting(body, replacing: replacements)
                else { continue }
                let modifiedAt = try AtomicWriter().write(rewritten, to: store.url(for: source))
                ownWrites.record(source, modifiedAt: modifiedAt)
                written[source] = (modifiedAt, rewritten)
            } catch {
                log("could not rewrite links to \(id) in \(source): \(error)")
            }
        }
        if !written.isEmpty {
            let notes = written.count == 1 ? "1 note" : "\(written.count) notes"
            log("renamed \(id) to \(newID): rewrote links in \(notes)")
        }
        return written
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
        let modifiedAt = try writes.sync {
            let modifiedAt = try AtomicWriter().write(text, to: store.url(for: id))
            ownWrites.record(id, modifiedAt: modifiedAt)
            return modifiedAt
        }
        queue.async { [self] in
            let (index, phase, generation) = worker.update { state in
                guard state.phase != .idle else { return }
                state.touchedSinceScan.insert(id)
                state.index = state.index.applying(
                    changes: LibraryChanges(modified: [id]), images: ImageStore(root: root)
                ) { _ in (modifiedAt: modifiedAt, body: text) }
            }
            if phase != .idle { publish(index, phase: phase, generation: generation) }
        }
        return modifiedAt
    }

    // MARK: - Images (I-1, I-2)

    /// Stores an image pasted or dropped into the editor under `i/` at the root (I-1), on the
    /// background queue (PF-6): the source is read or converted (`ImageSource.encoded()`),
    /// written atomically as `<yyyyMMdd-HHmmss>.<ext>` by `ImageStore`, and `completion` runs on
    /// the main thread with the file's name, for the editor to embed, or the error. An image is
    /// not a note (L-6): the snapshot is untouched here; the watcher reports the file by path
    /// in `LibraryChanges.images`, which re-resolves the notes whose embeds name it, none yet
    /// for a fresh name, and leaves a thumbnail already made from the same file as it is. If
    /// the library is stopped or restarted before the write lands, nothing is written and
    /// `completion` is never called.
    public func storeImage(_ source: ImageSource, completion: @escaping @MainActor (Result<String, any Error>) -> Void)
    {
        let generation = generation
        let store = ImageStore(root: root)
        queue.async { [self] in
            guard worker.isCurrent(generation) else { return }
            let outcome = Result {
                let encoded = try source.encoded()
                return try writes.sync { try store.write(encoded.bytes, extension: encoded.fileExtension) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else { return }
                    completion(outcome)
                }
            }
        }
    }

    /// Finds the file the embed `![[target]]` names (I-2) on the background queue (PF-6), as
    /// `ImageStore.url(forEmbed:)` looks for it, and hands it to `completion` on the main thread,
    /// or nil when there is no such file. If the library is stopped or restarted first,
    /// `completion` is never called.
    public func locateEmbed(_ target: String, completion: @escaping @MainActor (URL?) -> Void) {
        let generation = generation
        let store = ImageStore(root: root)
        queue.async { [self] in
            guard worker.isCurrent(generation) else { return }
            let url = store.url(forEmbed: target)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else { return }
                    completion(url)
                }
            }
        }
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

        /// The index as the queue last left it.
        func index() -> SearchIndex {
            state.withLock { $0.index }
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
