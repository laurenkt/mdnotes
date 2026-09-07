import Foundation

/// The rules of the `#` completion popover (T-3), apart from the popover itself: when typing
/// has opened a session, what prefix the session is filtering on, and which known tags that
/// prefix lists. Everything works on the editor's text as an `NSString` and an insertion
/// index, as `LinkCompletion` does, so the AppKit layer hands over its storage and selection
/// and nothing else.
///
/// A `#` opens a session only where a tag can begin (T-1): at the start of a line or after
/// whitespace. A `#` glued to the text before it, as in `C#`, is not a tag and offers nothing.
/// The prefix is the text typed since the `#`, and a character outside the T-1 class ends the
/// session, which is how a heading's `# ` and a tag's trailing punctuation close it without a
/// key of their own. Whether the `#` sits in a code span or fenced block is not checked here:
/// the popover follows the keystroke, and the scanner decides what is a tag once it is typed.
public enum TagCompletion {
    /// The index just after a `#` that ends exactly at `caret` and could begin a tag (T-1: the
    /// `#` is at the start of the text or preceded by whitespace), or nil when the caret is
    /// not right after such a `#` or is a selection rather than a caret. Typing the `#` is
    /// what opens a session (T-3), so this is checked once the text has changed, never on a
    /// caret move alone.
    public static func anchor(in text: NSString, caret: NSRange) -> Int? {
        guard caret.length == 0, caret.location <= text.length, canBeginTag(before: caret.location, in: text)
        else { return nil }
        return caret.location
    }

    /// The prefix typed since the `#` a session anchored at `anchor`: the text from the anchor
    /// to the caret. Nil when the session is over: the caret has left the range (moved before
    /// the anchor, or become a selection), the `#` is no longer just before the anchor or no
    /// longer where a tag can begin, or the text since it holds a character outside the T-1
    /// class, where a tag ends.
    public static func filterText(in text: NSString, anchor: Int, caret: NSRange) -> String? {
        guard caret.length == 0, caret.location >= anchor, caret.location <= text.length,
            canBeginTag(before: anchor, in: text)
        else { return nil }
        for index in anchor..<caret.location where !MarkdownScanner.isTagCharacter(text.character(at: index)) {
            return nil
        }
        return text.substring(with: NSRange(location: anchor, length: caret.location - anchor))
    }

    /// The tags the popover lists for `prefix` (T-3): every known tag whose name begins with
    /// it, ignoring case as tags do (T-2), in the spelling the library uses for it, sorted
    /// case-insensitively. An empty prefix lists every tag.
    public static func tags(withPrefix prefix: String, in index: TagIndex) -> [String] {
        let folded = CaseFolding.fold(prefix)
        return index.allTags.filter { CaseFolding.fold($0).hasPrefix(folded) }
    }

    /// What the completion inserts for `tag` (T-3): the tag's name, since the `#` is already
    /// typed and nothing closes a tag.
    public static func insertion(for tag: String) -> String { tag }

    /// True when `text` has a `#` just before `index` that a tag could start at (T-1): it is
    /// the first character of the text or the character before it is whitespace, which
    /// includes a line terminator.
    private static func canBeginTag(before index: Int, in text: NSString) -> Bool {
        guard index >= 1, index <= text.length, text.character(at: index - 1) == hash else { return false }
        guard index >= 2 else { return true }
        guard let scalar = Unicode.Scalar(UInt32(text.character(at: index - 2))) else { return false }
        return scalar.properties.isWhitespace
    }

    private static let hash = UInt16(UInt8(ascii: "#"))
}
