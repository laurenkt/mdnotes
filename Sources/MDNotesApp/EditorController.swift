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
/// The `[[` completion popover (K-4) is `linkCompletion`. The delegate feeds it: every change
/// to the text may open or re-filter a session, every caret move may re-filter or end one, and
/// while its list is showing the command selectors it takes (Return, Escape, Up, Down) go to
/// it before Escape can reach `onCancel`. Its titles come from the snapshot of the library the
/// shown note belongs to. Replacing the editor's text or losing focus dismisses it.
@MainActor
public final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    /// How long after the last edit the note is written (E-4).
    nonisolated public static let autosaveDelay: TimeInterval = 0.3

    public let textView: NSTextView

    /// E-2, E-3: styles the text view's storage, paragraph by paragraph as it is edited.
    public let styler: EditorStyler

    /// K-4: the `[[` completion popover over this editor's text.
    public let linkCompletion: LinkCompletionController

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

    /// Called on the main thread once the text view shows `noteID` (or nothing, after `clear()`).
    public var onLoad: (@MainActor (NoteID?) -> Void)?

    /// Called on the main thread when a write of a note's text has landed, with the file's new
    /// modification date, or failed.
    public var onSave: (@MainActor (NoteID, Result<Date, any Error>) -> Void)?

    private let clock: any AutosaveClock
    private var pendingSave: (any AutosaveTimer)?
    /// The library `noteID` belongs to; the target of its writes.
    private var library: LibraryController?

    private let queue = DispatchQueue(label: "MDNotes.EditorController", qos: .userInitiated)
    /// Bumped by every `load` and `clear`; a read or write result tagged with an older value
    /// is dropped.
    private var generation = 0

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

    public init(textView: NSTextView, clock: any AutosaveClock = SystemAutosaveClock()) {
        self.textView = textView
        self.clock = clock
        styler = EditorStyler(textView: textView, baseFont: textView.font ?? EditorFontPreference.font())
        linkCompletion = LinkCompletionController(textView: textView)
        scratchUndoManager = UndoManager()
        super.init()
        textView.isEditable = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textStorage?.delegate = self
        // K-4: the popover lists the titles of the library the shown note belongs to.
        linkCompletion.index = { [weak self] in self?.library?.snapshot ?? .empty }
    }

    /// Replaces the whole text without it counting as an edit or registering with undo (E-7).
    private func replaceText(with text: String) {
        isReplacingText = true
        defer { isReplacingText = false }
        // K-4: the brackets a session was anchored to are going with the text.
        linkCompletion.dismiss()
        textView.string = text
    }

    // MARK: - NSTextViewDelegate

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // K-4: while the completion list is showing, its keys are the popover's.
        if linkCompletion.handle(commandSelector) { return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let onCancel {
            onCancel()
            return true
        }
        return false
    }

    /// K-4: the text changed under the caret, by typing, paste or a completion. Opens the
    /// completion when `[[` was just typed, and re-filters or ends an open session.
    public func textDidChange(_ notification: Notification) {
        linkCompletion.textDidChange()
    }

    /// K-4: the caret moved. An open completion session re-filters, or ends if the caret left
    /// the brackets.
    public func textViewDidChangeSelection(_ notification: Notification) {
        linkCompletion.selectionDidChange()
    }

    /// K-4: the editor lost focus, so the completion is dismissed.
    public func textDidEndEditing(_ notification: Notification) {
        linkCompletion.dismiss()
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
            undoStack(for: shownNoteID).textWhenLeft = textView.string
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
    /// character. Then, unless the replacement is programmatic, as `load`'s is, the autosave
    /// delay restarts (E-4). The protocol is not main-actor isolated in the SDK, but the
    /// storage belongs to a view that is only ever edited on the main thread.
    nonisolated public func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            styler.restyleAfterEdit(in: editedRange)
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
    /// with fenced blocks covered whole.
    public func linkTarget(at index: Int) -> LinkTarget? {
        guard let storage = textView.textStorage, index >= 0, index <= storage.length else { return nil }
        let units = EditorStyler.units(of: storage)
        let paragraphs = MarkdownScanner.paragraphRange(in: units, editedRange: NSRange(location: index, length: 0))
        for token in MarkdownScanner.scan(units, in: paragraphs) {
            guard case .wikilink(let target, _, let isEmbed) = token.kind else { continue }
            if token.range.location > index { break }
            guard index <= token.range.location + token.range.length else { continue }
            return LinkTarget(text: storage.mutableString.substring(with: target), isEmbed: isEmbed)
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
        read(id, from: library, restoring: nil)
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
        replaceText(with: "")
        textView.isEditable = false
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
        replaceText(with: text)
        textView.isEditable = body?.isWritable ?? false
        let range = Self.clamp(selection ?? NSRange(location: 0, length: 0), to: text)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        resumeUndo(for: id, showing: text)
        onLoad?(id)
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
        let text = textView.string
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
