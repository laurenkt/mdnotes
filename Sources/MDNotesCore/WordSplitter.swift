import Foundation

/// Splits query text into words (S-2). A word is a maximal run of non-whitespace characters;
/// there is no other tokenisation, so punctuation, `#` (S-4) and `/` stay inside a word and a
/// note matches by substring, not by token (ADR-0003). Whitespace is Unicode whitespace as
/// `Character.isWhitespace` defines it: spaces, tabs, newlines, and the non-breaking kinds.
///
/// Shared by the search field, the `[[` completion popover (K-4), and anything else that
/// applies the S-2 rules to typed text.
public enum WordSplitter {
    /// The words of `text` as typed, in order, duplicates kept. Empty or blank text has none.
    public static func words(of text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    /// The words of `text`, each case-folded with `CaseFolding.fold(_:)`, ready to compare
    /// against folded titles and bodies.
    public static func foldedWords(of text: String) -> [String] {
        words(of: text).map(CaseFolding.fold)
    }
}
