import Foundation

/// Turns a template plus a title into the note it creates or opens (TP-4). `plan(_:title:in:)`
/// is pure: it expands the template's `path` (TP-3), judges the result by the same rules as
/// a query typed into the search field (C-3) and expands the body. `NoteStore.instantiate(_:)`
/// does the disk half: an existing `<path>.md` is opened and nothing is written; otherwise
/// the folders are made and the file written with the expanded body.
public enum TemplateInstantiation {
    /// What a template expands to for one title: the note it names and the body it would be
    /// created with.
    public struct Plan: Hashable, Sendable {
        public let id: NoteID
        public let body: TemplateParser.ExpandedBody

        public init(id: NoteID, body: TemplateParser.ExpandedBody) {
            self.id = id
            self.body = body
        }
    }

    /// Why a template cannot be instantiated. `message` is the text shown inline; it is also
    /// the `localizedDescription`, so a caller that only has `any Error` shows the same text.
    public enum Rejection: Error, Hashable, Sendable, LocalizedError {
        /// The template itself is unusable (TP-2).
        case template(TemplateParser.Rejection)
        /// The expanded path, given here, breaks a C-3 rule (TP-4).
        case path(String, NoteCreation.Rejection)

        public var message: String {
            switch self {
            case .template(let rejection):
                return rejection.message
            case .path(let path, .empty):
                return "This template's path expands to nothing (\u{201C}\(path)\u{201D})."
            case .path(_, let rejection):
                return rejection.message
            }
        }

        public var errorDescription: String? { message }
    }

    /// The outcome of `NoteStore.instantiate(_:)`.
    public struct Outcome: Hashable, Sendable {
        /// The note that was created or found.
        public let id: NoteID
        /// The file's modification date after the call.
        public let modifiedAt: Date
        /// False when `<path>.md` already existed and was left untouched.
        public let created: Bool
        /// Where the caret goes when the file was created, as a UTF-16 offset into its text:
        /// the body's `{{cursor}}`, or the end of the text when it had none (TP-4). Nil when
        /// the file was found, which leaves the caret where opening it puts it.
        public let cursorOffset: Int?

        public init(id: NoteID, modifiedAt: Date, created: Bool, cursorOffset: Int?) {
            self.id = id
            self.modifiedAt = modifiedAt
            self.created = created
            self.cursorOffset = cursorOffset
        }
    }

    /// Expands `template` for `title` (TP-3) and names the note its path makes (TP-4). The
    /// path is judged as a query would be, trimmed and under C-3: a `:` or NUL, an empty,
    /// `.`, `..` or hidden segment, or a first segment of `Trash` or `templates` is refused
    /// and nothing can be created from it. `{{cursor}}` in a path is literal text, so it is
    /// refused only if it breaks a rule, which it does not.
    public static func plan(
        _ template: TemplateParser.Template, title: String, in environment: TemplateParser.Environment = .init()
    ) throws(Rejection) -> Plan {
        let path = template.expandedPath(title: title, in: environment)
        let id: NoteID
        do {
            id = try NoteCreation.noteID(forQuery: path)
        } catch {
            throw .path(path, error)
        }
        return Plan(id: id, body: template.expandedBody(title: title, in: environment))
    }

    /// `plan(_:title:in:)` for what `TemplateStore.read(_:)` returns: a template that did not
    /// parse is refused with its own reason (TP-2).
    public static func plan(
        _ parsed: Result<TemplateParser.Template, TemplateParser.Rejection>, title: String,
        in environment: TemplateParser.Environment = .init()
    ) throws(Rejection) -> Plan {
        switch parsed {
        case .success(let template):
            return try plan(template, title: title, in: environment)
        case .failure(let rejection):
            throw .template(rejection)
        }
    }
}

extension NoteStore {
    /// TP-4: if the file behind `plan.id` exists it is left untouched and reported as found;
    /// otherwise its folders are made and it is written with the expanded body, atomically
    /// (E-5). Synchronous file I/O: call it off the main thread (PF-6).
    public func instantiate(_ plan: TemplateInstantiation.Plan) throws -> TemplateInstantiation.Outcome {
        let creation = try create(plan.id, body: plan.body.text)
        return TemplateInstantiation.Outcome(plan: plan, creation: creation)
    }
}

extension TemplateInstantiation.Outcome {
    /// The outcome of writing `plan` with `creation`: the caret is resolved to `{{cursor}}` or
    /// the end of the body for a created file, and left nil for one that was found.
    public init(plan: TemplateInstantiation.Plan, creation: NoteStore.Creation) {
        self.init(
            id: plan.id, modifiedAt: creation.modifiedAt, created: creation.created,
            cursorOffset: creation.created ? plan.body.cursorOffset ?? plan.body.text.utf16.count : nil)
    }
}
