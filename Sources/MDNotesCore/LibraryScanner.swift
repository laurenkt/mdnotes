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

    private static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .contentModificationDateKey,
    ]

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
            let values = try? entry.resourceValues(forKeys: Set(resourceKeys))
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
