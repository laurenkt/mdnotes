import Foundation

/// The one case folding used wherever MDNotes compares text case-insensitively: query words
/// against indexed titles and bodies (S-2), the query against a title on Enter (C-1), and,
/// once they exist, link targets against titles and tags against the tag index (K-2, T-2).
/// Every comparison folds both sides with `fold(_:)`, so no two features can disagree about
/// what "case-insensitive" means.
///
/// The folding is the Unicode default lowercase mapping, independent of the user's locale, so
/// an index built on one machine matches the same queries on any other. Nothing else is
/// normalised: whitespace, punctuation, `#`, `/`, digits and diacritics all survive unchanged
/// (ADR-0003: no tokeniser, stemming, or fuzzy matching).
public enum CaseFolding {
    /// `text` with every cased character mapped to lowercase and nothing else changed.
    /// Idempotent: folding folded text is a no-op.
    public static func fold(_ text: some StringProtocol) -> String {
        text.lowercased()
    }

    /// Whether `a` and `b` are the same text ignoring case (C-1). Whitespace and punctuation
    /// must match exactly; callers trim if the spec says to (C-2).
    public static func areEqual(_ a: some StringProtocol, _ b: some StringProtocol) -> Bool {
        fold(a) == fold(b)
    }
}
