import AppKit
import MDNotesCore

/// One row of the note list (S-6): title on the first line with the modified date at its
/// trailing edge, a single-line body snippet on the second. Every row is the same height;
/// the layout is fixed frames, so a reload costs no constraint solving (PF-2).
@MainActor
public final class NoteRowView: NSTableCellView {
    /// Reuse identifier under which the list makes and recycles rows.
    nonisolated public static let identifier = NSUserInterfaceItemIdentifier("NoteRow")

    public let titleLabel: NSTextField
    public let dateLabel: NSTextField
    public let snippetLabel: NSTextField

    private static let horizontalInset: CGFloat = 8
    private static let gap: CGFloat = 8
    private static let titleTop: CGFloat = 6
    private static let titleHeight: CGFloat = 17
    private static let snippetTop: CGFloat = 24
    private static let snippetHeight: CGFloat = 15

    public override init(frame frameRect: NSRect) {
        titleLabel = Self.makeLabel(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        dateLabel = Self.makeLabel(font: .systemFont(ofSize: NSFont.smallSystemFontSize))
        snippetLabel = Self.makeLabel(font: .systemFont(ofSize: NSFont.smallSystemFontSize))
        dateLabel.alignment = .right
        super.init(frame: frameRect)
        identifier = Self.identifier
        addSubview(titleLabel)
        addSubview(dateLabel)
        addSubview(snippetLabel)
        applyColors()
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Top-down coordinates so the row reads like it looks.
    public override var isFlipped: Bool { true }

    /// Fills the row from an index entry. `dateText` is the already formatted modified date.
    public func configure(entry: SearchIndex.Entry, dateText: String) {
        titleLabel.stringValue = entry.id.title
        dateLabel.stringValue = dateText
        snippetLabel.stringValue = entry.preview
        needsLayout = true
    }

    // MARK: - Inline title editing (R-1)

    /// True while the title label is editable: between `beginEditingTitle` and `endEditingTitle`.
    public private(set) var isEditingTitle = false

    /// Makes the title label an editable field, with `delegate` hearing its field editor, and
    /// gives it focus with the whole title selected. Returns false, changing nothing, if the row
    /// is not in a window, since then nothing can be focused.
    @discardableResult
    public func beginEditingTitle(delegate: any NSTextFieldDelegate) -> Bool {
        guard let window else { return false }
        titleLabel.isEditable = true
        titleLabel.drawsBackground = true
        titleLabel.backgroundColor = .textBackgroundColor
        titleLabel.textColor = .labelColor
        titleLabel.delegate = delegate
        isEditingTitle = true
        guard window.makeFirstResponder(titleLabel) else {
            endEditingTitle()
            return false
        }
        titleLabel.currentEditor()?.selectAll(nil)
        return true
    }

    /// Returns the title label to a plain label showing `title` if given, or leaves its text.
    /// Focus is left where it is; the caller moves it.
    public func endEditingTitle(showing title: String? = nil) {
        if let title { titleLabel.stringValue = title }
        titleLabel.delegate = nil
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false
        isEditingTitle = false
        applyColors()
    }

    public override func layout() {
        super.layout()
        let width = bounds.width
        let inset = Self.horizontalInset
        let dateWidth = min(ceil(dateLabel.intrinsicContentSize.width), max(0, width / 2))
        dateLabel.frame = NSRect(
            x: width - inset - dateWidth, y: Self.titleTop + 1, width: dateWidth, height: Self.titleHeight - 1)
        titleLabel.frame = NSRect(
            x: inset, y: Self.titleTop, width: max(0, width - 2 * inset - dateWidth - Self.gap),
            height: Self.titleHeight)
        snippetLabel.frame = NSRect(
            x: inset, y: Self.snippetTop, width: max(0, width - 2 * inset), height: Self.snippetHeight)
    }

    public override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        titleLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        dateLabel.textColor = secondary
        snippetLabel.textColor = secondary
    }

    private static func makeLabel(font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        return label
    }
}
