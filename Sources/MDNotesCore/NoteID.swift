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
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    public var description: String { relativePath }
}
