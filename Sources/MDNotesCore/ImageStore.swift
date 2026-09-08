import Foundation
import UniformTypeIdentifiers

/// The images pasted or dropped into the editor (I-1), and the files embeds name (I-2).
///
/// An image goes under `i/` at the library root as `<yyyyMMdd-HHmmss>.<ext>`, the timestamp in
/// local time and the extension lowercased; the editor then inserts `![[<name>]]`, and that
/// name is what `url(forEmbed:)` turns back into the file when the link is opened (I-2). An
/// embed may also spell a path relative to the root (K-1, L-6), such as `assets/photo.jpg`.
///
/// The bytes are whatever the caller hands over: this is Foundation only, so decoding and
/// converting image data is the app layer's job. All of it is synchronous file I/O and must
/// run off the main thread (PF-6).
public struct ImageStore: Sendable {
    /// The folder under the root that receives pasted and dropped images (I-1).
    public static let folderName = "i"

    /// Why an image could not be stored.
    public enum Failure: Error, Hashable, Sendable {
        /// The extension was empty once lowercased and stripped of dots, so the file would
        /// have no type.
        case emptyExtension
        /// Every name tried for the second was taken. Practically unreachable.
        case noFreeName
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `i/` under the root.
    public var folder: URL {
        root.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    // MARK: - Naming (I-1)

    /// `ext` lowercased with any leading dots dropped: `.PNG` and `png` both name a `png` file.
    public static func normalizedExtension(_ ext: String) -> String {
        String(ext.drop(while: { $0 == "." })).lowercased()
    }

    /// `date` as `yyyyMMdd-HHmmss` in the local time zone.
    public static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// The name an image stored at `date` gets (I-1): `<yyyyMMdd-HHmmss>.<ext>`, with `ext`
    /// normalised.
    public static func fileName(at date: Date, extension ext: String) -> String {
        "\(timestamp(for: date)).\(normalizedExtension(ext))"
    }

    // MARK: - Writing (I-1)

    /// Writes `bytes` under `i/`, creating the folder if needed, and returns the file's name.
    /// The name is `fileName(at:extension:)` for `date`; when a file of that name is already
    /// there (a second image in the same second) the stem gets `-2`, `-3` and so on until a free
    /// name is found, so nothing is ever written over. The write is atomic: the bytes land in
    /// a hidden temp file beside the destination and are renamed into place (as E-5 has notes
    /// written), so a reader never sees a partial image.
    public func write(_ bytes: [UInt8], extension ext: String, at date: Date = Date()) throws -> String {
        let ext = Self.normalizedExtension(ext)
        guard !ext.isEmpty else { throw Failure.emptyExtension }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = Self.timestamp(for: date)
        var name = "\(stem).\(ext)"
        var attempt = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name, isDirectory: false).path) {
            attempt += 1
            guard attempt <= Self.maximumAttempts else { throw Failure.noFreeName }
            name = "\(stem)-\(attempt).\(ext)"
        }
        try AtomicWriter().write(bytes, to: folder.appendingPathComponent(name, isDirectory: false))
        return name
    }

    private static let maximumAttempts = 10_000

    // MARK: - Locating (I-2)

    /// The file the embed `![[target]]` names, or nil when there is none (I-2). `target` is the
    /// text between the brackets, trimmed. A bare name is looked for under `i/` first, where
    /// I-1 puts images, then at the root; a name with a `/` is a path relative to the root (K-1,
    /// L-6). Only an existing regular file counts: a folder, or a name that would leave the
    /// root through an empty, `.` or `..` segment, is nil.
    public func url(forEmbed target: String) -> URL? {
        relativePath(forEmbed: target).map { root.appendingPathComponent($0, isDirectory: false) }
    }

    /// The same lookup as `url(forEmbed:)`, answered as the file's `/`-separated path relative
    /// to the root: `i/<name>` or `<name>` for a bare name, the text itself for a path. What the
    /// search index stores for a note's first image (S-11), so a snapshot does not depend on
    /// where the root is.
    public func relativePath(forEmbed target: String) -> String? {
        let text = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let segments = text.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let candidates = text.contains("/") ? [text] : ["\(Self.folderName)/\(text)", text]
        return candidates.first { Self.isRegularFile(root.appendingPathComponent($0, isDirectory: false)) }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    // MARK: - First image (S-11)

    /// Whether a file named `path` is an image, decided by its extension the way I-1 decides
    /// which dropped files are images: the extension's uniform type conforms to `public.image`.
    /// Nothing is read; a file with no extension is not an image.
    public static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        return UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }

    /// The root-relative path of the first embed in `links` that resolves to an existing image
    /// file (S-11): the image a list row shows a thumbnail of. `links` are a body's references
    /// in order of appearance, as `NoteReferences` lists them; plain wikilinks are skipped,
    /// as is an embed that names nothing on disk or a file that is not an image (K-1, L-6).
    /// Nil when no embed qualifies. Stats files: call it off the main thread (PF-6).
    public func firstImage(in links: [LinkTarget]) -> String? {
        for link in links where link.isEmbed {
            if let path = relativePath(forEmbed: link.text), Self.isImageFile(path) { return path }
        }
        return nil
    }
}
