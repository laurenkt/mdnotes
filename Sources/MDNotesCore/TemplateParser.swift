import Foundation

/// Reads a template file (TP-2) and expands its tokens (TP-3). Pure: nothing here touches
/// disk or knows where templates live; `TemplateStore` lists the files and instantiation
/// (TP-4) does the writing.
///
/// A template is a header block followed by a body. The header is a first line `---`, one or
/// more `key: value` lines and a closing `---`. The only recognised key is `path`; unknown keys
/// and lines that are not `key: value` are ignored. A file without a header, with an unclosed
/// header, or without a `path` parses to a `Rejection` whose `message` is what the list shows
/// inline (TP-2).
///
/// Tokens are `{{date:FORMAT}}`, `{{title}}` and `{{cursor}}`. FORMAT is a Unicode date format
/// pattern handed to `DateFormatter` as written and evaluated in the local time zone; the
/// header of a daily template might read `path: daily/{{date:yyyy}}/{{date:MM-MMMM}}` (TP-8).
/// `{{title}}` is the title words typed after the template name (TP-5). `{{cursor}}` marks the
/// caret in the body and is removed; in a path it is not a token. Anything else between
/// `{{` and `}}`, an empty date format included, is unknown and left as literal text.
public enum TemplateParser {
    /// The parts of a parsed template, tokens unexpanded.
    public struct Template: Hashable, Sendable {
        /// The `path` header value, trimmed, tokens unexpanded: a relative path without
        /// extension once expanded (TP-4).
        public let path: String
        /// Everything after the closing `---` line, tokens unexpanded.
        public let body: String

        public init(path: String, body: String) {
            self.path = path
            self.body = body
        }

        /// True when the path contains `{{title}}`, so instantiating without a title would
        /// name a file with a hole in it; TP-5 asks for one instead.
        public var pathNeedsTitle: Bool {
            Tokenizer.pieces(of: path, cursorIsToken: false).contains(.title)
        }

        /// `path` with its tokens replaced (TP-3). `{{cursor}}` is left literal: it is a body
        /// token, and a path is judged by C-3 afterwards.
        public func expandedPath(title: String, in environment: Environment = Environment()) -> String {
            TemplateParser.expandPath(path, title: title, in: environment)
        }

        /// `body` with its tokens replaced and `{{cursor}}` removed (TP-3).
        public func expandedBody(title: String, in environment: Environment = Environment()) -> ExpandedBody {
            TemplateParser.expandBody(body, title: title, in: environment)
        }
    }

    /// Why a template cannot be used (TP-2). `message` is the text shown inline.
    public enum Rejection: Error, Hashable, Sendable {
        /// The file does not start with a `---` line.
        case missingHeader
        /// The header opened with `---` and no later line closes it.
        case unterminatedHeader
        /// The header has no `path` key, or its value is empty.
        case missingPath

        public var message: String {
            switch self {
            case .missingHeader:
                return "This template has no header: it must start with a \u{201C}---\u{201D} line."
            case .unterminatedHeader:
                return "This template's header is not closed with a \u{201C}---\u{201D} line."
            case .missingPath:
                return "This template's header has no \u{201C}path\u{201D}."
            }
        }
    }

    /// What `{{date:FORMAT}}` is evaluated against. The defaults are now, in the local time
    /// zone, calendar and locale (TP-3); tests pin all four.
    public struct Environment: Sendable {
        public var date: Date
        public var timeZone: TimeZone
        public var calendar: Calendar
        public var locale: Locale

        public init(
            date: Date = Date(),
            timeZone: TimeZone = .current,
            calendar: Calendar = .current,
            locale: Locale = .current
        ) {
            self.date = date
            self.timeZone = timeZone
            self.calendar = calendar
            self.locale = locale
        }
    }

    /// An expanded body and where the caret goes.
    public struct ExpandedBody: Hashable, Sendable {
        /// The body with tokens replaced and every `{{cursor}}` removed.
        public let text: String
        /// The UTF-16 offset in `text` where the first `{{cursor}}` stood, as `NSRange` counts
        /// it, or nil when the body had none: the caret then goes to the end (TP-4).
        public let cursorOffset: Int?

        public init(text: String, cursorOffset: Int?) {
            self.text = text
            self.cursorOffset = cursorOffset
        }
    }

    /// The line that opens and closes the header (TP-2).
    public static let headerFence = "---"
    /// The one recognised header key (TP-2).
    public static let pathKey = "path"

    // MARK: Header (TP-2)

    /// Splits `text` into header values and body, and requires `path`. Lines end at `\n` or
    /// `\r\n`, so a CRLF file parses the same. Only the fence lines must be exactly `---`
    /// (trailing whitespace allowed); header lines are `key: value` with both sides trimmed,
    /// and anything else in the header is ignored. The body is the text after the closing
    /// fence's line break, byte for byte.
    public static func parse(_ text: String) throws(Rejection) -> Template {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: isLineBreak)[...]
        guard let first = lines.popFirst(), isFence(first) else { throw .missingHeader }
        var path: String?
        var bodyStart: String.Index?
        while let line = lines.popFirst() {
            if isFence(line) {
                bodyStart = line.endIndex
                break
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == pathKey, path == nil { path = value }
        }
        guard var bodyStart else { throw .unterminatedHeader }
        guard let path, !path.isEmpty else { throw .missingPath }
        if bodyStart < text.endIndex, isLineBreak(text[bodyStart]) { bodyStart = text.index(after: bodyStart) }
        return Template(path: path, body: String(text[bodyStart...]))
    }

    private static func isFence(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == headerFence
    }

    /// `\r\n` is one `Character`, so a character test covers both line endings.
    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n"
    }

    // MARK: Tokens (TP-3)

    /// `path` with `{{date:FORMAT}}` and `{{title}}` replaced. `{{cursor}}` and unknown tokens
    /// stay literal.
    public static func expandPath(_ path: String, title: String, in environment: Environment = Environment()) -> String
    {
        var out = ""
        for piece in Tokenizer.pieces(of: path, cursorIsToken: false) {
            out += expansion(of: piece, title: title, in: environment)
        }
        return out
    }

    /// `body` with `{{date:FORMAT}}` and `{{title}}` replaced and every `{{cursor}}` removed;
    /// the first `{{cursor}}` decides `cursorOffset`. Unknown tokens stay literal.
    public static func expandBody(_ body: String, title: String, in environment: Environment = Environment())
        -> ExpandedBody
    {
        var out = ""
        var cursorOffset: Int?
        for piece in Tokenizer.pieces(of: body, cursorIsToken: true) {
            if piece == .cursor {
                if cursorOffset == nil { cursorOffset = out.utf16.count }
                continue
            }
            out += expansion(of: piece, title: title, in: environment)
        }
        return ExpandedBody(text: out, cursorOffset: cursorOffset)
    }

    private static func expansion(of piece: Tokenizer.Piece, title: String, in environment: Environment) -> String {
        switch piece {
        case .literal(let text):
            return text
        case .title:
            return title
        case .cursor:
            return ""
        case .date(let format):
            let formatter = DateFormatter()
            formatter.calendar = environment.calendar
            formatter.timeZone = environment.timeZone
            formatter.locale = environment.locale
            formatter.dateFormat = format
            return formatter.string(from: environment.date)
        }
    }

    /// Splits template text into literal runs and recognised tokens. A `{{` that is not
    /// followed by a recognised name and `}}` is literal text, and scanning resumes one
    /// character on, so `{{x {{title}}` yields the literal `{{x ` and then the title token,
    /// and `{{{title}}}` the title between single braces.
    enum Tokenizer {
        enum Piece: Hashable {
            case literal(String)
            case date(String)
            case title
            case cursor
        }

        static let open = "{{"
        static let close = "}}"
        static let datePrefix = "date:"

        static func pieces(of text: String, cursorIsToken: Bool) -> [Piece] {
            var pieces: [Piece] = []
            var literal = ""
            var rest = text[...]
            func flush() {
                if !literal.isEmpty {
                    pieces.append(.literal(literal))
                    literal = ""
                }
            }
            while let openRange = rest.range(of: open) {
                literal += rest[..<openRange.lowerBound]
                let afterOpen = rest[openRange.upperBound...]
                if let closeRange = afterOpen.range(of: close),
                    let token = recognise(afterOpen[..<closeRange.lowerBound], cursorIsToken: cursorIsToken)
                {
                    flush()
                    pieces.append(token)
                    rest = afterOpen[closeRange.upperBound...]
                } else {
                    literal += "{"
                    rest = rest[rest.index(after: openRange.lowerBound)...]
                }
            }
            literal += rest
            flush()
            return pieces
        }

        private static func recognise(_ name: Substring, cursorIsToken: Bool) -> Piece? {
            if name == "title" { return .title }
            if name == "cursor" { return cursorIsToken ? .cursor : nil }
            if name.hasPrefix(datePrefix) {
                let format = name.dropFirst(datePrefix.count)
                return format.isEmpty ? nil : .date(String(format))
            }
            return nil
        }
    }
}
