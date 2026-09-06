import Darwin
import Foundation

/// Turns an edited title into the note it would rename to (R-2) or the reason it cannot. Pure:
/// nothing here touches disk. `NoteStore.rename(_:to:)` does the renaming.
///
/// A rename changes the file's name within its folder, so the new title is one file name: the
/// characters C-3 forbids in a segment are rejected, and so is `/`, which would move the note.
/// The L-3 rules that would make the renamed note invisible are rejected as they are for
/// creation. A title that would give another note's file name, ignoring case as the file
/// system does, is a collision; a note may change the case of its own title.
public enum NoteRename {
    /// Why a title cannot be committed. `message` is the text shown inline (R-2).
    public enum Rejection: Error, Hashable, Sendable {
        /// The trimmed title is empty.
        case empty
        /// A character that cannot be in a file name: `:`, NUL, or `/` (R-2 renames within
        /// the folder).
        case illegalCharacter(Character)
        /// `.` or `..`, which name folders, not notes.
        case relativeName(String)
        /// A title starting with `.`: hidden, so the scanner would never list it (L-3).
        case hidden(String)
        /// Another note already has the file name the title would give.
        case collision(NoteID)

        public var message: String {
            switch self {
            case .empty:
                return "A note name cannot be empty."
            case .illegalCharacter(let character):
                let shown = character == "\0" ? "NUL" : "\u{201C}\(character)\u{201D}"
                return "\(shown) cannot be used in a note name."
            case .relativeName(let name):
                return "\u{201C}\(name)\u{201D} is not a note name."
            case .hidden(let name):
                return "\u{201C}\(name)\u{201D} would be hidden: names cannot start with a dot."
            case .collision(let other):
                return "A note named \u{201C}\(other.title)\u{201D} already exists."
            }
        }
    }

    /// The characters a title cannot contain. `/` joins C-3's set because a rename stays
    /// within the note's folder (R-2).
    public static let illegalCharacters: Set<Character> = [":", "/", "\0"]

    /// The id `id` has once its title is `title` (R-2): the same folder, `<title>.md`. The title
    /// is trimmed of whitespace, as a query is (C-2). Throws the first rule the title breaks.
    /// Collisions are not checked here: see `collision(renaming:to:in:)`.
    public static func noteID(renaming id: NoteID, toTitle title: String) throws(Rejection) -> NoteID {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw .empty }
        if let bad = trimmed.first(where: illegalCharacters.contains) { throw .illegalCharacter(bad) }
        if trimmed == "." || trimmed == ".." { throw .relativeName(trimmed) }
        if trimmed.hasPrefix(".") { throw .hidden(trimmed) }
        return NoteID(relativePath: folder(of: id) + trimmed + LibraryScanner.noteExtension)
    }

    /// The note, other than `id` itself, whose file `newID` would name on a case-insensitive
    /// file system, or nil when the rename collides with nothing (R-2). Linear in the snapshot;
    /// runs once per commit, not per keystroke.
    public static func collision(renaming id: NoteID, to newID: NoteID, in snapshot: SearchIndex) -> NoteID? {
        let wanted = CaseFolding.fold(newID.relativePath)
        return snapshot.entries.first { $0.id != id && CaseFolding.fold($0.id.relativePath) == wanted }?.id
    }

    /// The folder part of `id`'s path including its trailing `/`, or `""` for a note at the root.
    private static func folder(of id: NoteID) -> String {
        let path = id.relativePath
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }
}

extension NoteStore {
    /// Renames the file backing `id` to `newID`'s path (R-2), making any missing folders on
    /// the way. Nothing is ever overwritten: if another file already has the new name the
    /// rename fails with `CocoaError.fileWriteFileExists`, atomically, through `RENAME_EXCL`.
    /// A change of case alone succeeds on a case-insensitive volume, where the name is the
    /// note's own. The file's modification date is untouched by a rename and is returned so the
    /// caller can recognise the watcher's report of the new name as its own doing (E-6).
    /// Synchronous file I/O: call it off the main thread (PF-6).
    public func rename(_ id: NoteID, to newID: NoteID) throws -> Date {
        if id == newID { return try modificationDate(of: id) }
        let source = url(for: id)
        let destination = url(for: newID)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }
            throw NoteStore.posixError()
        }
        return try modificationDate(of: newID)
    }
}
