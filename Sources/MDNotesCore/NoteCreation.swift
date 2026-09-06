import Foundation

/// Turns the search field's text into the note it would create (C-2) or the reason it cannot
/// (C-3). Pure: nothing here touches disk. `NoteStore.create(_:)` does the writing.
public enum NoteCreation {
    /// Why a query cannot name a new note. `message` is the text shown inline (C-3).
    public enum Rejection: Error, Hashable, Sendable {
        /// The trimmed query is empty. Enter does nothing (C-1 needs a non-empty query).
        case empty
        /// A character that cannot be in a file name: `:` or NUL (C-3).
        case illegalCharacter(Character)
        /// Two `/` in a row, or a `/` at the start or end: a folder or file with no name.
        case emptySegment
        /// A `.` or `..` segment, which would leave the folder it is in.
        case relativeSegment(String)
        /// A segment starting with `.`: hidden, so the scanner would never list it (L-3).
        case hiddenSegment(String)
        /// A first segment naming a folder the scanner skips (L-3), so the note would be
        /// created but never listed.
        case skippedFolder(String)

        public var message: String {
            switch self {
            case .empty:
                return "Type a title to create a note."
            case .illegalCharacter(let character):
                let shown = character == "\0" ? "NUL" : "\u{201C}\(character)\u{201D}"
                return "\(shown) cannot be used in a note name."
            case .emptySegment:
                return "A folder or note name cannot be empty."
            case .relativeSegment(let segment):
                return "\u{201C}\(segment)\u{201D} is not a folder name."
            case .hiddenSegment(let segment):
                return "\u{201C}\(segment)\u{201D} would be hidden: names cannot start with a dot."
            case .skippedFolder(let folder):
                return "\u{201C}\(folder)\u{201D} is reserved and cannot hold notes."
            }
        }
    }

    /// The characters C-3 forbids inside a segment. `/` is the separator, so it can never be
    /// inside one.
    public static let illegalCharacters: Set<Character> = [":", "\0"]

    /// The note `query` names (C-2): the query trimmed of whitespace, with `.md` appended, at
    /// the root; `/` splits it into folders and a file name. Throws the first rule the query
    /// breaks (C-3, and the L-3 rules that would make the new note invisible).
    public static func noteID(forQuery query: String) throws(Rejection) -> NoteID {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw .empty }
        if let bad = trimmed.first(where: illegalCharacters.contains) { throw .illegalCharacter(bad) }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for segment in segments {
            if segment.isEmpty { throw .emptySegment }
            if segment == "." || segment == ".." { throw .relativeSegment(segment) }
            if segment.hasPrefix(".") { throw .hiddenSegment(segment) }
        }
        if segments.count > 1, let folder = segments.first, LibraryScanner.skippedRootFolders.contains(folder) {
            throw .skippedFolder(folder)
        }
        return NoteID(relativePath: trimmed + LibraryScanner.noteExtension)
    }

    /// The path of `id` as a query would spell it: relative path without the `.md` extension.
    /// A query equal to this (case-insensitively) names the same file, so C-1 opens it rather
    /// than creating over it.
    public static func queryForm(of id: NoteID) -> String {
        let path = id.relativePath
        return path.hasSuffix(LibraryScanner.noteExtension)
            ? String(path.dropLast(LibraryScanner.noteExtension.count)) : path
    }
}

extension NoteStore {
    /// The outcome of `create(_:)`.
    public struct Creation: Hashable, Sendable {
        /// The file's modification date after the call.
        public let modifiedAt: Date
        /// False when the file already existed and was left untouched.
        public let created: Bool
    }

    /// Creates the empty file backing `id`, making any missing folders on the way (C-2). The
    /// write is atomic (E-5). An existing file is never overwritten, a case variant of the name
    /// on a case-insensitive volume included: it is left as it is and `created` is false.
    /// Synchronous file I/O: call it off the main thread (PF-6).
    public func create(_ id: NoteID) throws -> Creation {
        let url = self.url(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            return Creation(modifiedAt: try NoteStore.modificationDate(at: url), created: false)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let modifiedAt = try AtomicWriter().write("", to: url)
        return Creation(modifiedAt: modifiedAt, created: true)
    }
}
