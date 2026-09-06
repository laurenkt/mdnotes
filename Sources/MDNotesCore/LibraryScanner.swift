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
        try walk(directory: root, relativePrefix: "", isRoot: true, into: &notes)
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
        try walk(directory: directory, relativePrefix: folder, isRoot: false, into: &notes)
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

    private static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .contentModificationDateKey,
    ]
    private static let resourceKeySet = Set(resourceKeys)

    private static func walk(
        directory: URL, relativePrefix: String, isRoot: Bool, into notes: inout [ScannedNote]
    ) throws {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: resourceKeys, options: [])
        } catch {
            if isRoot { throw error }
            return
        }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: resourceKeySet)
            let name = values?.name ?? entry.lastPathComponent
            if name.hasPrefix(".") { continue }
            if isRoot && skippedRootFolders.contains(name) { continue }

            let relativePath = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
            if values?.isDirectory == true {
                try walk(directory: entry, relativePrefix: relativePath, isRoot: false, into: &notes)
                continue
            }
            guard name.hasSuffix(noteExtension) else { continue }
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            notes.append(ScannedNote(id: NoteID(relativePath: relativePath), modifiedAt: modifiedAt))
        }
    }
}
