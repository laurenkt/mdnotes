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

    /// Reads the body of `id`. Throws if the file cannot be read at all (missing, permissions);
    /// encoding and download problems are reported in the result, not thrown.
    public func read(_ id: NoteID) throws -> NoteBody {
        let url = self.url(for: id)
        guard isAvailable(url) else { return .notDownloaded }
        let data = try Data(contentsOf: url)
        if let text = String(validating: data, as: UTF8.self) {
            return .text(text)
        }
        return .invalidUTF8(lossyText: String(decoding: data, as: UTF8.self))
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
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        {
            return status != .notDownloaded
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return true }
        return info.st_flags & UInt32(SF_DATALESS) == 0
    }
}
