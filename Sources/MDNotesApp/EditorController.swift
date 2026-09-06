import AppKit
import MDNotesCore

/// Loads notes into the editor's text view (S-8). The body is read on a background queue
/// (PF-6) and applied on the main thread; a load that finishes after a newer one started is
/// dropped. Loading never touches first responder, so selecting rows leaves focus in the list.
@MainActor
public final class EditorController {
    public let textView: NSTextView

    /// The note the editor shows, or is about to show once its read completes.
    public private(set) var noteID: NoteID?

    /// What was read for `noteID`; nil until the read completes, or when it failed.
    public private(set) var body: NoteBody?

    /// Called on the main thread once the text view shows `noteID` (or nothing, after `clear()`).
    public var onLoad: (@MainActor (NoteID?) -> Void)?

    private let queue = DispatchQueue(label: "MDNotes.EditorController", qos: .userInitiated)
    /// Bumped by every `load` and `clear`; a read tagged with an older value is dropped.
    private var generation = 0

    public init(textView: NSTextView) {
        self.textView = textView
        textView.isEditable = false
    }

    /// Reads `id` from `store` in the background and shows it. A body that must not be written
    /// back (undecodable, not yet downloaded, unreadable) is shown read-only (L-7, L-8).
    public func load(_ id: NoteID, from store: NoteStore) {
        generation += 1
        let generation = generation
        noteID = id
        body = nil
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

    /// Empties the editor. Any read in flight is dropped.
    public func clear() {
        generation += 1
        noteID = nil
        body = nil
        textView.string = ""
        textView.isEditable = false
        onLoad?(nil)
    }

    private func receive(_ body: NoteBody?, for id: NoteID, generation: Int) {
        guard generation == self.generation else { return }
        self.body = body
        textView.string = body?.displayText ?? ""
        textView.isEditable = body?.isWritable ?? false
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        onLoad?(id)
    }
}
