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
/// It is also the text view's delegate: Escape in the editor is handed to `onCancel` (S-7)
/// instead of the text view's default, which offers completions.
@MainActor
public final class EditorController: NSObject, NSTextViewDelegate {
    /// How long after the last edit the note is written (E-4).
    nonisolated public static let autosaveDelay: TimeInterval = 0.3

    public let textView: NSTextView

    /// Called on Escape in the editor (S-7: clear the query and return to the search field).
    public var onCancel: (@MainActor () -> Void)?

    /// The note the editor shows, or is about to show once its read completes.
    public private(set) var noteID: NoteID?

    /// What was read for `noteID`, or what was last written for it; nil until the read
    /// completes, or when it failed.
    public private(set) var body: NoteBody?

    /// True while the text view holds edits that have not been handed to a write.
    public private(set) var hasUnsavedEdits = false

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

    public init(textView: NSTextView, clock: any AutosaveClock = SystemAutosaveClock()) {
        self.textView = textView
        self.clock = clock
        super.init()
        textView.isEditable = false
        textView.delegate = self
    }

    // MARK: - NSTextViewDelegate

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let onCancel {
            onCancel()
            return true
        }
        return false
    }

    /// An edit by the user. Programmatic replacement of the text, as `load` does, never
    /// arrives here. Restarts the autosave delay (E-4).
    public func textDidChange(_ notification: Notification) {
        guard noteID != nil, body?.isWritable == true else { return }
        hasUnsavedEdits = true
        pendingSave?.cancel()
        pendingSave = clock.schedule(at: clock.now.addingTimeInterval(Self.autosaveDelay)) { [weak self] in
            self?.autosaveTimerFired()
        }
    }

    // MARK: - Loading (S-8)

    /// Writes any unsaved edits to the note shown now (E-4), then reads `id` from `library` in
    /// the background and shows it. A body that must not be written back (undecodable, not yet
    /// downloaded, unreadable) is shown read-only (L-7, L-8).
    public func load(_ id: NoteID, from library: LibraryController) {
        flush()
        generation += 1
        let generation = generation
        noteID = id
        body = nil
        self.library = library
        let store = library.store
        queue.async { [self] in
            let body = try? store.read(id)
            if body == .notDownloaded { store.requestDownload(of: id) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.receive(body, for: id, generation: generation)
                }
            }
        }
    }

    /// Writes any unsaved edits (E-4), then empties the editor. Any read in flight is dropped.
    public func clear() {
        flush()
        generation += 1
        noteID = nil
        body = nil
        library = nil
        textView.string = ""
        textView.isEditable = false
        onLoad?(nil)
    }

    private func receive(_ body: NoteBody?, for id: NoteID, generation: Int) {
        guard generation == self.generation else { return }
        self.body = body
        // The text is being replaced, so nothing typed into the old text is pending any more.
        cancelPendingSave()
        hasUnsavedEdits = false
        textView.string = body?.displayText ?? ""
        textView.isEditable = body?.isWritable ?? false
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        onLoad?(id)
    }

    // MARK: - Autosave (E-4)

    /// Writes the note now if it has unsaved edits: on note switch, window focus loss and quit
    /// (E-4). `completion` runs on the main thread once the write has landed or failed, or at
    /// once when there was nothing to write. The write itself runs off the main thread (PF-6).
    public func flush(completion: (@MainActor () -> Void)? = nil) {
        cancelPendingSave()
        guard hasUnsavedEdits, let noteID, let library else {
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
