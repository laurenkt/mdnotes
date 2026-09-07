import AppKit
import MDNotesCore

/// The `[[` completion popover (K-4): a list of titles under the caret, filtered by the text
/// typed since the brackets, from which Enter inserts a title and the closing `]]`.
///
/// A session opens when the text changes and the caret sits right after a `[[`
/// (`LinkCompletion.anchor`). While it lasts, every change to the text or the caret re-reads
/// the text typed since the brackets (`LinkCompletion.filterText`) and lists the titles the
/// S-2 rules match on it (`LinkCompletion.titles`), most recently modified first, in a panel
/// hung under the caret as a child window of the editor's window. The list is showing only
/// while there is something to list: with no match it is hidden and the keys are the editor's
/// again, but the session stays open, so deleting back to a match brings it back.
///
/// The session and the list are current the moment the text changes; the panel's window
/// catches up with them once the current event has been handled (`setNeedsPanelUpdate`), so
/// the typed character is drawn before the panel is moved (PF-3) and Enter typed before the
/// panel has caught up still inserts the title the list holds.
///
/// The session ends, and the panel with it, when the caret leaves the brackets, the brackets
/// go, a `]` or a line break is typed, Escape is pressed, a title is inserted, the editor's
/// text is replaced or it loses focus (`dismiss()`), or the popover is dismissed by whoever
/// owns it. The editor keeps focus throughout: the panel never becomes key, and the keys the
/// popover takes (Return and Enter, Escape, Up and Down) reach it through the text view
/// delegate's `doCommandBy`, from `handle(_:)`.
///
/// Inserting goes through `insertText(_:replacementRange:)`, the path a keystroke takes, so
/// the completion is styled (E-2), undoable as one step (E-7) and autosaved (E-4) like typing.
@MainActor
public final class LinkCompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Every row is this tall.
    nonisolated public static let rowHeight: CGFloat = 22
    /// The panel shows at most this many rows before scrolling.
    nonisolated public static let maximumVisibleRows = 8
    nonisolated private static let panelWidth: CGFloat = 320
    nonisolated private static let panelPadding: CGFloat = 4
    nonisolated private static let cornerRadius: CGFloat = 6

    public let textView: NSTextView

    /// The snapshot whose titles are listed. Installed by the owner; an empty index lists
    /// nothing.
    public var index: @MainActor () -> SearchIndex = { .empty }

    /// The index just after the `[[` of the open session, or nil while there is none.
    public private(set) var anchor: Int?

    /// True while a session is open, whether or not the panel is showing.
    public var isActive: Bool { anchor != nil }

    /// The titles listed, in row order; empty while the panel is hidden.
    public private(set) var titles: [String] = []

    /// True while the list is showing: `titles` is what the popover lists, the keys are its
    /// (`handle(_:)`), and the panel is up under the caret with the titles in it, or goes up on
    /// the next turn of the run loop (`isPanelAttached`).
    public private(set) var isShowing = false

    /// True while the panel is a child window of the editor's window. Follows `isShowing` a
    /// run-loop turn behind: see `setNeedsPanelUpdate()`.
    public private(set) var isPanelAttached = false
    private var isPanelUpdateScheduled = false

    /// The title Enter would insert, or nil while nothing is showing.
    public var selectedTitle: String? {
        let row = tableView.selectedRow
        guard isShowing, row >= 0, row < titles.count else { return nil }
        return titles[row]
    }

    /// Called on the main thread once a title has been inserted, with the title and the range
    /// of the text it now occupies, brackets included.
    public var onInsert: (@MainActor (String, NSRange) -> Void)?

    public let tableView: NSTableView
    private let panel: NSPanel
    private let scrollView: NSScrollView
    /// True while a title is being inserted, so the edit's own notifications do not reopen or
    /// re-filter the session that is ending.
    private var isInserting = false

    public init(textView: NSTextView) {
        self.textView = textView
        tableView = CompletionTableView()
        scrollView = NSScrollView()
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.rowHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        configurePanel()
    }

    // MARK: - Session (K-4)

    /// The text changed under the caret. Opens a session when the caret now sits right after a
    /// `[[`, and otherwise re-filters or ends the one that is open.
    public func textDidChange() {
        guard !isInserting else { return }
        if anchor == nil {
            guard let storage = textView.textStorage else { return }
            anchor = LinkCompletion.anchor(in: storage.mutableString, caret: textView.selectedRange())
        }
        refresh()
    }

    /// The caret moved without the text changing: a click, an arrow key, undo. Re-filters or
    /// ends the open session; never opens one (K-4: typing `[[` opens it).
    public func selectionDidChange() {
        guard !isInserting, anchor != nil else { return }
        refresh()
    }

    /// Re-reads the text since the brackets and lists the titles for it. A no-op while no
    /// session is open. Called by the owner when the snapshot changes, so the list keeps up
    /// with notes created or renamed while it is showing.
    public func refresh() {
        guard let anchor, let storage = textView.textStorage else { return }
        guard
            let typed = LinkCompletion.filterText(
                in: storage.mutableString, anchor: anchor, caret: textView.selectedRange())
        else {
            dismiss()
            return
        }
        let matches = LinkCompletion.titles(matching: typed, in: index())
        if matches.isEmpty {
            hidePanel()
            return
        }
        titles = matches
        isShowing = true
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        setNeedsPanelUpdate()
    }

    /// Ends the session and hides the panel. The text is left as typed (K-4: Escape dismisses).
    public func dismiss() {
        anchor = nil
        hidePanel()
    }

    /// Inserts the selected title (K-4): the text typed since the brackets is replaced by the
    /// title and the closing `]]`, and the caret is left after them. Returns false, doing
    /// nothing, while nothing is showing.
    @discardableResult
    public func acceptSelection() -> Bool {
        guard let anchor, let title = selectedTitle else { return false }
        let caret = textView.selectedRange().location
        let typed = NSRange(location: anchor, length: max(0, caret - anchor))
        isInserting = true
        dismiss()
        let insertion = LinkCompletion.insertion(for: title)
        textView.insertText(insertion, replacementRange: typed)
        isInserting = false
        let link = NSRange(location: anchor - 2, length: 2 + (insertion as NSString).length)
        onInsert?(title, link)
        return true
    }

    /// Moves the selection down one row, stopping at the last.
    public func selectNext() {
        select(row: tableView.selectedRow + 1)
    }

    /// Moves the selection up one row, stopping at the first.
    public func selectPrevious() {
        select(row: tableView.selectedRow - 1)
    }

    private func select(row: Int) {
        guard isShowing, !titles.isEmpty else { return }
        let clamped = min(max(row, 0), titles.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    /// The command selectors the popover takes while it is showing (K-4): Return and Enter
    /// insert the selected title, Escape dismisses, Up and Down move the selection. Returns
    /// true when the key was taken; false leaves it to the text view. With a session open but
    /// nothing showing, Escape ends the session and is still left to the text view.
    public func handle(_ commandSelector: Selector) -> Bool {
        guard isShowing else {
            if isActive, commandSelector == #selector(NSResponder.cancelOperation(_:)) { dismiss() }
            return false
        }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            return acceptSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.moveDown(_:)):
            selectNext()
            return true
        case #selector(NSResponder.moveUp(_:)):
            selectPrevious()
            return true
        default:
            return false
        }
    }

    // MARK: - Panel

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = Self.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowWasClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.masksToBounds = true
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.panelPadding),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.panelPadding),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        panel.contentView = background
    }

    /// Brings the panel's window into line with `isShowing` and `titles` once the current
    /// event has been handled, not now. Ordering a child window in or out and resizing it are
    /// round trips to the window server, several milliseconds each, and this is called from
    /// the text view's change notifications, inside the keystroke: done there, they would
    /// come out of the PF-3 budget for the character to appear. Deferred, the character is
    /// drawn first and the panel follows on the same turn of the run loop, and a burst of
    /// typing moves the panel once.
    private func setNeedsPanelUpdate() {
        guard !isPanelUpdateScheduled else { return }
        isPanelUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updatePanel() }
        }
    }

    /// Puts the panel up under the caret's line at the session's anchor, sized to the titles,
    /// as a child window of the editor's window so it follows and stays above it; or takes it
    /// down when nothing is showing. Runs on its own a turn of the run loop after the state
    /// changed; calling it flushes that now. A window that is not on screen shows nothing,
    /// but the state is the same.
    public func updatePanel() {
        isPanelUpdateScheduled = false
        guard isShowing, let anchor, let window = textView.window else {
            detachPanel()
            return
        }
        let rows = min(titles.count, Self.maximumVisibleRows)
        let height = CGFloat(rows) * Self.rowHeight + 2 * Self.panelPadding
        let frame = frame(forHeight: height, under: anchor, in: window)
        if frame != panel.frame { panel.setFrame(frame, display: false) }
        if !isPanelAttached || panel.parent !== window {
            detachPanel()
            isPanelAttached = true
            window.addChildWindow(panel, ordered: .above)
        }
    }

    private func detachPanel() {
        guard isPanelAttached else { return }
        isPanelAttached = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// The panel's frame: its top-left at the bottom-left of the character after the brackets,
    /// moved above the line when there is no room below on the window's screen, and kept
    /// within the screen horizontally.
    private func frame(forHeight height: CGFloat, under anchor: Int, in window: NSWindow) -> NSRect {
        var caret = textView.firstRect(forCharacterRange: NSRange(location: anchor, length: 0), actualRange: nil)
        if caret.isEmpty && caret.origin == .zero {
            // No layout to ask: hang the panel under the editor's top-left corner instead.
            let top = textView.convert(NSPoint(x: 0, y: textView.isFlipped ? 0 : textView.bounds.height), to: nil)
            caret = NSRect(origin: window.convertPoint(toScreen: top), size: .zero)
        }
        var origin = NSPoint(x: caret.minX, y: caret.minY - height)
        if let screen = window.screen?.visibleFrame {
            if origin.y < screen.minY, caret.maxY + height <= screen.maxY { origin.y = caret.maxY }
            origin.x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - Self.panelWidth))
        }
        return NSRect(origin: origin, size: NSSize(width: Self.panelWidth, height: height))
    }

    private func hidePanel() {
        titles = []
        guard isShowing else { return }
        isShowing = false
        tableView.reloadData()
        setNeedsPanelUpdate()
    }

    /// A click on a row inserts that title, as Enter would.
    @objc private func rowWasClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < titles.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        acceptSelection()
    }

    // MARK: - NSTableViewDataSource, NSTableViewDelegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        titles.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < titles.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CompletionRow")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = Self.makeCell(identifier: identifier)
        }
        cell.textField?.stringValue = titles[row]
        return cell
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row >= 0 && row < titles.count
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// The popover's table. Its panel never becomes key, so the first click on a row must count as
/// a click and not as a bid for focus.
@MainActor
private final class CompletionTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}
