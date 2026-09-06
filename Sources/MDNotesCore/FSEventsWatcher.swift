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
/// Paths a full scan would skip (L-3, L-6) are ignored. The handler runs on a private serial
/// queue, never the main thread (PF-6), with a non-empty batch per callback. Own writes are
/// not filtered here; that is `OwnWrites` (E-6). Safe to start and stop from any thread, but
/// not from inside the handler. The last reference may be dropped from anywhere, the handler
/// included: `deinit` stops the stream, and never runs on the watcher's own queue.
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
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
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
        FSEventStreamRelease(stream)
        // Drain a callback that may already be running with an unretained reference to self.
        queue.sync {}
    }

    public enum WatchError: Error, Equatable {
        case streamCreationFailed(String)
        case streamStartFailed(String)
    }

    // MARK: - Event handling

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        // The reference taken for this call is released on another queue afterwards. If the
        // owner let go of the watcher while this callback ran, this reference is the last one,
        // and releasing it here would run `deinit`, and so `stop()`, on the watcher's own queue,
        // where waiting for that queue to drain is a deadlock libdispatch traps on.
        defer { DispatchQueue.global(qos: .utility).async { withExtendedLifetime(watcher) {} } }
        let cStrings = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        var events: [(path: String, flags: FSEventStreamEventFlags)] = []
        events.reserveCapacity(count)
        for i in 0..<count {
            guard let cString = cStrings[i] else { continue }
            events.append((String(cString: cString), flags[i]))
        }
        watcher.handle(events)
    }

    private func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        // Only this queue changes `known`, so reading it before the disk work and writing it
        // after is consistent, and the lock is not held across file I/O.
        let changes = fold(events, known: state.withLock { $0.known })
        if changes.isEmpty { return }
        state.withLock { state in
            state.known.formUnion(changes.added)
            state.known.formUnion(changes.modified)
            state.known.subtract(changes.removed)
        }
        handler(changes)
    }

    /// One batch of events as `LibraryChanges`, judged against `known` and the disk as it is now.
    private func fold(_ events: [(path: String, flags: FSEventStreamEventFlags)], known: Set<NoteID>)
        -> LibraryChanges
    {
        var changes = LibraryChanges()
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
            let present = Set(((try? LibraryScanner.scan(root: root, folder: folder)) ?? []).map(\.id))
            changes.added.formUnion(present.subtracting(before))
            changes.removed.formUnion(before.subtracting(present))
            if dropped { changes.modified.formUnion(present.intersection(before)) }
        }
        for relative in files {
            guard let id = LibraryScanner.noteID(forRelativePath: relative) else { continue }
            if FileManager.default.fileExists(atPath: rootPath + "/" + relative) {
                if known.contains(id) { changes.modified.insert(id) } else { changes.added.insert(id) }
            } else {
                changes.removed.insert(id)
            }
        }
        // Disk is the authority: a note that exists now is not removed, whatever else was seen.
        changes.removed.subtract(changes.added)
        changes.removed.subtract(changes.modified)
        return changes
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
