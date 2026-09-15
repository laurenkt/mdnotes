import Foundation

/// One note found on disk: its identity and the file's modification date.
public struct ScannedNote: Hashable, Sendable {
    public let id: NoteID
    public let modifiedAt: Date

    public init(id: NoteID, modifiedAt: Date) {
        self.id = id
        self.modifiedAt = modifiedAt
    }
}

/// Walks a library root and lists its notes (L-2 to L-6).
///
/// Only the directory structure is read, never file bodies, so evicted iCloud placeholders are
/// listed like any other file (L-7). The walk is synchronous file I/O and must be called off
/// the main thread (PF-6).
///
/// Each folder is listed with `getattrlistbulk`, which hands back names, kinds and
/// modification dates by the buffer-load in a few system calls, and nothing else is touched:
/// no `URL` per entry, no resource-value dictionary, no bridging. Listing 20k notes through
/// `FileManager` and `URL.resourceValues` cost seven times the kernel's own listing, and every
/// one of those objects went through the Objective-C runtime, whose lock the main thread holds
/// for long stretches while a cold launch loads frameworks; the scan then waited on it (PF-1,
/// I-11). The names are native Swift strings, so the sort by path stays on its fast path.
public enum LibraryScanner {
    /// Folders directly under the root that are never scanned (L-3). Hidden entries (leading
    /// `.`, which covers `.obsidian/`) are skipped at every depth.
    public static let skippedRootFolders: Set<String> = ["Trash", "templates"]

    /// The file extension that makes a file a note (L-2).
    public static let noteExtension = ".md"

    /// Lists every note under `root`, sorted by relative path.
    ///
    /// Throws if `root` itself cannot be listed. A subfolder that cannot be listed (deleted or
    /// unreadable mid-scan) is skipped.
    public static func scan(root: URL) throws -> [ScannedNote] {
        var notes: [ScannedNote] = []
        try walk(directory: root.path, relativePrefix: "", isRoot: true, into: &notes)
        notes.sort { $0.id.relativePath < $1.id.relativePath }
        return notes
    }

    /// Lists the notes under one folder of `root`, given as a `/`-separated relative path
    /// (`""` is the root itself). Ids are relative to `root`, as `scan(root:)` reports them.
    /// Throws if the folder cannot be listed. Applies L-3 to the folder path first: a folder the
    /// full scan would skip lists nothing.
    public static func scan(root: URL, folder: String) throws -> [ScannedNote] {
        if folder.isEmpty { return try scan(root: root) }
        guard isScannedFolder(relativePath: folder) else { return [] }
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.path]) }
        var notes: [ScannedNote] = []
        try walk(directory: directory.path, relativePrefix: folder, isRoot: false, into: &notes)
        notes.sort { $0.id.relativePath < $1.id.relativePath }
        return notes
    }

    /// The id of the note a full scan would list at `relativePath`, or nil if the scan would
    /// skip that path (L-2, L-3, L-6). The path uses `/` separators, relative to the root.
    public static func noteID(forRelativePath relativePath: String) -> NoteID? {
        guard relativePath.hasSuffix(noteExtension), isScannedPath(relativePath) else { return nil }
        return NoteID(relativePath: relativePath)
    }

    /// True if a full scan would descend into the folder at `relativePath` (L-3). `""` is the
    /// root, which is always scanned.
    public static func isScannedFolder(relativePath: String) -> Bool {
        relativePath.isEmpty || isScannedPath(relativePath)
    }

    private static func isScannedPath(_ relativePath: String) -> Bool {
        var first = true
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component.hasPrefix(".") { return false }
            if first && skippedRootFolders.contains(String(component)) { return false }
            first = false
        }
        return true
    }

    // MARK: - Listing

    /// One directory entry as `getattrlistbulk` reports it.
    private struct Entry {
        let name: String
        let type: fsobj_type_t
        let modifiedAt: Date
    }

    /// Bytes per `getattrlistbulk` call: room for a few hundred entries at a time.
    private static let listingBufferSize = 64 * 1024

    private static func walk(
        directory path: String, relativePrefix: String, isRoot: Bool, into notes: inout [ScannedNote]
    ) throws {
        let entries: [Entry]
        do {
            entries = try list(directory: path)
        } catch {
            if isRoot { throw error }
            return
        }

        for entry in entries {
            let name = entry.name
            if name.hasPrefix(".") { continue }
            if isRoot && skippedRootFolders.contains(name) { continue }

            let relativePath = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
            let childPath = path + "/" + name
            switch entry.type {
            case fsobj_type_t(VDIR.rawValue):
                try walk(directory: childPath, relativePrefix: relativePath, isRoot: false, into: &notes)
            case fsobj_type_t(VREG.rawValue):
                guard name.hasSuffix(noteExtension) else { continue }
                notes.append(ScannedNote(id: NoteID(relativePath: relativePath), modifiedAt: entry.modifiedAt))
            case fsobj_type_t(VLNK.rawValue):
                // A symbolic link to a file is listed as the note it points at, with the
                // target's date; a link to a folder is not followed, so a cycle cannot form.
                guard name.hasSuffix(noteExtension), let modifiedAt = regularFileModificationDate(at: childPath)
                else { continue }
                notes.append(ScannedNote(id: NoteID(relativePath: relativePath), modifiedAt: modifiedAt))
            default:
                continue
            }
        }
    }

    /// The entries of one directory: name, kind and modification date, in the order the file
    /// system hands them out. Throws when the directory cannot be opened.
    private static func list(directory path: String) throws -> [Entry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw listingError(path: path, errno: errno) }
        defer { close(fd) }

        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr =
            UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_MODTIME)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: listingBufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var entries: [Entry] = []
        while true {
            let count = getattrlistbulk(fd, &list, buffer, listingBufferSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                if entries.isEmpty { throw listingError(path: path, errno: errno) }
                return entries
            }
            if count == 0 { return entries }
            var cursor = buffer
            for _ in 0..<Int(count) {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                defer { cursor += length }
                if let entry = decode(entryAt: cursor) { entries.append(entry) }
            }
        }
    }

    /// Decodes one entry of a `getattrlistbulk` buffer. The attributes come in a fixed order
    /// after the entry's length: the set actually returned, the per-entry error when asked
    /// for, then the rest in bit order, each packed at 4-byte alignment. Nil for an entry the
    /// file system reported an error on or could not name.
    private static func decode(entryAt start: UnsafeMutableRawPointer) -> Entry? {
        var field = start + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 {
            let error = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
            if error != 0 { return nil }
        }
        guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { return nil }
        let reference = field.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        field += MemoryLayout<attrreference_t>.size
        var type: fsobj_type_t = 0
        if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 {
            type = field.loadUnaligned(as: fsobj_type_t.self)
            field += MemoryLayout<fsobj_type_t>.size
        }
        var modifiedAt = Date.distantPast
        if returned.commonattr & UInt32(ATTR_CMN_MODTIME) != 0 {
            modifiedAt = date(from: field.loadUnaligned(as: timespec.self))
        }
        return Entry(name: name, type: type, modifiedAt: modifiedAt)
    }

    /// The date of a symbolic link's target when that is a regular file, else nil.
    private static func regularFileModificationDate(at path: String) -> Date? {
        var status = stat()
        guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        return date(from: status.st_mtimespec)
    }

    /// The `Date` for a file time, rounded the way `URL.resourceValues` rounds
    /// `contentModificationDate`, so the two compare equal for the same file: the seconds are
    /// moved to the reference date as integers, and only then do the nanoseconds join.
    /// (`Date(timeIntervalSince1970:)` rounds twice and differs in the last bit for four files
    /// in ten.)
    private static func date(from time: timespec) -> Date {
        Date(
            timeIntervalSinceReferenceDate: Double(time.tv_sec - Int(Date.timeIntervalBetween1970AndReferenceDate))
                + Double(time.tv_nsec) / 1e9)
    }

    private static func listingError(path: String, errno code: Int32) -> any Error {
        let posix = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        let cocoaCode: CocoaError.Code = code == ENOENT || code == ENOTDIR ? .fileReadNoSuchFile : .fileReadUnknown
        return CocoaError(cocoaCode, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: posix])
    }
}
