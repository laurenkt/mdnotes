import AppKit

/// The eviction bar (L-10, ADR-0009): one thin line directly under the search field saying
/// how many notes iCloud has not downloaded and that search is incomplete for it. When the
/// boot volume is nearly full, the reason macOS evicts, the line ends with the free space and
/// an `Open Storage Settings` button follows it. There is no way to dismiss the bar: it goes
/// when the last note is downloaded.
///
/// The bar is a view and knows nothing about the library: the window controller hands it the
/// library's eviction status whenever that changes and hides it while the scan is still
/// running or nothing is dataless. The button reports through `onOpenStorageSettings`; the
/// window controller opens the URL, so a test can click without opening System Settings.
@MainActor
public final class EvictionBar: NSView {
    /// Height of the bar when it is shown.
    nonisolated public static let height: CGFloat = 24

    /// Free space under which the bar adds the free-space suffix and the button (L-10).
    /// Decimal gigabytes, as Finder and Storage Settings count them.
    nonisolated public static let lowFreeSpaceThreshold: Int64 = 2_000_000_000

    /// What the button opens: the Storage pane of System Settings (L-10).
    nonisolated public static let storageSettingsURLString = "x-apple.systempreferences:com.apple.settings.Storage"

    /// The title of the button that follows the text while space is low.
    nonisolated public static let openStorageSettingsTitle = "Open Storage Settings"

    /// The count text, with the free-space suffix while space is low.
    public let label: NSTextField
    /// `Open Storage Settings`. Hidden unless the last `show` found space low.
    public let storageSettingsButton: NSButton

    /// How many notes the bar says are dataless, or nil while the bar is hidden.
    public private(set) var datalessCount: Int?

    /// Called when the button is clicked. Installed by the window controller.
    public var onOpenStorageSettings: (@MainActor () -> Void)?

    public init() {
        label = Self.makeLabel()
        storageSettingsButton = Self.makeButton()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        storageSettingsButton.target = self
        storageSettingsButton.action = #selector(storageSettingsButtonClicked(_:))
        addSubview(label)
        addSubview(storageSettingsButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            storageSettingsButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            storageSettingsButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            storageSettingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // A narrow window truncates the text before it loses the button.
        storageSettingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    // MARK: - Text (L-10)

    /// True when `freeBytes` is known and under `lowFreeSpaceThreshold`: the suffix and the
    /// button are shown. Unknown free space shows neither.
    nonisolated public static func isLowOnSpace(_ freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes < lowFreeSpaceThreshold
    }

    /// `N notes not downloaded from iCloud. Search is incomplete.`, singular for one note,
    /// with ` · 985 MB free` appended while space is low.
    nonisolated public static func text(datalessCount: Int, freeBytes: Int64?) -> String {
        let notes = datalessCount == 1 ? "1 note" : "\(datalessCount) notes"
        var text = "\(notes) not downloaded from iCloud. Search is incomplete."
        if let freeBytes, isLowOnSpace(freeBytes) {
            text += " \u{00B7} \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) free"
        }
        return text
    }

    // MARK: - Showing

    /// Shows the bar for `datalessCount` notes; `freeBytes` decides the suffix and the button.
    /// The bar takes a line of height under the search field while it is visible.
    public func show(datalessCount: Int, freeBytes: Int64?) {
        self.datalessCount = datalessCount
        label.stringValue = Self.text(datalessCount: datalessCount, freeBytes: freeBytes)
        storageSettingsButton.isHidden = !Self.isLowOnSpace(freeBytes)
        isHidden = false
    }

    public func hide() {
        guard datalessCount != nil else { return }
        datalessCount = nil
        label.stringValue = ""
        storageSettingsButton.isHidden = true
        isHidden = true
    }

    @objc private func storageSettingsButtonClicked(_ sender: Any?) {
        onOpenStorageSettings?()
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

    private static func makeButton() -> NSButton {
        let button = NSButton(title: openStorageSettingsTitle, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }
}
