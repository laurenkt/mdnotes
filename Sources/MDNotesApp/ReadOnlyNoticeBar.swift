import AppKit

/// The read-only notice (L-7, L-8): one line above the editor saying why the shown note
/// cannot be edited. Hidden while the editor shows a writable body or nothing at all.
///
/// The bar is a view and knows nothing about notes: the window controller hands it the
/// editor's notice text whenever a load lands and clears it when the next one does.
@MainActor
public final class ReadOnlyNoticeBar: NSView {
    /// Height of the bar when it is shown.
    nonisolated public static let height: CGFloat = 24

    /// The notice text.
    public let label: NSTextField

    /// The notice shown, or nil while the bar is hidden.
    public private(set) var notice: String?

    public init() {
        label = Self.makeLabel()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    /// Shows `text`; the bar takes a line of height above the editor while it is visible.
    public func show(_ text: String) {
        notice = text
        label.stringValue = text
        isHidden = false
    }

    public func hide() {
        guard notice != nil else { return }
        notice = nil
        label.stringValue = ""
        isHidden = true
    }

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
