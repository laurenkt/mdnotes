import Foundation

/// A search-field query in template mode (TP-5, ADR-0014): one whose first character is `@`.
/// Pure: this reads the text and matches names; the window shows the templates and Enter
/// instantiates one.
///
/// The characters attached to the `@`, up to the first whitespace, are the `filter`: the
/// name word that narrows the templates by the S-2 rules, a case-insensitive substring of
/// the name. `@` alone, or `@` followed by whitespace, has an empty filter and lists every
/// template. The words after the filter, split as S-2 splits a query and joined by single
/// spaces, are the `title` that `{{title}}` expands to (TP-3); with none it is empty and a
/// template whose path needs one is refused inline rather than instantiated.
public struct TemplateQuery: Hashable, Sendable {
    /// The character a query must start with to be template mode.
    public static let prefix: Character = "@"

    /// The name word after `@`, as typed; empty when `@` stands alone or before whitespace.
    public let filter: String

    /// The remaining words, as typed, joined by single spaces; empty when there are none.
    public let title: String

    public init(filter: String, title: String) {
        self.filter = filter
        self.title = title
    }

    /// Reads `text` as a template-mode query, or nil when it is not one: the first character
    /// must be `@`, leading whitespace included, so `daily` and ` @daily` are note queries.
    public init?(_ text: String) {
        guard text.first == Self.prefix else { return nil }
        let rest = text.dropFirst()
        let filter = rest.prefix { !$0.isWhitespace }
        let words = WordSplitter.words(of: String(rest.dropFirst(filter.count)))
        self.init(filter: String(filter), title: words.joined(separator: " "))
    }

    /// True when `text` is a template-mode query.
    public static func isTemplateMode(_ text: String) -> Bool {
        text.first == prefix
    }

    /// Whether the template called `name` is listed for this query (S-2): every template
    /// with an empty filter, otherwise those whose name contains the filter ignoring case.
    public func matches(_ name: String) -> Bool {
        filter.isEmpty || CaseFolding.fold(name).contains(CaseFolding.fold(filter))
    }

    /// The names in `names` this query lists, in the order given: the store's case-insensitive
    /// order is kept, since templates have no modified-date ordering worth showing (S-3 is
    /// for notes).
    public func names(matching names: [String]) -> [String] {
        names.filter(matches)
    }
}
