import AppKit
import MDNotesCore

/// Data source and delegate of the note list (S-6). Shows one `SearchIndex.Results` at a time,
/// a view onto an immutable snapshot, so a reload is a `reloadData()` and nothing else (PF-2).
///
/// Selection is tracked by note id, not row: when a fresh snapshot moves the selected note to
/// another row it stays selected, and `onSelectionChange` fires only when the selected note
/// actually changes, never because the list around it was reloaded.
@MainActor
public final class NoteListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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

    private let dateFormatter: DateFormatter

    public init(tableView: NSTableView) {
        self.tableView = tableView
        results = SearchIndex.empty.query("")
        dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        dateFormatter.doesRelativeDateFormatting = true
        super.init()
        tableView.rowHeight = Self.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
    }

    /// The entry on the selected row, if any.
    public var selectedEntry: SearchIndex.Entry? {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return nil }
        return results[row]
    }

    /// The modified date as a row shows it.
    public func dateText(for date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// Replaces the list's contents. The selected note stays selected if it is still listed,
    /// wherever it moved to. If it is gone the selection clears, unless `fallbackRow` is given:
    /// then the row now at that index is selected, or the last row when the list has become
    /// shorter than that. Passing the vanished note's old row makes the selection move to the
    /// next row, as X-4 and D-1 want after a deletion.
    public func show(_ results: SearchIndex.Results, fallbackRow: Int? = nil) {
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
