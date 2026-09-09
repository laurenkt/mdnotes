import AppKit
import MDNotesCore

/// One row of the note list (S-6): title on the first line with the modified date at its
/// trailing edge, a single-line body snippet on the second. Every row is the same height;
/// the layout is fixed frames, so a reload costs no constraint solving (PF-2).
///
/// S-11: a note with an embedded image gets a `thumbnailSize` square at the row's right end,
/// spanning both lines, that the title, date and snippet make room for. The square is empty
/// until `showThumbnail(_:for:)` hands over the cached image; nothing here touches a file.
/// The image view is not editable and refuses first responder, so the table keeps a click on
/// it (`validateProposedFirstResponder` says no) and selects the note as it does for a click
/// anywhere else in the row.
@MainActor
public final class NoteRowView: NSTableCellView {
    /// Reuse identifier under which the list makes and recycles rows.
    nonisolated public static let identifier = NSUserInterfaceItemIdentifier("NoteRow")

    /// S-11: the thumbnail's side, in points.
    nonisolated public static let thumbnailSize: CGFloat = 34

    public let titleLabel: NSTextField
    public let dateLabel: NSTextField
    public let snippetLabel: NSTextField
    /// The square at the right end (S-11). Hidden for a note without an image; shown, and empty
    /// until its image is cached, for a note with one.
    public let thumbnailView: NSImageView

    /// Root-relative path of the image the row shows or waits for; nil for a note without one.
    public private(set) var thumbnailPath: String?

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
        thumbnailView = NSImageView()
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageAlignment = .alignCenter
        thumbnailView.isEditable = false
        thumbnailView.refusesFirstResponder = true
        thumbnailView.isHidden = true
        super.init(frame: frameRect)
        identifier = Self.identifier
        addSubview(titleLabel)
        addSubview(dateLabel)
        addSubview(snippetLabel)
        addSubview(thumbnailView)
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
    /// The thumbnail square is reserved when the entry names an image and emptied either way;
    /// the list fills it through `showThumbnail(_:for:)` once the image is cached (S-11).
    public func configure(entry: SearchIndex.Entry, dateText: String) {
        titleLabel.stringValue = entry.id.title
        snippetLabel.stringValue = entry.preview
        thumbnailPath = entry.firstImagePath
        thumbnailView.image = nil
        thumbnailView.isHidden = thumbnailPath == nil
        setDateText(dateText)
    }

    /// Fills the row for a template in template mode (TP-5, ADR-0014's second row kind): the
    /// template's name where a title goes and, as the snippet, the path it would create or
    /// why it cannot be used. No date and no thumbnail: a template is not a note.
    public func configure(templateName: String, snippet: String) {
        titleLabel.stringValue = templateName
        snippetLabel.stringValue = snippet
        thumbnailPath = nil
        thumbnailView.image = nil
        thumbnailView.isHidden = true
        setDateText("")
    }

    /// S-11: shows `image`, cropped to its centre square, in the thumbnail view, but only while
    /// the row still shows the note whose image is at `path`: a completion for a row since
    /// recycled to another note is dropped. Nil empties the square: the file is gone or is no
    /// longer an image (X-1). Returns whether the answer was taken.
    @discardableResult
    public func showThumbnail(_ image: CGImage?, for path: String) -> Bool {
        guard path == thumbnailPath else { return false }
        guard let image else {
            thumbnailView.image = nil
            return true
        }
        let side = min(image.width, image.height)
        let square = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        let cropped = image.cropping(to: square) ?? image
        thumbnailView.image = NSImage(
            cgImage: cropped, size: NSSize(width: Self.thumbnailSize, height: Self.thumbnailSize))
        return true
    }

    /// Replaces the date alone (S-9: relative words refreshed on a day change). The date's
    /// width may change, so the row lays out again; the title is left as it is, editable or not.
    public func setDateText(_ dateText: String) {
        dateLabel.stringValue = dateText
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

    /// S-10: the date takes its intrinsic width unconditionally and sits at the trailing edge;
    /// the title gets whatever is left and truncates with an ellipsis. The width comes from
    /// `sizeThatFits`, the cell's own measure of the whole string: `intrinsicContentSize` of a
    /// truncating label can come back a few points short and the date would lose its end.
    /// S-11: a note with an image gives the right end to the thumbnail square, centred on the
    /// row's height, and the text columns end a gap before it.
    public override func layout() {
        super.layout()
        let width = bounds.width
        let inset = Self.horizontalInset
        var textEnd = width - inset
        if thumbnailPath != nil {
            let side = Self.thumbnailSize
            thumbnailView.frame = NSRect(
                x: width - inset - side, y: (bounds.height - side) / 2, width: side, height: side)
            textEnd -= side + Self.gap
        }
        let dateWidth = ceil(
            dateLabel.sizeThatFits(NSSize(width: .greatestFiniteMagnitude, height: Self.titleHeight)).width)
        dateLabel.frame = NSRect(
            x: textEnd - dateWidth, y: Self.titleTop + 1, width: dateWidth, height: Self.titleHeight - 1)
        titleLabel.frame = NSRect(
            x: inset, y: Self.titleTop, width: max(0, textEnd - inset - dateWidth - Self.gap),
            height: Self.titleHeight)
        snippetLabel.frame = NSRect(
            x: inset, y: Self.snippetTop, width: max(0, textEnd - inset), height: Self.snippetHeight)
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
