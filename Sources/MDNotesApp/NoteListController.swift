import AppKit
import MDNotesCore

/// Data source and delegate of the note list (S-6). Shows one `SearchIndex.Results` at a time,
/// a view onto an immutable snapshot, so a reload is a `reloadData()` and nothing else (PF-2).
///
/// Selection is tracked by note id, not row: when a fresh snapshot moves the selected note to
/// another row it stays selected, and `onSelectionChange` fires only when the selected note
/// actually changes, never because the list around it was reloaded.
///
/// A title is renamed in place (R-1): a double-click on it, or `beginEditingTitle(ofRow:)` for
/// Cmd-R, turns the row's title label into a field with focus. Enter hands the new text to
/// `onCommitTitle`, whose owner validates and renames (R-2); a rejected title stays in the
/// field to be fixed. Escape reverts. Focus leaving the field commits a valid title and drops
/// an invalid one. While a title is being edited, `show(_:fallbackRow:)` is held back and
/// applied when the edit ends, so a snapshot arriving mid-edit cannot tear the field down.
@MainActor
public final class NoteListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// Every row is this tall (S-6).
    nonisolated public static let rowHeight: CGFloat = 46

    public let tableView: NSTableView

    /// What the list is showing, in row order.
    public private(set) var results: SearchIndex.Results

    /// The id of the selected row's note, kept across reloads.
    public private(set) var selectedID: NoteID?

    /// Called on the main thread when the selected note changes, with the new entry or nil when
    /// nothing is selected any more.
    public var onSelectionChange: (@MainActor (SearchIndex.Entry?) -> Void)?

    /// R-2: called on the main thread when the user commits an edited title that differs from
    /// the note's current one, with the note and the text as typed. Returns true to accept, in
    /// which case the edit ends; the receiver does the renaming. Returns false to reject, having
    /// shown why: after Enter the field stays up with the text to be fixed, after a focus loss
    /// the text is dropped.
    public var onCommitTitle: (@MainActor (NoteID, String) -> Bool)?

    /// The note whose title is being edited inline (R-1), or nil.
    public private(set) var editingTitleOfID: NoteID?
    private var editingRowView: NoteRowView?
    /// The last `show` made while a title was being edited, applied once the edit ends.
    private var deferredShow: (results: SearchIndex.Results, fallbackRow: Int?)?
    /// True while `endEditingTitle` itself moves focus off the field, so the field editor's
    /// end-of-editing notification is not taken for the user leaving the field.
    private var isEndingTitleEdit = false

    /// Formats each row's modified date (S-9).
    private let relativeDate = RelativeDateText()

    /// The instant the relative words are seen from. Tests substitute a fixed one.
    public var now: @MainActor () -> Date = { Date() }

    public init(tableView: NSTableView) {
        self.tableView = tableView
        results = SearchIndex.empty.query("")
        super.init()
        tableView.rowHeight = Self.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        // R-1: a double-click on a title edits it.
        tableView.target = self
        tableView.doubleAction = #selector(tableViewWasDoubleClicked(_:))
        // S-9: `Today` becomes `Yesterday` at midnight, and a window that comes back after
        // days away shows dates seen from now, not from when its rows were made.
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(dateRefreshNeeded(_:)), name: .NSCalendarDayChanged, object: nil)
        center.addObserver(
            self, selector: #selector(dateRefreshNeeded(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    /// The day change is not promised on the main thread, so this hops there when it must.
    /// Another window becoming key is not the list becoming visible and is ignored.
    @objc nonisolated private func dateRefreshNeeded(_ notification: Notification) {
        let name = notification.name
        let object = (notification.object as AnyObject?).map(ObjectIdentifier.init)
        let refresh: @MainActor () -> Void = {
            if name == NSWindow.didBecomeKeyNotification, object != self.tableView.window.map(ObjectIdentifier.init) {
                return
            }
            self.refreshDates()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(refresh)
        } else {
            DispatchQueue.main.async(execute: refresh)
        }
    }

    /// The entry on the selected row, if any.
    public var selectedEntry: SearchIndex.Entry? {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return nil }
        return results[row]
    }

    /// The modified date as a row shows it (S-9), seen from `now`.
    public func dateText(for date: Date) -> String {
        relativeDate.string(for: date, now: now())
    }

    /// S-9: rewrites the date on every row the table currently holds, seen from `now`. Rows
    /// made later format their own dates, so nothing else needs doing. A title being edited is
    /// untouched: only the date label changes.
    public func refreshDates() {
        tableView.enumerateAvailableRowViews { [results] rowView, row in
            guard row >= 0, row < results.count, let view = rowView.view(atColumn: 0) as? NoteRowView else {
                return
            }
            view.setDateText(dateText(for: results[row].modifiedAt))
        }
    }

    /// Replaces the list's contents. The selected note stays selected if it is still listed,
    /// wherever it moved to. If it is gone the selection clears, unless `fallbackRow` is given:
    /// then the row now at that index is selected, or the last row when the list has become
    /// shorter than that. Passing the vanished note's old row makes the selection move to the
    /// next row, as X-4 and D-1 want after a deletion.
    public func show(_ results: SearchIndex.Results, fallbackRow: Int? = nil) {
        // R-1: a reload would remake the row whose title is being edited, ending the edit.
        if editingTitleOfID != nil {
            deferredShow = (results, fallbackRow)
            return
        }
        self.results = results
        tableView.reloadData()
        if let selectedID, let row = results.firstIndex(where: { $0.id == selectedID }) {
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else if let fallbackRow, !results.isEmpty {
            let row = min(max(fallbackRow, 0), results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else if tableView.selectedRow >= 0 {
            tableView.deselectAll(nil)
        }
        syncSelection()
    }

    /// Selects the row showing `id` and scrolls it into view. Returns false, changing nothing,
    /// when the note is not listed.
    @discardableResult
    public func select(_ id: NoteID) -> Bool {
        guard let row = results.firstIndex(where: { $0.id == id }) else { return false }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        tableView.scrollRowToVisible(row)
        syncSelection()
        return true
    }

    /// R-2, D-2: the selected note has been renamed by us and the next snapshot lists it under
    /// `newID`. The selection follows it there, so the reload keeps the row selected and
    /// `onSelectionChange` stays quiet: the note in the editor is the same one. Nothing happens
    /// when another note, or none, is selected.
    public func noteWasRenamed(from oldID: NoteID, to newID: NoteID) {
        if selectedID == oldID { selectedID = newID }
    }

    // MARK: - Inline title editing (R-1, R-2)

    /// Edits the title of `row` inline (R-1: Cmd-R). The row is selected if it is not, scrolled
    /// into view, and its title label becomes a field with focus and the whole title selected.
    /// Returns false, changing nothing, when the row is out of range or the field cannot take
    /// focus. Editing the row already being edited is a no-op; another row's edit in progress
    /// is dropped first, as a focus loss would drop it.
    @discardableResult
    public func beginEditingTitle(ofRow row: Int) -> Bool {
        guard row >= 0, row < results.count else { return false }
        let id = results[row].id
        if editingTitleOfID == id { return true }
        if editingTitleOfID != nil { endEditingTitle(movingFocus: false) }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            syncSelection()
        }
        tableView.scrollRowToVisible(row)
        // The row's view exists once the table has laid out the rows now visible.
        tableView.layoutSubtreeIfNeeded()
        guard let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NoteRowView else {
            return false
        }
        editingTitleOfID = id
        editingRowView = view
        guard view.beginEditingTitle(delegate: self) else {
            editingTitleOfID = nil
            editingRowView = nil
            return false
        }
        return true
    }

    /// Edits the title under `point`, in the table's coordinates (R-1: a double-click on a
    /// title). Returns false, changing nothing, when the point is not on a row's title.
    @discardableResult
    public func beginEditingTitle(at point: NSPoint) -> Bool {
        let row = tableView.row(at: point)
        guard row >= 0, let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteRowView,
            view.titleLabel.frame.contains(view.convert(point, from: tableView))
        else { return false }
        return beginEditingTitle(ofRow: row)
    }

    /// Ends the edit in progress without committing anything (R-1: Escape): the label shows the
    /// note's title again and focus returns to the list. Does nothing when no title is being
    /// edited.
    public func cancelEditingTitle() {
        endEditingTitle(movingFocus: true)
    }

    @objc private func tableViewWasDoubleClicked(_ sender: Any?) {
        guard let event = NSApplication.shared.currentEvent else { return }
        beginEditingTitle(at: tableView.convert(event.locationInWindow, from: nil))
    }

    /// Enter commits the text through `onCommitTitle`, or ends the edit at once when the text is
    /// the title unchanged; a rejected text stays in the field. Escape cancels. Everything else
    /// keeps the field editor's behaviour.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let id = editingTitleOfID, control === editingRowView?.titleLabel else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = control.stringValue
            if text == id.title || onCommitTitle?(id, text) ?? true {
                endEditingTitle(movingFocus: true)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditingTitle(movingFocus: true)
            return true
        default:
            return false
        }
    }

    /// Focus left the field on its own (a click elsewhere, Tab): a changed text is committed if
    /// its owner accepts it and dropped otherwise, and the edit ends either way.
    public func controlTextDidEndEditing(_ notification: Notification) {
        guard !isEndingTitleEdit, let id = editingTitleOfID, let field = editingRowView?.titleLabel,
            (notification.object as? NSControl) === field
        else { return }
        let text = field.stringValue
        if text != id.title { _ = onCommitTitle?(id, text) }
        endEditingTitle(movingFocus: false)
    }

    /// Returns the edited row to a plain label showing the note's title. With `movingFocus`,
    /// focus goes back to the table if the field still has it. A `show` held back during the
    /// edit is applied last.
    private func endEditingTitle(movingFocus: Bool) {
        guard let id = editingTitleOfID, let view = editingRowView else { return }
        isEndingTitleEdit = true
        defer { isEndingTitleEdit = false }
        editingTitleOfID = nil
        editingRowView = nil
        if movingFocus, let window = tableView.window, let editor = window.firstResponder as? NSTextView,
            editor.isFieldEditor, editor.delegate === view.titleLabel
        {
            window.makeFirstResponder(tableView)
        }
        view.endEditingTitle(showing: id.title)
        if let deferred = deferredShow {
            deferredShow = nil
            show(deferred.results, fallbackRow: deferred.fallbackRow)
        }
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view =
            tableView.makeView(withIdentifier: NoteRowView.identifier, owner: nil) as? NoteRowView ?? NoteRowView()
        let entry = results[row]
        view.configure(entry: entry, dateText: dateText(for: entry.modifiedAt))
        return view
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        syncSelection()
    }

    /// Fires `onSelectionChange` if the selected note differs from the one last reported.
    private func syncSelection() {
        let entry = selectedEntry
        guard entry?.id != selectedID else { return }
        selectedID = entry?.id
        onSelectionChange?(entry)
    }
}
