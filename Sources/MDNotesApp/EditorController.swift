import AppKit
import Foundation
import MDNotesCore

/// Loads notes into the editor's text view (S-8) and writes them back (E-4). The body is read
/// on a background queue (PF-6) and applied on the main thread; a load that finishes after a
/// newer one started is dropped. Loading never touches first responder, so selecting rows
/// leaves focus in the list.
///
/// Autosave (E-4): every edit restarts a timer on `clock`; when `autosaveDelay` passes with no
/// further edit the text is written. Switching note or clearing the editor writes at once, as
/// do `flush()` callers for window focus loss and quit. Writes go through
/// `LibraryController.save`, which is atomic (E-5) and records the write for the watcher to
/// ignore (E-6). Reads and writes share one serial queue, so a note reopened right after a
/// switch shows what was just written.
///
/// Undo is per note (E-7): each note the editor has shown owns an `UndoManager`, handed to the
/// text view through the delegate, so Cmd-Z in one note never touches another and a note's
/// stack is still there after switching away and back within the session. Loading replaces
/// the text without registering anything. A stack only replays against the text it was
/// recorded on, so if a note's text has changed on disk while it was away the stack is
/// discarded rather than applied to the wrong ranges.
///
/// External changes to the shown note (X-2 to X-4) are reported by the window controller, which
/// hears about them from the library. A change on disk with no unsaved edits is reread through
/// `reloadFromDisk()`, keeping the selection where it still fits (X-2); with unsaved edits
/// nothing happens here, and the pending autosave writes the editor's text over the disk
/// version (X-3). A deletion goes through `noteWasDeleted()` (X-4): a clean editor is cleared;
/// one with unsaved edits keeps them in the view, `holdsEditsOfDeletedNote` is set, and no
/// write happens until the user types again, which recreates the file.
///
/// It is also the text view's delegate: Escape in the editor is handed to `onCancel` (S-7)
/// instead of the text view's default, which offers completions.
///
/// Wikilinks are styled by `styler` against the snapshot's link index (K-2): the one the
/// library the shown note belongs to has published. When a new snapshot arrives the window
/// controller calls `refreshLinkStyling()`, so a title that became ambiguous, or stopped being
/// so, changes colour without an edit.
///
/// The `[[` completion popover (K-4) is `linkCompletion` and the `#` completion popover (T-3)
/// is `tagCompletion`, one `CompletionController` each. The delegate feeds both: every change
/// to the text may open or re-filter a session, every caret move may re-filter or end one, and
/// while a list is showing the command selectors it takes (Return, Escape, Up, Down) go to it
/// before Escape can reach `onCancel`. Their titles and tags come from the snapshot of the
/// library the shown note belongs to. Replacing the editor's text or losing focus dismisses
/// them. The two triggers cannot both be open: a `#` right after `[[` is not where a tag
/// begins, and a `[` is not a tag character.
///
/// A plain click on a tag (T-4) is intercepted by `EditorTextView` and handed to the window
/// controller; `tag(at:)` is what names the tag under the pointer.
///
/// The storage may show display-only thumbnail attachments below image embeds (E-9,
/// ADR-0012), added and removed through `addAttachment` and `removeAttachments`. They are not
/// in the file and are not edits: `text` is the one accessor for the file's text and leaves
/// them out, the save writes `text`, the undo bookkeeping compares `text`, and the link and tag
/// lookups map the storage index they are given through `EditorText` before scanning. Adding
/// or removing one neither starts the autosave delay nor registers with undo. Which embeds get
/// one, and when it goes, is `thumbnails`' business: it hears of every character edit from the
/// storage delegate and reconciles the paragraphs around it once the edit is over.
@MainActor
public final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    /// How long after the last edit the note is written (E-4).
    nonisolated public static let autosaveDelay: TimeInterval = 0.3

    public let textView: NSTextView

    /// E-2, E-3: styles the text view's storage, paragraph by paragraph as it is edited.
    public let styler: EditorStyler

    /// E-9: keeps a thumbnail below every image embed that resolves, and only those.
    public let thumbnails: EditorThumbnails

    /// K-4: the `[[` completion popover over this editor's text.
    public let linkCompletion: CompletionController

    /// T-3: the `#` completion popover over this editor's text.
    public let tagCompletion: CompletionController

    /// Both popovers, in the order they are offered a key.
    private var completions: [CompletionController] { [linkCompletion, tagCompletion] }

    /// Called on Escape in the editor (S-7: clear the query and return to the search field).
    public var onCancel: (@MainActor () -> Void)?

    /// The note the editor shows, or is about to show once its read completes.
    public private(set) var noteID: NoteID?

    /// What was read for `noteID`, or what was last written for it; nil until the read
    /// completes, or when it failed.
    public private(set) var body: NoteBody?

    /// True while the text view holds edits that have not been handed to a write.
    public private(set) var hasUnsavedEdits = false

    /// X-4: true while the view holds unsaved edits of a note whose file was deleted on disk.
    /// They are written, recreating the file, only once the user types again; until then a
    /// `flush()` (note switch, focus loss, quit) writes nothing, and loading another note or
    /// clearing the editor drops them.
    public private(set) var holdsEditsOfDeletedNote = false

    /// L-7, L-8: why the shown body is read-only, or nil while it is writable or nothing is
    /// shown. Set as each load lands and cleared by the next.
    public private(set) var readOnlyNotice: String?

    /// Called on the main thread with `readOnlyNotice` whenever a load changes it.
    public var onReadOnlyNoticeChange: (@MainActor (String?) -> Void)?

    /// Called on the main thread once the text view shows `noteID` (or nothing, after `clear()`).
    public var onLoad: (@MainActor (NoteID?) -> Void)?

    /// Called on the main thread when a write of a note's text has landed, with the file's new
    /// modification date, or failed.
    public var onSave: (@MainActor (NoteID, Result<Date, any Error>) -> Void)?

    private let clock: any AutosaveClock
    private var pendingSave: (any AutosaveTimer)?
    /// The library `noteID` belongs to; the target of its writes, and where `thumbnails` has
    /// embed targets looked up (I-2).
    private(set) var library: LibraryController?

    private let queue = DispatchQueue(label: "MDNotes.EditorController", qos: .userInitiated)
    /// Bumped by every `load` and `clear`; a read or write result tagged with an older value
    /// is dropped.
    private var generation = 0
    /// `placeCaret(at:in:)` for a note whose load has not landed yet (TP-4): the note and the
    /// UTF-16 file offset the caret goes to once it has.
    private var pendingCaret: (id: NoteID, offset: Int)?

    /// The undo stack of one note (E-7), kept for the session.
    @MainActor
    private final class NoteUndo {
        let manager = UndoManager()
        /// The text the view showed when the note was last switched away from; nil while the
        /// note is shown or has never been shown. Checked on reload before the stack is reused.
        var textWhenLeft: String?
    }
    private var undoStacks: [NoteID: NoteUndo] = [:]
    /// The note whose text the view holds: set once a read lands, nil while one is in flight.
    /// Edits made in the gap register nowhere that matters.
    private var shownNoteID: NoteID?
    /// Collects registrations made while no note is shown; thrown away on the next load.
    private var scratchUndoManager: UndoManager
    /// True while the controller itself is replacing the text, so the storage's edit
    /// notification is not taken for a user edit.
    private var isReplacingText = false
    /// True while a display-only attachment run is being added or removed (E-9), so the
    /// storage's edit notification is neither styled nor taken for a user edit.
    private var isEditingAttachments = false

    /// `thumbnails` is the cache the inline thumbnails come from (E-9, PF-8); the window
    /// controller passes the one its list rows use.
    public init(
        textView: NSTextView, clock: any AutosaveClock = SystemAutosaveClock(),
        thumbnails cache: ThumbnailCache = ThumbnailCache()
    ) {
        self.textView = textView
        self.clock = clock
        styler = EditorStyler(textView: textView, baseFont: textView.font ?? EditorFontPreference.font())
        thumbnails = EditorThumbnails(cache: cache)
        linkCompletion = CompletionController(textView: textView, rules: LinkCompletionRules())
        tagCompletion = CompletionController(textView: textView, rules: TagCompletionRules())
        scratchUndoManager = UndoManager()
        super.init()
        thumbnails.editor = self
        textView.isEditable = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textStorage?.delegate = self
        // K-4, T-3: the popovers list the titles and tags of the library the shown note
        // belongs to.
        for completion in completions {
            completion.index = { [weak self] in self?.library?.snapshot ?? .empty }
        }
        // K-2: links are resolved against the same snapshot, so an ambiguous title is styled
        // as ambiguous the moment it is loaded or typed.
        styler.linkIndex = { [weak self] in self?.library?.snapshot.links ?? .empty }
    }

    /// K-2: the snapshot changed, so a link's resolution may have changed under text that did
    /// not. Called when the library publishes; the styler re-styles the links it changed.
    public func refreshLinkStyling() {
        styler.restyleLinks()
    }

    // MARK: - The file's text (E-9)

    /// The text as the file holds it: the view's text without the display-only attachment
    /// characters (E-9, ADR-0012). The one accessor every reader of the view's text uses; the
    /// save writes exactly this.
    public var text: String { editorText.string }

    /// The file's text with the mapping between its indices and the storage's.
    private var editorText: EditorText {
        EditorText(storage: textView.textStorage ?? NSTextStorage())
    }

    /// The storage ranges of the display-only attachment runs (E-9), ascending; empty while
    /// none is shown.
    public var attachmentRanges: [NSRange] { editorText.displayOnlyRanges }

    /// Shows `attachment` on a line of its own directly below the line containing storage index
    /// `index` (E-9), after any attachment already below that line; an index on an attachment
    /// line counts as the line the attachment is below. The two characters added, a line break
    /// and the attachment character, both carry `EditorText.displayOnlyAttribute` and are the
    /// only way a display-only run comes to be: `text` leaves them out, the storage delegate
    /// does not take them for an edit (E-4) and nothing registers with undo (E-7). A caret at
    /// or after the insertion point moves with the text it was in.
    public func addAttachment(_ attachment: NSTextAttachment, belowLineContaining index: Int) {
        guard let storage = textView.textStorage else { return }
        let text = editorText
        let onFileText = text.storageIndex(forFileIndex: text.fileIndex(forStorageIndex: index))
        let backing = storage.mutableString
        var contentsEnd = 0
        backing.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: onFileText, length: 0))
        var at = contentsEnd
        while let run = text.displayOnlyRanges.first(where: { $0.location == at }) { at = NSMaxRange(run) }

        let run = NSMutableAttributedString(string: "\n")
        run.append(NSAttributedString(attachment: attachment))
        run.addAttributes(
            [EditorText.displayOnlyAttribute: true, .font: styler.baseFont, .foregroundColor: styler.baseColor],
            range: NSRange(location: 0, length: run.length))
        editAttachments {
            storage.insert(run, at: at)
        }
    }

    /// Removes the display-only attachments that `range`, a storage range, overlaps (E-9): every
    /// one when `range` is nil, and for an empty range the one containing its location. An
    /// attachment is the line break and attachment character `addAttachment` put in together,
    /// so one of several stacked below a line can go on its own. Not an edit and not undoable,
    /// as `addAttachment` is not.
    public func removeAttachments(in range: NSRange? = nil) {
        guard let storage = textView.textStorage else { return }
        let backing = storage.mutableString
        let pieces = editorText.displayOnlyRanges.flatMap { Self.pieces(of: $0, in: backing) }.filter { piece in
            guard let range else { return true }
            return range.length == 0
                ? NSLocationInRange(range.location, piece) : NSIntersectionRange(piece, range).length > 0
        }
        guard !pieces.isEmpty else { return }
        editAttachments {
            for piece in pieces.reversed() { storage.deleteCharacters(in: piece) }
        }
    }

    /// `run`, a display-only run, cut into the attachments it holds: each a line break followed
    /// by an attachment character, as `addAttachment` made them. A character of the run that
    /// is not part of such a pair is a piece of its own.
    private static func pieces(of run: NSRange, in backing: NSMutableString) -> [NSRange] {
        var pieces: [NSRange] = []
        var index = run.location
        let end = NSMaxRange(run)
        while index < end {
            if index + 1 < end, backing.character(at: index) == Self.lineBreak,
                backing.character(at: index + 1) == EditorText.attachmentCharacter
            {
                pieces.append(NSRange(location: index, length: 2))
                index += 2
            } else {
                pieces.append(NSRange(location: index, length: 1))
                index += 1
            }
        }
        return pieces
    }

    /// U+000A, the line break an attachment run begins with.
    nonisolated private static let lineBreak: UInt16 = 0x0A

    /// Runs `edit` on the storage as one editing pass with the delegate's edit handling off.
    private func editAttachments(_ edit: () -> Void) {
        guard let storage = textView.textStorage else { return }
        isEditingAttachments = true
        defer { isEditingAttachments = false }
        storage.beginEditing()
        edit()
        storage.endEditing()
    }

    /// Replaces the whole text without it counting as an edit or registering with undo (E-7).
    private func replaceText(with text: String) {
        isReplacingText = true
        defer { isReplacingText = false }
        // K-4, T-3: the trigger a session was anchored to is going with the text.
        dismissCompletions()
        textView.string = text
    }

    /// Ends any completion session (K-4, T-3): the popovers are taken down and the text is
    /// left as typed.
    public func dismissCompletions() {
        for completion in completions { completion.dismiss() }
    }

    /// Re-lists what the open completion sessions show (K-4, T-3). Called when the snapshot
    /// changes, so a list left showing keeps up with notes created, renamed or tagged.
    public func refreshCompletions() {
        for completion in completions { completion.refresh() }
    }

    // MARK: - NSTextViewDelegate

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // K-4, T-3: while a completion list is showing, its keys are the popover's.
        for completion in completions where completion.handle(commandSelector) { return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let onCancel {
            onCancel()
            return true
        }
        return false
    }

    /// K-4, T-3: the text changed under the caret, by typing, paste or a completion. Opens a
    /// completion when `[[` or `#` was just typed, and re-filters or ends an open session.
    public func textDidChange(_ notification: Notification) {
        for completion in completions { completion.textDidChange() }
    }

    /// K-4, T-3: the caret moved. An open completion session re-filters, or ends if the caret
    /// left the trigger.
    public func textViewDidChangeSelection(_ notification: Notification) {
        for completion in completions { completion.selectionDidChange() }
    }

    /// K-4, T-3: the editor lost focus, so the completions are dismissed.
    public func textDidEndEditing(_ notification: Notification) {
        dismissCompletions()
    }

    /// E-7: the text view registers its edits with the shown note's own manager, so Cmd-Z and
    /// Cmd-Shift-Z (which reach the window and ask the first responder for its manager) act on
    /// that note alone.
    public func undoManager(for view: NSTextView) -> UndoManager? {
        guard let shownNoteID else { return scratchUndoManager }
        return undoStack(for: shownNoteID).manager
    }

    private func undoStack(for id: NoteID) -> NoteUndo {
        if let stack = undoStacks[id] { return stack }
        let stack = NoteUndo()
        undoStacks[id] = stack
        return stack
    }

    /// Closes the shown note's typing run and remembers the text its stack was recorded on,
    /// before the view moves on to another note or to nothing.
    private func leaveShownNote() {
        textView.breakUndoCoalescing()
        if let shownNoteID {
            undoStack(for: shownNoteID).textWhenLeft = text
        }
        shownNoteID = nil
        scratchUndoManager = UndoManager()
    }

    // MARK: - NSTextStorageDelegate

    /// An edit to the text: typing, paste, undo and redo all pass through here, which is why
    /// the signal is the storage's and not the text view's `textDidChange` (undo does not post
    /// that). Attribute-only changes, such as the font preference (E-8) and the styler's own
    /// work, are not edits. The styler re-styles the paragraphs around the edit first (E-2,
    /// E-3); it does so here rather than before processing because attribute changes made
    /// while the character edit is being processed widen its range, and the text view then
    /// moves the insertion point to the end of the widened range instead of past the typed
    /// character. The thumbnails hear of the edit too, and reconcile the paragraphs around it
    /// once the storage is done (E-9). Then, unless the replacement is programmatic, as
    /// `load`'s is, the autosave delay restarts (E-4). A display-only attachment run being
    /// added or removed (E-9) is none of these: the text it belongs to is unchanged. The
    /// protocol is not main-actor isolated in the SDK, but the storage belongs to a view that
    /// is only ever edited on the main thread.
    nonisolated public func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard !isEditingAttachments else { return }
            styler.restyleAfterEdit(in: editedRange)
            thumbnails.textDidChange(in: editedRange, changeInLength: delta)
            textDidEdit()
        }
    }

    private func textDidEdit() {
        guard !isReplacingText, noteID != nil, body?.isWritable == true else { return }
        // X-4: typing again is what brings a deleted note's file back.
        holdsEditsOfDeletedNote = false
        hasUnsavedEdits = true
        pendingSave?.cancel()
        pendingSave = clock.schedule(at: clock.now.addingTimeInterval(Self.autosaveDelay)) { [weak self] in
            self?.autosaveTimerFired()
        }
    }

    // MARK: - Links (K-3)

    /// The target of the wikilink the caret is in, or nil when it is not in one. The caret is
    /// the start of the selection.
    public func linkTargetAtCaret() -> LinkTarget? {
        linkTarget(at: textView.selectedRange().location)
    }

    /// The target of the wikilink or embed whose text, brackets included, contains the
    /// insertion index `index`, or nil when no link does. Both ends count: a caret just before
    /// the `[[` or just after the `]]` is touching the link, and a click resolved to an
    /// insertion index lands on an end when it hits the outer half of a bracket. Where two
    /// links meet, the earlier one wins. A `[[link]]` inside a code span or fenced block is not
    /// a link (E-2), so the paragraphs around the index are scanned as the styler scans them,
    /// with fenced blocks covered whole. `index` is a storage index (E-9): one on an attachment
    /// line counts as the end of the line above it, so a caret on a thumbnail is touching the
    /// embed that ends its line.
    public func linkTarget(at index: Int) -> LinkTarget? {
        guard let storage = textView.textStorage, index >= 0, index <= storage.length else { return nil }
        let text = editorText
        let index = text.fileIndex(forStorageIndex: index)
        let paragraphs = MarkdownScanner.paragraphRange(
            in: text.units, editedRange: NSRange(location: index, length: 0))
        for token in MarkdownScanner.scan(text.units, in: paragraphs) {
            guard case .wikilink(let target, _, let isEmbed) = token.kind else { continue }
            if token.range.location > index { break }
            guard index <= token.range.location + token.range.length else { continue }
            return LinkTarget(text: text.string(inFileRange: target), isEmbed: isEmbed)
        }
        return nil
    }

    // MARK: - Images (I-1)

    /// Inserts `![[name]]` at the caret, replacing the selection, as typing it would (I-1): the
    /// edit registers with the note's undo stack (E-7), is styled (E-2) and starts the autosave
    /// delay (E-4), and the caret ends after the closing brackets. Does nothing while no
    /// writable note is shown.
    public func insertEmbed(of name: String) {
        guard noteID != nil, body?.isWritable == true else { return }
        textView.insertText("![[\(name)]]", replacementRange: textView.selectedRange())
    }

    // MARK: - Tags (T-4)

    /// The tag whose text, `#` included, contains the character at `index`, as `#name`; nil
    /// when the character is not part of a tag. Unlike `linkTarget(at:)` this takes the index
    /// of a character, not an insertion index, because a click on a tag lands on one of its
    /// characters (`EditorTextView.characterIndex(under:)`); the space after a tag is not the
    /// tag. A `#word` inside a code span or fenced block is not a tag (T-1), so the paragraphs
    /// around the index are scanned as the styler scans them, with fenced blocks covered whole.
    public func tag(at index: Int) -> String? {
        let text = editorText
        guard let range = tagFileRange(at: index, in: text) else { return nil }
        return text.string(inFileRange: range)
    }

    /// The storage range of the tag containing the character at storage index `index`, `#`
    /// included, or nil. A character of an attachment line (E-9) is in no tag.
    public func tagRange(at index: Int) -> NSRange? {
        let text = editorText
        guard let range = tagFileRange(at: index, in: text) else { return nil }
        return text.storageRange(forFileRange: range)
    }

    /// The file range of the tag containing the character at storage index `index`, or nil.
    private func tagFileRange(at index: Int, in text: EditorText) -> NSRange? {
        guard let storage = textView.textStorage, index >= 0, index < storage.length,
            !text.displayOnlyRanges.contains(where: { NSLocationInRange(index, $0) })
        else { return nil }
        let index = text.fileIndex(forStorageIndex: index)
        let paragraphs = MarkdownScanner.paragraphRange(
            in: text.units, editedRange: NSRange(location: index, length: 0))
        for token in MarkdownScanner.scan(text.units, in: paragraphs) {
            guard case .tag = token.kind else { continue }
            if token.range.location > index { break }
            guard index < token.range.location + token.range.length else { continue }
            return token.range
        }
        return nil
    }

    // MARK: - Loading (S-8)

    /// Writes any unsaved edits to the note shown now (E-4), then reads `id` from `library` in
    /// the background and shows it. A body that must not be written back (undecodable, not yet
    /// downloaded, unreadable) is shown read-only (L-7, L-8).
    public func load(_ id: NoteID, from library: LibraryController) {
        flush()
        holdsEditsOfDeletedNote = false
        leaveShownNote()
        noteID = id
        self.library = library
        if pendingCaret?.id != id { pendingCaret = nil }
        read(id, from: library, restoring: nil)
    }

    /// TP-4: puts the caret at `offset`, a UTF-16 offset into `id`'s file text, clamped to it.
    /// Applied at once when the editor already shows `id`; otherwise remembered and applied
    /// when the load of `id` in flight lands, in place of the start of the text. Forgotten by
    /// a load of another note or a `clear()`.
    public func placeCaret(at offset: Int, in id: NoteID) {
        if noteID == id, body != nil {
            let fileText = editorText
            let range = fileText.storageRange(
                forFileRange: Self.clamp(NSRange(location: offset, length: 0), to: fileText.string))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        } else {
            pendingCaret = (id, offset)
        }
    }

    /// X-2: the shown note changed on disk and the editor has no unsaved edits, so the file is
    /// reread and shown, with the selection kept where it still fits in the new text. With
    /// unsaved edits nothing is read: the editor's text is what the next autosave writes (X-3).
    public func reloadFromDisk() {
        guard let noteID, let library, !hasUnsavedEdits else { return }
        // The undo stack was recorded against the old text; `resumeUndo` keeps it only if the
        // reread text turns out to be the same (E-7).
        leaveShownNote()
        read(noteID, from: library, restoring: textView.selectedRange())
    }

    /// Reads `id` in the background and shows it; `selection` is what the view selects once
    /// the text is in, clamped to it, or the start when nil.
    private func read(_ id: NoteID, from library: LibraryController, restoring selection: NSRange?) {
        generation += 1
        let generation = generation
        body = nil
        let store = library.store
        queue.async { [self] in
            let body = try? store.read(id)
            if body == .notDownloaded { store.requestDownload(of: id) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.receive(body, for: id, generation: generation, restoring: selection)
                }
            }
        }
    }

    /// Writes any unsaved edits (E-4), then empties the editor. Any read in flight is dropped.
    public func clear() {
        flush()
        holdsEditsOfDeletedNote = false
        leaveShownNote()
        generation += 1
        noteID = nil
        body = nil
        library = nil
        pendingCaret = nil
        thumbnails.reset()
        replaceText(with: "")
        textView.isEditable = false
        setReadOnlyNotice(nil)
        onLoad?(nil)
    }

    /// X-4: the shown note's file is gone from disk. With no unsaved edits the editor is
    /// cleared, as `clear()` does. With unsaved edits the text stays in the view and the
    /// pending autosave is cancelled, so the file is not recreated behind the deletion; only
    /// typing again schedules a write, which recreates it. Does nothing while no note is shown.
    public func noteWasDeleted() {
        guard noteID != nil else { return }
        if hasUnsavedEdits {
            cancelPendingSave()
            holdsEditsOfDeletedNote = true
        } else {
            clear()
        }
    }

    /// R-2: the shown note's file has been renamed by us, so the same text now lives at `newID`.
    /// The editor follows: its note id, and the undo stack the note has built up (E-7), move to
    /// the new id; the text, selection and any unsaved edits stay untouched, and nothing is
    /// reread. Does nothing while no note is shown.
    public func noteWasRenamed(to newID: NoteID) {
        guard let oldID = noteID, oldID != newID else { return }
        noteID = newID
        if shownNoteID == oldID { shownNoteID = newID }
        if let stack = undoStacks.removeValue(forKey: oldID) { undoStacks[newID] = stack }
    }

    private func receive(_ body: NoteBody?, for id: NoteID, generation: Int, restoring selection: NSRange?) {
        guard generation == self.generation else { return }
        self.body = body
        // The text is being replaced, so nothing typed into the old text is pending any more.
        cancelPendingSave()
        hasUnsavedEdits = false
        let text = body?.displayText ?? ""
        // E-9: thumbnails still being looked up were for the text going away; the new text's
        // embeds are looked up as the replacement is reconciled.
        thumbnails.reset()
        replaceText(with: text)
        textView.isEditable = body?.isWritable ?? false
        setReadOnlyNotice(Self.readOnlyNotice(for: body))
        var selection = selection
        if let pendingCaret {
            // TP-4: the caret a template asked for lands with the note's first load; the
            // storage holds the file's text at this point, so the file offset is the storage's.
            if pendingCaret.id == id, selection == nil { selection = NSRange(location: pendingCaret.offset, length: 0) }
            self.pendingCaret = nil
        }
        let range = Self.clamp(selection ?? NSRange(location: 0, length: 0), to: text)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        resumeUndo(for: id, showing: text)
        onLoad?(id)
    }

    /// The one-line notice for a body the editor must not write back (L-7, L-8), or nil for a
    /// writable one. A nil body is a read that failed outright.
    public static func readOnlyNotice(for body: NoteBody?) -> String? {
        switch body {
        case .text: return nil
        case .invalidUTF8: return "This note is not valid UTF-8 and is shown read-only."
        case .notDownloaded: return "This note has not been downloaded from iCloud yet and is shown read-only."
        case nil: return "This note could not be read and is shown read-only."
        }
    }

    private func setReadOnlyNotice(_ notice: String?) {
        guard notice != readOnlyNotice else { return }
        readOnlyNotice = notice
        onReadOnlyNoticeChange?(notice)
    }

    /// `range` moved and shortened as needed to lie within `text` (X-2: "preserving selection
    /// where possible").
    private static func clamp(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    /// E-7: makes `id`'s stack the one the view registers with. If the note has changed since
    /// it was left, its stack was recorded against text the view no longer holds and is dropped.
    private func resumeUndo(for id: NoteID, showing text: String) {
        let stack = undoStack(for: id)
        if let left = stack.textWhenLeft, left != text {
            stack.manager.removeAllActions()
        }
        stack.textWhenLeft = nil
        shownNoteID = id
    }

    // MARK: - Autosave (E-4)

    /// Writes the note now if it has unsaved edits: on note switch, window focus loss and quit
    /// (E-4). `completion` runs on the main thread once the write has landed or failed, or at
    /// once when there was nothing to write. The write itself runs off the main thread (PF-6).
    /// The edits of a deleted note are not written here: X-4 has them re-saved only once the
    /// user types again.
    public func flush(completion: (@MainActor () -> Void)? = nil) {
        cancelPendingSave()
        guard hasUnsavedEdits, !holdsEditsOfDeletedNote, let noteID, let library else {
            completion?()
            return
        }
        hasUnsavedEdits = false
        // E-9: the file's text, without any display-only attachment characters.
        let text = text
        let generation = generation
        queue.async { [self] in
            let result = Result { try library.save(text, to: noteID) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.didSave(noteID, text: text, result: result, generation: generation)
                    completion?()
                }
            }
        }
    }

    private func autosaveTimerFired() {
        pendingSave = nil
        flush()
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    private func didSave(_ id: NoteID, text: String, result: Result<Date, any Error>, generation: Int) {
        switch result {
        case .success:
            if generation == self.generation { body = .text(text) }
        case .failure(let error):
            FileHandle.standardError.write(Data("MDNotes: could not save \(id): \(error)\n".utf8))
            // The text is still in the view: the next edit's timer or the next flush tries
            // again (X-4 wants a deleted note recreated by typing, not by a retry loop).
            if generation == self.generation { hasUnsavedEdits = true }
        }
        onSave?(id, result)
    }
}
