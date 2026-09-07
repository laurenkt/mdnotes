import Foundation

/// The rules of the `[[` completion popover (K-4), apart from the popover itself: when typing
/// has opened a session, what text the session is filtering on, and which titles that text
/// lists. Everything works on the editor's text as an `NSString` and an insertion index, so the
/// AppKit layer only has to hand over its storage and selection.
public enum LinkCompletion {
    /// The index just after a `[[` that ends exactly at `caret`, or nil when the caret is not
    /// right after two opening brackets or is a selection rather than a caret. Typing the
    /// second bracket is what opens a session (K-4), so this is checked once the text has
    /// changed, never on a caret move alone.
    public static func anchor(in text: NSString, caret: NSRange) -> Int? {
        guard caret.length == 0, caret.location >= 2, caret.location <= text.length,
            text.character(at: caret.location - 1) == openBracket,
            text.character(at: caret.location - 2) == openBracket
        else { return nil }
        return caret.location
    }

    /// The text typed since the `[[` a session anchored at `anchor`: the text from the anchor
    /// to the caret. Nil when the session is over: the caret has left the range (moved before
    /// the anchor, or become a selection), the opening brackets are no longer just before the
    /// anchor, or the text since them holds a closing bracket or a line break, which is where a
    /// wikilink target ends (K-1).
    public static func filterText(in text: NSString, anchor: Int, caret: NSRange) -> String? {
        guard caret.length == 0, caret.location >= anchor, anchor >= 2, caret.location <= text.length,
            text.character(at: anchor - 1) == openBracket, text.character(at: anchor - 2) == openBracket
        else { return nil }
        let typed = text.substring(with: NSRange(location: anchor, length: caret.location - anchor))
        if typed.contains(where: { $0 == "]" || $0.isNewline }) { return nil }
        return typed
    }

    /// The titles the popover lists for `text`: the titles matched by the S-2 rules on it
    /// (`SearchIndex.queryTitles`), most recently modified first (S-3), each title once. Two
    /// notes whose titles differ only in case make one row, in the spelling of the most
    /// recently modified, since a `[[link]]` to either resolves the same way (K-2).
    public static func titles(matching text: String, in index: SearchIndex) -> [String] {
        var titles: [String] = []
        var seen: Set<String> = []
        for entry in index.queryTitles(text) {
            let title = entry.id.title
            if seen.insert(CaseFolding.fold(title)).inserted { titles.append(title) }
        }
        return titles
    }

    /// What the completion inserts for `title` (K-4): the title and the closing brackets.
    public static func insertion(for title: String) -> String { title + "]]" }

    private static let openBracket = UInt16(UInt8(ascii: "["))
}
