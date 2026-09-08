import Foundation
import Synchronization

/// Watches a library root with FSEvents and reports what changed as note ids (X-1).
///
/// The stream is created with file-level events and a short latency, so the kernel coalesces a
/// burst of changes into one callback; the watcher then folds that callback into one
/// `LibraryChanges`, deciding each path's kind from what is on disk when the callback runs
/// rather than from the event flags, which are cumulative and unreliable across a coalesced
/// window. A `.md` file that exists is `added` if the watcher has not seen it and `modified` if
/// it has; one that is gone is `removed`. A rename therefore arrives as a removal of the old id
/// plus an addition of the new one, and a folder rename or removal as the same for every note
/// under it. A dropped-events flag rescans the whole root and diffs it against the known notes.
///
/// A scan judges the disk as it is when the callback runs, which can be ahead of the stream: a
/// note written after the folder event but before the callback is on disk for the scan, and its
/// own event is still queued. The watcher remembers the modification date each scan saw, and a
/// later event for a note whose date is unchanged since is that echo and is not reported again,
/// so the note is read once and an open note is not reloaded twice (X-2, I-5). A note edited
/// after the scan has a new date and is reported as modified like any other.
///
/// Paths a full scan would skip (L-3, L-6) are ignored. The handler runs on a private serial
/// queue, never the main thread (PF-6), with a non-empty batch per callback. Own writes are
/// not filtered here; that is `OwnWrites` (E-6). Safe to start and stop from any thread, but
/// not from inside the handler. The last reference may be dropped from anywhere, the handler
/// included: `deinit` stops the stream, and never runs on the watcher's own queue.
///
/// The stream does not refer to the watcher directly. Its `info` pointer is a `StreamContext`
/// the stream itself retains, holding the watcher weakly, so a callback that arrives while or
/// after the watcher deinitialises finds nothing and returns. A callback that does find the
/// watcher takes one reference of its own and hands that reference to a global queue to be
/// released, and never releases it on the watcher's queue; that hand-off is what keeps `deinit`,
/// and so `stop()`'s drain of the queue, off the queue being drained (I-2).
public final class FSEventsWatcher: Sendable {
    /// How long the kernel may hold events to coalesce them before delivery. The first event
    /// after a quiet period is delivered without waiting, so a single change arrives well within
    /// the X-1 budget.
    public static let defaultLatency: TimeInterval = 0.1

    public typealias Handler = @Sendable (LibraryChanges) -> Void

    public let root: URL

    private struct State {
        var stream: Int = 0
        var known: Set<NoteID> = []
        /// Notes a scan reported, with the modification date it saw, until their own event
        /// arrives or they are reported again.
        var scanned: [NoteID: Date] = [:]
    }

    private let state: Mutex<State>
    private let scanOnStart: Bool
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "MDNotes.FSEventsWatcher", qos: .utility)
    /// The root as FSEvents reports it: symlinks resolved, no trailing slash.
    private let rootPath: String

    /// - Parameters:
    ///   - root: the library root (L-1).
    ///   - knownNotes: the notes currently in the library, so a folder that vanishes can be
    ///     reported note by note. Pass the scanner's result, or nil to have `start()` walk the
    ///     root itself.
    ///   - latency: see `defaultLatency`.
    ///   - handler: receives each non-empty batch, on a background queue.
    public init(
        root: URL, knownNotes: Set<NoteID>? = nil, latency: TimeInterval = FSEventsWatcher.defaultLatency,
        handler: @escaping Handler
    ) {
        self.root = root
        self.rootPath = FSEventsWatcher.canonicalPath(root.path)
        self.scanOnStart = knownNotes == nil
        self.state = Mutex(State(known: knownNotes ?? []))
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// True between `start()` and `stop()`.
    public var isRunning: Bool {
        state.withLock { $0.stream != 0 }
    }

    /// The notes the watcher believes are in the library: the initial set plus every change it
    /// has reported. Exposed for tests.
    public var knownNotes: Set<NoteID> {
        state.withLock { $0.known }
    }

    /// Begins delivering changes that happen from now on. Throws if the stream cannot be created
    /// or started. Calling it while running does nothing.
    ///
    /// When no `knownNotes` were given, the root is walked here, synchronously, after the stream
    /// is live, so nothing slips between the walk and the first event; call it off the main
    /// thread in that case (PF-6). A note created during the walk is reported as modified rather
    /// than added, which the index treats alike. FSEvents may also replay a change made just
    /// before `start()` as the stream's first event; it is judged against the disk like any other.
    public func start() throws {
        try state.withLock { state in
            if state.stream != 0 { return }
            // The stream owns the context: created at +1 here, released by `release` when the
            // stream is deallocated after `stop()`.
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passRetained(StreamContext(self)).toOpaque(), retain: nil,
                release: { info in
                    guard let info else { return }
                    Unmanaged<StreamContext>.fromOpaque(info).release()
                },
                copyDescription: nil)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard
                let stream = FSEventStreamCreate(
                    nil, FSEventsWatcher.callback, &context, [rootPath] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else { throw WatchError.streamCreationFailed(rootPath) }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                throw WatchError.streamStartFailed(rootPath)
            }
            state.stream = Int(bitPattern: UnsafeRawPointer(stream))
        }
        if scanOnStart {
            let scanned = (try? LibraryScanner.scan(root: root)) ?? []
            state.withLock { $0.known.formUnion(scanned.map(\.id)) }
        }
    }

    /// Stops delivery. No callback runs after this returns. Calling it while stopped does nothing.
    public func stop() {
        let stream: FSEventStreamRef? = state.withLock { state in
            defer { state.stream = 0 }
            guard let raw = UnsafeRawPointer(bitPattern: state.stream) else { return nil }
            return OpaquePointer(raw)
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        // Drain a callback that may already be running, so none runs after this returns and the
        // stream's context outlives every use of it.
        queue.sync {}
        FSEventStreamRelease(stream)
    }

    public enum WatchError: Error, Equatable {
        case streamCreationFailed(String)
        case streamStartFailed(String)
    }

    // MARK: - Event handling

    /// What the stream's `info` pointer refers to. Retained by the stream, not the watcher, and
    /// holding the watcher weakly, so the stream never refers to a watcher that is going away.
    private final class StreamContext: Sendable {
        private struct Weak: Sendable {
            weak var watcher: FSEventsWatcher?
        }
        private let weak: Weak

        init(_ watcher: FSEventsWatcher) {
            weak = Weak(watcher: watcher)
        }

        /// A reference of the caller's own, at +1, or nil once the watcher's `deinit` has begun.
        func retainWatcher() -> Unmanaged<FSEventsWatcher>? {
            guard let watcher = weak.watcher else { return nil }
            return Unmanaged.passRetained(watcher)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info, let retained = Unmanaged<StreamContext>.fromOpaque(info).takeUnretainedValue().retainWatcher()
        else { return }
        // If the owner lets go of the watcher while this callback runs, the reference taken above
        // is the last one, and whichever release brings the count to zero runs `deinit`, and so
        // `stop()`, which waits for this queue to drain: a deadlock libdispatch traps on if it
        // happens here. So this queue never releases it. `retainWatcher()` let its own strong
        // reference go before returning, and the one below is balanced within the statement;
        // neither can be last while the +1 is outstanding, and that +1 is released on a global
        // queue after the work is done, from a closure that owns it outright rather than sharing
        // it with a local this queue would release afterwards.
        let cStrings = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        var events: [(path: String, flags: FSEventStreamEventFlags)] = []
        events.reserveCapacity(count)
        for i in 0..<count {
            guard let cString = cStrings[i] else { continue }
            events.append((String(cString: cString), flags[i]))
        }
        retained.takeUnretainedValue().handle(events)
        DispatchQueue.global(qos: .utility).async { retained.release() }
    }

    private func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        // Only this queue changes `known` and `scanned`, so reading them before the disk work
        // and writing after is consistent, and the lock is not held across file I/O.
        let (known, scanned) = state.withLock { ($0.known, $0.scanned) }
        let (changes, stillScanned) = fold(events, known: known, scanned: scanned)
        state.withLock { state in
            state.known.formUnion(changes.added)
            state.known.formUnion(changes.modified)
            state.known.subtract(changes.removed)
            state.scanned = stillScanned
        }
        if changes.isEmpty { return }
        handler(changes)
    }

    /// One batch of events as `LibraryChanges`, judged against `known` and the disk as it is now,
    /// plus the scan-reported notes still awaiting their own event: `scanned` less those this
    /// batch settled, plus those this batch's scans reported.
    private func fold(
        _ events: [(path: String, flags: FSEventStreamEventFlags)], known: Set<NoteID>, scanned: [NoteID: Date]
    ) -> (LibraryChanges, [NoteID: Date]) {
        var changes = LibraryChanges()
        var scanned = scanned
        var folders: [String: Bool] = [:]  // relative folder path -> whether events were dropped
        var files: Set<String> = []

        for event in events {
            let dropped =
                event.flags
                & FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped) != 0
            if dropped {
                folders[""] = true
                continue
            }
            guard let relative = relativePath(of: event.path) else { continue }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: event.path, isDirectory: &isDirectory)
            let isFolder =
                exists
                ? isDirectory.boolValue : event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            if isFolder {
                if folders[relative] == nil { folders[relative] = false }
            } else {
                files.insert(relative)
            }
        }

        // The root diff covers every other folder; a folder diff covers the files under it.
        if folders[""] != nil { folders = ["": folders[""] ?? false] }
        for (folder, dropped) in folders where LibraryScanner.isScannedFolder(relativePath: folder) {
            let prefix = folder.isEmpty ? "" : folder + "/"
            let before = known.filter { $0.relativePath.hasPrefix(prefix) }
            let found = (try? LibraryScanner.scan(root: root, folder: folder)) ?? []
            let present = Set(found.map(\.id))
            changes.added.formUnion(present.subtracting(before))
            changes.removed.formUnion(before.subtracting(present))
            if dropped { changes.modified.formUnion(present.intersection(before)) }
            for note in found where !before.contains(note.id) || dropped { scanned[note.id] = note.modifiedAt }
            for id in before.subtracting(present) { scanned[id] = nil }
        }
        for relative in files {
            guard let id = LibraryScanner.noteID(forRelativePath: relative) else { continue }
            // Exact about case (L-4): after a rename of `Alpha.md` to `alpha.md` the old path
            // still "exists" on a case-insensitive volume, but the old note is gone.
            let url = URL(fileURLWithPath: rootPath + "/" + relative, isDirectory: false)
            guard let modifiedAt = try? NoteStore.modificationDate(atExactly: url) else {
                changes.removed.insert(id)
                scanned[id] = nil
                continue
            }
            if !known.contains(id) {
                changes.added.insert(id)
            } else if scanned[id] != modifiedAt {
                changes.modified.insert(id)
            }
            // Otherwise this is the event for the change a scan already reported (I-5). Either
            // way the note has caught up with the stream.
            scanned[id] = nil
        }
        // Disk is the authority: a note that exists now is not removed, whatever else was seen.
        changes.removed.subtract(changes.added)
        changes.removed.subtract(changes.modified)
        return (changes, scanned)
    }

    /// `path` relative to the root with `/` separators, `""` for the root itself, or nil if the
    /// path is outside the root.
    private func relativePath(of path: String) -> String? {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// The path with symlinks resolved, as FSEvents reports paths (`/private/var/...`, not
    /// `/var/...`), and without a trailing slash. Falls back to the path as given if it does not
    /// exist. Uses `realpath(3)`: Foundation's resolver strips `/private`, which FSEvents keeps.
    private static func canonicalPath(_ path: String) -> String {
        var resolved = path
        if let real = realpath(path, nil) {
            resolved = String(cString: real)
            free(real)
        }
        while resolved.count > 1 && resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }
}
