import AppKit

/// The main window's content (W-2): search field across the top, the note list below it, the
/// editor below the list, and the backlinks strip below the editor. The list/editor boundary is
/// a draggable `NSSplitView` divider whose position persists across launches (W-1).
///
/// This is layout only. Data sources, delegates and behaviour are wired by later tasks.
@MainActor
public final class MainView: NSView, NSSplitViewDelegate {
    /// `UserDefaults` key under which the divider position (the list's height) persists (W-1).
    nonisolated public static let listHeightDefaultsKey = "MainSplitListHeight"
    /// Divider position (height of the list, in points) used when nothing is persisted yet.
    nonisolated public static let defaultListHeight: CGFloat = 220
    /// Height of the backlinks strip when it is shown (K-6, wired in M4.7).
    nonisolated public static let backlinksStripHeight: CGFloat = 28

    public let searchField: NSSearchField
    public let splitView: NSSplitView
    public let listScrollView: NSScrollView
    public let tableView: NoteTableView
    public let editorScrollView: NSScrollView
    public let textView: NSTextView
    public let backlinksStrip: NSView
    private let stack: NSStackView
    private let defaults: UserDefaults
    private var isRestoringSplit = false
    private var hasRestoredSplit = false

    public override init(frame frameRect: NSRect) {
        defaults = .standard
        searchField = Self.makeSearchField()
        (listScrollView, tableView) = Self.makeList()
        (editorScrollView, textView) = Self.makeEditor()
        backlinksStrip = Self.makeBacklinksStrip()
        splitView = Self.makeSplitView(top: listScrollView, bottom: editorScrollView)
        stack = NSStackView(views: [searchField, splitView, backlinksStrip])
        super.init(frame: frameRect)

        splitView.delegate = self
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            backlinksStrip.heightAnchor.constraint(equalToConstant: Self.backlinksStripHeight),
        ])
        // The split view takes every point the search field and strip do not need.
        searchField.setContentHuggingPriority(.required, for: .vertical)
        backlinksStrip.setContentHuggingPriority(.required, for: .vertical)
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        splitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasRestoredSplit else { return }
        hasRestoredSplit = true
        restoreSplitPosition()
    }

    // MARK: - Keyboard (S-7)

    /// Moves focus to the search field and selects its text. Cmd-L reaches this from anywhere
    /// in the window; the menu item and the global hotkey (W-3) route here too.
    public func focusSearchField() {
        guard let window else { return }
        if window.makeFirstResponder(searchField) {
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    /// Cmd-L focuses the search field wherever focus is (S-7). The window tries the content
    /// view's key equivalents before the menu and before the first responder's `keyDown`, so
    /// this holds whichever view has focus.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCommandL(event) {
            focusSearchField()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isCommandL(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "l"
    }

    // MARK: - Split persistence (W-1)

    /// The persisted list height, or nil if nothing has been saved yet or the value is unusable.
    public var persistedListHeight: CGFloat? {
        guard let number = defaults.object(forKey: Self.listHeightDefaultsKey) as? NSNumber else { return nil }
        let height = CGFloat(number.doubleValue)
        return height.isFinite && height > 0 ? height : nil
    }

    private func restoreSplitPosition() {
        let height = persistedListHeight ?? Self.defaultListHeight
        isRestoringSplit = true
        // The split view needs a real frame before a divider position means anything.
        layoutSubtreeIfNeeded()
        splitView.setPosition(height, ofDividerAt: 0)
        layoutSubtreeIfNeeded()
        isRestoringSplit = false
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isRestoringSplit, window != nil else { return }
        let height = listScrollView.frame.height
        guard height > 0, height != persistedListHeight else { return }
        defaults.set(Double(height), forKey: Self.listHeightDefaultsKey)
    }

    // MARK: - Subview construction

    private static func makeSearchField() -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search or create"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private static func makeList() -> (NSScrollView, NoteTableView) {
        let table = NoteTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.title = "Note"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.style = .plain

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return (scroll, table)
    }

    private static func makeEditor() -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let text = scroll.documentView as? NSTextView ?? NSTextView()
        text.isRichText = false
        text.importsGraphics = false
        text.usesFontPanel = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        return (scroll, text)
    }

    private static func makeBacklinksStrip() -> NSView {
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Backlinks")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
        // K-6: hidden when there are no backlinks. There are none until M4.7 wires it.
        strip.isHidden = true
        return strip
    }

    private static func makeSplitView(top: NSView, bottom: NSView) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(top)
        split.addArrangedSubview(bottom)
        // The list keeps its height when the window resizes; the editor absorbs the change.
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 250), forSubviewAt: 1)
        return split
    }
}
