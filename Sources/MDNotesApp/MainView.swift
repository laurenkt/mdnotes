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
    /// The height the editor's text container and view may grow to: the value
    /// `NSTextView.scrollableTextView()` uses, so layout is unchanged by the subclass.
    nonisolated private static let unboundedEditorHeight: CGFloat = 10_000_000

    public let searchField: NSSearchField
    /// The inline message under the search field (C-3). Hidden until `showMessage(_:)`.
    public let messageLabel: NSTextField
    public let splitView: NSSplitView
    public let listScrollView: NSScrollView
    public let tableView: NoteTableView
    public let editorScrollView: NSScrollView
    public let textView: EditorTextView
    public let backlinksStrip: NSView

    /// Cmd-Delete (D-1). Returns true if a note was selected and its deletion begun; false
    /// lets the key go on to whatever has focus. Installed by the window controller.
    public var onDeleteNote: (@MainActor () -> Bool)?

    /// Cmd-R (R-1). Returns true if a note was selected and its title is now being edited in
    /// the list; false lets the key go on to whatever has focus. Installed by the window
    /// controller.
    public var onRenameNote: (@MainActor () -> Bool)?

    /// Cmd-, (PR-1). Shows the Preferences window. Installed by the app delegate; the key is
    /// left alone while nothing is installed.
    public var onShowPreferences: (@MainActor () -> Void)?

    /// E-8: called with the new editor font once `applyEditorFont()` has set it on the text
    /// view, so the styling (E-2) can be laid back over it. Installed by the window controller.
    public var onEditorFontChange: (@MainActor (NSFont) -> Void)?

    private let stack: NSStackView
    private let defaults: UserDefaults
    private var isRestoringSplit = false
    private var hasRestoredSplit = false
    /// The font last set on the text view. Compared instead of `textView.font`, which reports
    /// the first character's font and so a heading's bold face (E-2).
    private var appliedEditorFont: NSFont

    public override init(frame frameRect: NSRect) {
        defaults = .standard
        searchField = Self.makeSearchField()
        messageLabel = Self.makeMessageLabel()
        (listScrollView, tableView) = Self.makeList()
        (editorScrollView, textView) = Self.makeEditor()
        appliedEditorFont = textView.font ?? EditorFontPreference.font(from: defaults)
        backlinksStrip = Self.makeBacklinksStrip()
        splitView = Self.makeSplitView(top: listScrollView, bottom: editorScrollView)
        stack = NSStackView(views: [searchField, messageLabel, splitView, backlinksStrip])
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
        messageLabel.setContentHuggingPriority(.required, for: .vertical)
        backlinksStrip.setContentHuggingPriority(.required, for: .vertical)
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        splitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // E-8: the editor font follows the preference for as long as the view lives.
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsDidChange(_:)), name: UserDefaults.didChangeNotification,
            object: defaults)
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

    // MARK: - Inline message (C-3)

    /// Shows `text` under the search field. Shown until `hideMessage()`; the stack view
    /// gives it a line of height only while it is visible.
    public func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
    }

    public func hideMessage() {
        guard !messageLabel.isHidden else { return }
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
    }

    // MARK: - Editor font (E-8)

    /// Sets the editor's font from the preference if it differs from the font in use. Called
    /// whenever the defaults change; the check keeps unrelated writes, such as the split
    /// position persisting during a drag, from relaying out the text. Setting the text view's
    /// font puts it on every character, so `onEditorFontChange` follows for the styling.
    public func applyEditorFont() {
        let font = EditorFontPreference.font(from: defaults)
        guard font != appliedEditorFont else { return }
        appliedEditorFont = font
        textView.font = font
        onEditorFontChange?(font)
    }

    @objc private func defaultsDidChange(_ notification: Notification) {
        applyEditorFont()
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

    /// Cmd-L focuses the search field wherever focus is (S-7), Cmd-Delete deletes the selected
    /// note wherever focus is (D-1), Cmd-R edits its title in the list (R-1), and Cmd-, shows
    /// the Preferences window (PR-1). The window tries the content view's key equivalents
    /// before the menu and before the first responder's `keyDown`, so all of them hold
    /// whichever view has focus; Cmd-Delete and Cmd-R with no row selected are left to the
    /// focused view.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCommand(event, key: "l") {
            focusSearchField()
            return true
        }
        if Self.isCommand(event, key: Self.deleteKey), let onDeleteNote, onDeleteNote() {
            return true
        }
        if Self.isCommand(event, key: "r"), let onRenameNote, onRenameNote() {
            return true
        }
        if Self.isCommand(event, key: ","), let onShowPreferences {
            onShowPreferences()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The Delete (backspace) key's character.
    private static let deleteKey = "\u{7F}"

    private static func isCommand(_ event: NSEvent, key: String) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == key
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

    private static func makeMessageLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .systemRed
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
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

    /// The editor: an `EditorTextView` in a scroll view, set up the way
    /// `NSTextView.scrollableTextView()` sets up a plain text view (TextKit 2, wrapping to the
    /// scroll view's width, growing downwards without limit).
    private static func makeEditor() -> (NSScrollView, EditorTextView) {
        let text = EditorTextView(frame: .zero)
        text.autoresizingMask = [.width, .height]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(width: 0, height: Self.unboundedEditorHeight)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: Self.unboundedEditorHeight)
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        text.isRichText = false
        text.importsGraphics = false
        text.usesFontPanel = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.font = EditorFontPreference.font(from: .standard)
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
