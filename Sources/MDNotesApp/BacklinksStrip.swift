import AppKit
import MDNotesCore

/// The backlinks strip (K-6): one bar below the editor listing the titles of the notes that
/// link to the open note, most recently modified first, each a button that opens its note.
/// The bar is hidden while there are no backlinks and collapsible while there are: collapsed,
/// it shows the disclosure triangle and a count and hides the titles; expanded, the titles
/// follow the label. The collapse state is written to `UserDefaults` when it changes and read
/// back when the strip is made, so it is remembered across launches.
///
/// The strip is a view and knows nothing about the library: the window controller hands it the
/// notes to list whenever the open note or the snapshot changes and is told, through `onOpen`,
/// which note a click asked for. Titles that do not fit the bar's width are dropped from the
/// end rather than clipped, through the title stack's visibility priorities.
@MainActor
public final class BacklinksStrip: NSView {
    /// `UserDefaults` key under which the collapse state persists (K-6). True when collapsed.
    nonisolated public static let collapsedDefaultsKey = "BacklinksStripCollapsed"

    /// Toggles the collapse state. Its state is on while the strip is expanded.
    public let disclosureButton: NSButton
    /// "Backlinks" while expanded; the count ("3 backlinks") while collapsed.
    public let summaryLabel: NSTextField
    /// The title buttons, in `backlinks` order. Hidden while collapsed.
    public let titlesStack: NSStackView

    /// The notes listed, most recently modified first. Empty while the strip is hidden.
    public private(set) var backlinks: [NoteID] = []

    /// True while the titles are hidden behind the count.
    public private(set) var isCollapsed: Bool

    /// Called with the note whose title was clicked. Installed by the window controller.
    public var onOpen: (@MainActor (NoteID) -> Void)?

    private let defaults: UserDefaults

    /// `defaults` holds the collapse state; the strip starts out as it was last left.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCollapsed = defaults.bool(forKey: Self.collapsedDefaultsKey)
        disclosureButton = Self.makeDisclosureButton()
        summaryLabel = Self.makeSummaryLabel()
        titlesStack = Self.makeTitlesStack()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureButtonClicked(_:))
        addSubview(disclosureButton)
        addSubview(summaryLabel)
        addSubview(titlesStack)
        NSLayoutConstraint.activate([
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            summaryLabel.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 2),
            summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titlesStack.leadingAnchor.constraint(equalTo: summaryLabel.trailingAnchor, constant: 8),
            titlesStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titlesStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        summaryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The bar spans the window (W-2): the title stack takes whatever width is left rather
        // than hugging its titles, and drops titles from the end when they do not fit. Its
        // resistance to being narrower than its titles sits below the window's own resistance
        // to resizing, so a long list of backlinks detaches titles instead of widening the
        // window.
        titlesStack.setHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        titlesStack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // K-6: hidden until there are backlinks to show.
        isHidden = true
        applyCollapseState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The title buttons in `backlinks` order, whether or not the bar is wide enough to show
    /// them all.
    public var titleButtons: [NSButton] {
        titlesStack.views.compactMap { $0 as? NSButton }
    }

    // MARK: - Content (K-6)

    /// Lists `notes`, most recently modified first as the link index orders them; the strip
    /// shows itself when there are any and hides itself when there are none. Titles are the
    /// notes' file names (L-5); a button's tooltip carries the path, which tells apart two
    /// notes with the same title.
    public func show(_ notes: [NoteID]) {
        guard notes != backlinks else { return }
        backlinks = notes
        for view in titlesStack.views { titlesStack.removeView(view) }
        for (offset, id) in notes.enumerated() {
            let button = Self.makeTitleButton(for: id)
            button.tag = offset
            button.target = self
            button.action = #selector(titleClicked(_:))
            titlesStack.addView(button, in: .leading)
            // Titles past the bar's width drop from the end first, never the beginning.
            let priority = max(Float(NSStackView.VisibilityPriority.notVisible.rawValue) + 1, 900 - Float(offset))
            titlesStack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: priority), for: button)
        }
        isHidden = notes.isEmpty
        updateSummary()
    }

    @objc private func titleClicked(_ sender: NSButton) {
        guard backlinks.indices.contains(sender.tag) else { return }
        onOpen?(backlinks[sender.tag])
    }

    // MARK: - Collapse (K-6)

    /// Hides the titles behind the count, or shows them again, and remembers the choice.
    public func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        defaults.set(collapsed, forKey: Self.collapsedDefaultsKey)
        applyCollapseState()
    }

    public func toggleCollapsed() {
        setCollapsed(!isCollapsed)
    }

    @objc private func disclosureButtonClicked(_ sender: NSButton) {
        setCollapsed(sender.state != .on)
    }

    private func applyCollapseState() {
        disclosureButton.state = isCollapsed ? .off : .on
        titlesStack.isHidden = isCollapsed
        updateSummary()
    }

    private func updateSummary() {
        if isCollapsed {
            summaryLabel.stringValue = backlinks.count == 1 ? "1 backlink" : "\(backlinks.count) backlinks"
        } else {
            summaryLabel.stringValue = "Backlinks"
        }
    }

    // MARK: - Subview construction

    private static func makeDisclosureButton() -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .disclosure
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel("Backlinks")
        return button
    }

    private static func makeSummaryLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "Backlinks")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func makeTitlesStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func makeTitleButton(for id: NoteID) -> NSButton {
        let button = NSButton(title: id.title, target: nil, action: nil)
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        button.contentTintColor = .linkColor
        button.toolTip = id.relativePath
        button.lineBreakMode = .byTruncatingTail
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}
