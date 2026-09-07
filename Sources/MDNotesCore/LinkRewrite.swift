import Foundation

/// Rewrites the wikilinks that pointed at a renamed note so they point at its new name (R-3).
/// Pure: nothing here touches disk. `LibraryController.rename` reads the files, applies the
/// plan and writes them back atomically.
///
/// A rename changes a note's title (L-5) and with it its path (L-4), so a link written either
/// way stops resolving. `plan(renaming:to:in:)` asks the link index, before the rename, which
/// other notes have links that resolve to the note (K-2, K-5) and what each of those links
/// should say afterwards: a link by title gets the new title, a link by path gets the new
/// path, so a path-qualified link stays path-qualified and a bare title stays bare. Only links
/// that resolved to the note are touched: a bare title that resolved to another candidate of
/// an ambiguous title (K-2) is that note's link, not this one's, and an embed never resolves
/// to a note (K-1). The renamed note's own links to itself are left alone: R-3 rewrites
/// other notes, and the renamed note may be open in the editor.
///
/// `rewriting(_:replacing:)` applies such a plan to one body, replacing only the target text
/// between the brackets: a label after `|`, the spacing inside the brackets and everything
/// else in the file survive byte for byte. A link inside a code span or fenced block is not a
/// link and is left as written (T-1 for tags, and the same scanner for links).
public enum LinkRewrite {
    /// Folded link target text, as `LinkTarget.key` spells it, to the text that replaces it.
    public typealias Replacements = [String: String]

    /// For every note other than `id` with a link that resolves to `id` in `links`, the
    /// replacements to make in its body once `id` is renamed to `newID`: the folded target of
    /// each such link to the new title, or the new path (without extension, L-4) when the
    /// link was by path. Empty when nothing links to the note. Renaming a note to itself
    /// plans nothing.
    public static func plan(renaming id: NoteID, to newID: NoteID, in links: LinkIndex) -> [NoteID: Replacements] {
        if id == newID { return [:] }
        var plan: [NoteID: Replacements] = [:]
        let byTitle = newID.title
        let byPath = NoteCreation.queryForm(of: newID)
        for source in links.backlinks(to: id) where source != id {
            var replacements: Replacements = [:]
            for target in links.outgoing(of: source) where !target.isEmbed && links.resolve(target).target == id {
                replacements[target.key] = target.key.contains("/") ? byPath : byTitle
            }
            if !replacements.isEmpty { plan[source] = replacements }
        }
        return plan
    }

    /// `text` with the target of every wikilink whose folded target is a key of `replacements`
    /// replaced by that key's value, or nil when no link matched and the text is unchanged.
    /// Embeds and links inside code are never rewritten.
    public static func rewriting(_ text: String, replacing replacements: Replacements) -> String? {
        if replacements.isEmpty || text.isEmpty { return nil }
        let source = text as NSString
        var edits: [(range: NSRange, replacement: String)] = []
        for token in MarkdownScanner.scan(text) {
            guard case .wikilink(let target, _, let isEmbed) = token.kind, !isEmbed else { continue }
            let written = source.substring(with: target)
            guard let replacement = replacements[CaseFolding.fold(written)], replacement != written else { continue }
            edits.append((target, replacement))
        }
        if edits.isEmpty { return nil }
        let result = NSMutableString(string: text)
        // Back to front, so each edit's range is still where the scanner found it.
        for edit in edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}
