import Darwin
import Foundation

/// Writes a file so that a reader only ever sees the old contents or the new, never a mix (E-5).
///
/// The bytes go to a hidden temp file in the destination's own directory (so the rename is a
/// same-volume rename, and so the scanner never lists it: L-3), are flushed to disk, and the temp
/// is renamed over the destination. A crash or error before the rename leaves the destination
/// untouched; the rename itself is atomic. The destination's modification date is the time of
/// the write and is returned so callers can recognise their own change on disk (E-6).
///
/// All of this is synchronous file I/O and must run off the main thread (PF-6).
public struct AtomicWriter: Sendable {
    /// Called with the temp file's URL once it is fully written and before it replaces the
    /// destination. Throwing aborts the write and removes the temp file. Tests use it to
    /// interrupt a write at the last possible moment; production writers never install one.
    public typealias Interruption = @Sendable (URL) throws -> Void

    private let beforeCommit: Interruption

    public init() {
        self.init(beforeCommit: { _ in })
    }

    public init(beforeCommit: @escaping Interruption) {
        self.beforeCommit = beforeCommit
    }

    /// Writes `text` as UTF-8, byte for byte (L-8). Returns the destination's modification date
    /// after the write.
    @discardableResult
    public func write(_ text: String, to url: URL) throws -> Date {
        try write(Array(text.utf8), to: url)
    }

    /// Writes `bytes` to `url`, replacing any existing file. The directory must already exist.
    /// Returns the destination's modification date after the write.
    @discardableResult
    public func write(_ bytes: [UInt8], to url: URL) throws -> Date {
        let destination = url.standardizedFileURL
        let temp = AtomicWriter.tempURL(for: destination)
        do {
            try AtomicWriter.writeTemp(bytes, at: temp.path, mode: AtomicWriter.mode(of: destination.path))
            try beforeCommit(temp)
            guard rename(temp.path, destination.path) == 0 else { throw NoteStore.posixError() }
        } catch {
            unlink(temp.path)
            throw error
        }
        return try AtomicWriter.modificationDate(at: destination)
    }

    /// A unique hidden sibling of `destination`. The leading `.` keeps it out of the scanner (L-3).
    static func tempURL(for destination: URL) -> URL {
        let name = ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        return destination.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    /// The permission bits of an existing file at `path`, so the replacement keeps them; a
    /// default for a new file.
    private static func mode(of path: String) -> mode_t {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0o644 }
        return info.st_mode & 0o777
    }

    /// Creates `path` exclusively, writes every byte and flushes it to disk. On any failure the
    /// partial file is removed before the error propagates.
    private static func writeTemp(_ bytes: [UInt8], at path: String, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw NoteStore.posixError() }
        defer { close(fd) }
        try bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let put = Darwin.write(fd, buffer.baseAddress.map { $0 + written }, buffer.count - written)
                if put < 0 {
                    if errno == EINTR { continue }
                    throw NoteStore.posixError()
                }
                written += put
            }
        }
        // The new file's permissions must not depend on the process umask when they were copied
        // from the file being replaced.
        guard fchmod(fd, mode) == 0 else { throw NoteStore.posixError() }
        guard fsync(fd) == 0 else { throw NoteStore.posixError() }
    }

    private static func modificationDate(at url: URL) throws -> Date {
        // Same autorelease consideration as `NoteStore.isDownloaded` (PF-5).
        try autoreleasepool {
            try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
        }
    }
}
