import Foundation

/// Identity of a note: its path relative to the library root, using `/` separators,
/// including the `.md` extension. Example: `daily/2026/06-sunday.md`.
public struct NoteID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let relativePath: String

    public init(relativePath: String) {
        self.relativePath = relativePath
    }

    /// Filename without the `.md` extension. This is the note's title.
    public var title: String {
        // Found on the UTF-8 view rather than by splitting: this runs once per note on the
        // launch path (PF-1), and `/` is ASCII so the byte after it is a character boundary.
        let utf8 = relativePath.utf8
        let nameStart = utf8.lastIndex(of: UInt8(ascii: "/")).map { utf8.index(after: $0) } ?? utf8.startIndex
        let name = relativePath[nameStart...]
        return String(name.hasSuffix(".md") ? name.dropLast(3) : name)
    }

    public var description: String { relativePath }
}
