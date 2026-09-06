import Foundation

/// The single-line body snippet a list row shows next to the title and date (S-6).
///
/// A snippet is the start of the note flattened onto one line: every run of whitespace,
/// newlines included, becomes a single space, and the result is trimmed and cut to
/// `maxCharacters`. Case and punctuation are the file's own; the snippet is for display, not
/// search, so it is never folded. Only the first `scanCharacters` characters of a body are
/// examined, so a 1 MB note costs the same as a short one (PF-4).
public enum BodySnippet {
    /// Longest snippet produced, in characters. Wider than any row can show, so truncation is
    /// the row's decision, not the index's.
    public static let maxCharacters = 200

    /// How far into a body to look for non-whitespace before giving up.
    public static let scanCharacters = 2048

    /// The snippet for `body`. Empty when the body is empty or all whitespace.
    public static func make(from body: String) -> String {
        var out = ""
        out.reserveCapacity(maxCharacters)
        var count = 0
        var pendingSpace = false
        for character in body.prefix(scanCharacters) {
            if character.isWhitespace {
                pendingSpace = count > 0
                continue
            }
            if pendingSpace {
                out.append(" ")
                count += 1
                pendingSpace = false
            }
            out.append(character)
            count += 1
            if count >= maxCharacters { break }
        }
        return out
    }
}
