import Darwin
import Foundation

/// The outcome of reading a note's body from disk (L-7, L-8).
public enum NoteBody: Hashable, Sendable {
    /// The file decoded as UTF-8. This is the note's text, byte-exact.
    case text(String)
    /// The file is not valid UTF-8 (L-8). `lossyText` replaces bad sequences with U+FFFD and is
    /// for display only: it must never be written back to disk.
    case invalidUTF8(lossyText: String)
    /// The file is an evicted iCloud placeholder that has not been downloaded (L-7). Reading it
    /// would block on the network, so the body is unknown until it becomes available.
    case notDownloaded

    /// Text to show in the editor, or nil when nothing is available yet.
    public var displayText: String? {
        switch self {
        case .text(let s), .invalidUTF8(let s): return s
        case .notDownloaded: return nil
        }
    }

    /// Whether the editor may write this body back to the file (L-8).
    public var isWritable: Bool {
        if case .text = self { return true }
        return false
    }
}

/// Reads note bodies from a library root (L-7, L-8).
///
/// All reads are synchronous file I/O and must run off the main thread (PF-6). A read never
/// waits for an iCloud download: an evicted placeholder yields `.notDownloaded` without
/// touching its contents.
public struct NoteStore: Sendable {
    /// Answers whether a file's contents can be read without waiting for a download.
    public typealias AvailabilityProbe = @Sendable (URL) -> Bool

    public let root: URL
    private let isAvailable: AvailabilityProbe

    public init(root: URL) {
        self.init(root: root, isAvailable: NoteStore.isDownloaded(_:))
    }

    /// Injects the availability check. Tests use it to simulate an evicted file, which cannot
    /// be fabricated outside an iCloud container.
    public init(root: URL, isAvailable: @escaping AvailabilityProbe) {
        self.root = root
        self.isAvailable = isAvailable
    }

    /// The file backing `id`.
    public func url(for id: NoteID) -> URL {
        root.appendingPathComponent(id.relativePath, isDirectory: false)
    }

    /// The modification date of the file backing `id`, read the same way the scanner reads it.
    /// Throws if the file does not exist. An evicted placeholder still has a date (L-7).
    ///
    /// Exact about case: a note's identity is its path as the scanner lists it (L-4), so on a
    /// case-insensitive volume a file whose name differs from `id`'s only in case is a different
    /// note, and `id` does not exist. Without this a note renamed `Alpha` to `alpha` would keep
    /// answering for its old id (R-2, X-1).
    public func modificationDate(of id: NoteID) throws -> Date {
        let url = self.url(for: id)
        // Same autorelease consideration as `isDownloaded` (PF-5).
        return try autoreleasepool {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .nameKey])
            guard NoteStore.nameMatches(values.name, url: url) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            return values.contentModificationDate ?? .distantPast
        }
    }

    /// The modification date of whatever file `url` reaches, case variants included. For the
    /// one caller that must never write over a file it can reach (`create`).
    static func modificationDate(at url: URL) throws -> Date {
        try autoreleasepool {
            try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        }
    }

    /// True if a file exists at exactly `url`, its name matching in case (L-4), not merely a
    /// case variant of it on a case-insensitive volume.
    public static func fileExistsExactly(at url: URL) -> Bool {
        autoreleasepool {
            guard let values = try? url.resourceValues(forKeys: [.nameKey]) else { return false }
            return nameMatches(values.name, url: url)
        }
    }

    /// Whether the name the file system reports for `url` is the one `url` spells, allowing
    /// only Unicode normalisation to differ. A nil name (the volume did not say) is trusted.
    private static func nameMatches(_ reported: String?, url: URL) -> Bool {
        guard let reported else { return true }
        return reported == url.lastPathComponent
    }

    /// True unless `id`'s file is an evicted placeholder whose contents are not on disk (L-7).
    /// A missing file counts as available: there is nothing to download. File I/O; call off
    /// the main thread (PF-6).
    public func isAvailable(_ id: NoteID) -> Bool {
        isAvailable(url(for: id))
    }

    /// Reads the body of `id`. Throws if the file cannot be read at all (missing, permissions);
    /// encoding and download problems are reported in the result, not thrown.
    public func read(_ id: NoteID) throws -> NoteBody {
        let url = self.url(for: id)
        guard isAvailable(url) else { return .notDownloaded }
        let bytes = try NoteStore.readBytes(at: url.path)
        if let text = String(validating: bytes, as: UTF8.self) {
            return .text(text)
        }
        return .invalidUTF8(lossyText: String(decoding: bytes, as: UTF8.self))
    }

    /// Reads a whole file into a buffer sized exactly to the file.
    ///
    /// `Data(contentsOf:)` rounds each read up to a page, and with tens of thousands of small
    /// notes those pages stay resident in the allocator long after the `Data` is gone (PF-5).
    static func readBytes(at path: String) throws -> [UInt8] {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw NoteStore.posixError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw NoteStore.posixError() }
        let size = Int(info.st_size)
        return try [UInt8](unsafeUninitializedCapacity: size) { buffer, initialized in
            initialized = 0
            guard let base = buffer.baseAddress else { return }
            while initialized < size {
                let got = Darwin.read(fd, base + initialized, size - initialized)
                if got < 0 { throw NoteStore.posixError() }
                if got == 0 { break }
                initialized += got
            }
        }
    }

    /// The current `errno` as a thrown error, mapping a missing file to the Cocoa error callers
    /// already check for.
    static func posixError() -> any Error {
        let code = errno
        if code == ENOENT { return CocoaError(.fileReadNoSuchFile) }
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Asks iCloud to start downloading an evicted file (L-7). Returns immediately; the file
    /// becomes readable later and the file-system watcher reports it. A no-op for ordinary files.
    public func requestDownload(of id: NoteID) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url(for: id))
    }

    /// True unless the file is an iCloud placeholder whose contents are not on disk.
    ///
    /// Checks `ubiquitousItemDownloadingStatus` first; a nil status means the file is not in an
    /// iCloud container. As a second line, the APFS dataless flag catches placeholders that the
    /// ubiquity APIs do not report (for example a root synced by another provider).
    public static func isDownloaded(_ url: URL) -> Bool {
        // The resource-value lookup autoreleases several KB per call; without a pool of its own,
        // a tight loop over 20k notes on one thread holds 100+ MB until the caller returns (PF-5).
        let status = autoreleasepool {
            try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        }
        if let status {
            return status != .notDownloaded
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return true }
        return info.st_flags & UInt32(SF_DATALESS) == 0
    }
}
