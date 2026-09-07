import AppKit

/// The Preferences window (PR-1): the library folder (L-1), the current root's path and a
/// Choose button that opens a folder chooser; the editor font (E-8), a family pop-up and a
/// size field with a stepper; and the global hotkey (W-3), a recorder showing the combination.
/// Nothing else (PR-1).
///
/// The window shows the root the app is on, handed to it by `AppDelegate` through
/// `showLibraryRoot(_:)`. Choosing a folder writes `LibraryRootPreference`, so the folder is
/// remembered across launches (L-1), and reports it through `onLibraryRootChange`;
/// `AppDelegate` tears down the library controller and rebuilds it on the new root. The
/// chooser itself is `chooseFolder`, an `NSOpenPanel` sheet by default; headless tests replace
/// it with a closure that answers at once, and drive the same path through the button.
///
/// The hotkey works the same way: `showHotKey(_:)` shows the one registered, a combination
/// recorded in `hotKeyRecorder` writes `HotKeyPreference` and is reported through
/// `onHotKeyChange`, and `AppDelegate` re-registers.
///
/// The font needs no report: `showEditorFont()` reads `EditorFontPreference` from the
/// defaults, a family chosen in `fontFamilyPopUp` or a size entered in `fontSizeField` (or
/// stepped in `fontSizeStepper`) writes it back, and `MainView`, which watches the defaults,
/// restyles the editor at once. The pop-up's first item, `systemMonospacedTitle`, is the
/// default family and removes the family preference; a stored family that is not installed
/// shows as that item, since that is the font the editor falls back to. A size outside
/// `EditorFontPreference.minimumSize` to `maximumSize`, or not a number, is not stored and the
/// field goes back to the size in use.
@MainActor
public final class PreferencesWindowController: NSWindowController {
    /// Presents a folder chooser starting at the given folder and hands the chosen folder to
    /// the completion, or nil when the user cancelled.
    public typealias FolderChooser = @MainActor (URL, @escaping @MainActor (URL?) -> Void) -> Void

    /// The pop-up item that stands for the default family (E-8).
    public static let systemMonospacedTitle = "System Monospaced"

    /// Shows the current library folder's path, abbreviated with `~`.
    public let libraryFolderLabel: NSTextField
    /// Opens the folder chooser.
    public let chooseButton: NSButton
    /// Lists `systemMonospacedTitle`, a separator, then the installed families (E-8).
    public let fontFamilyPopUp: NSPopUpButton
    /// Shows and takes the point size (E-8).
    public let fontSizeField: NSTextField
    /// Steps the point size by one (E-8).
    public let fontSizeStepper: NSStepper
    /// Shows and records the global hotkey (W-3).
    public let hotKeyRecorder: HotKeyRecorder

    /// The library folder the window shows (L-1).
    public private(set) var libraryRoot: URL
    /// The editor font family the window shows, nil for the system monospaced family (E-8).
    public private(set) var editorFontFamily: String?
    /// The editor font size the window shows (E-8).
    public private(set) var editorFontSize: CGFloat
    /// The global hotkey the window shows (W-3).
    public private(set) var hotKey: HotKey

    /// Called on the main thread after a different folder has been chosen and stored, with the
    /// new root.
    public var onLibraryRootChange: (@MainActor (URL) -> Void)?
    /// Called on the main thread after a different hotkey has been recorded and stored.
    public var onHotKeyChange: (@MainActor (HotKey) -> Void)?

    /// How the Choose button asks for a folder. Replaced by tests.
    public var chooseFolder: FolderChooser

    private let defaults: UserDefaults

    /// - Parameters:
    ///   - libraryRoot: the root in use, shown until `showLibraryRoot(_:)` says otherwise.
    ///   - hotKey: the hotkey in use, shown until `showHotKey(_:)` says otherwise.
    ///   - defaults: where the folder, the font and the hotkey are remembered (L-1, E-8, W-3).
    public init(libraryRoot: URL, hotKey: HotKey = .default, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.libraryRoot = LibraryRootPreference.standardized(libraryRoot)
        self.hotKey = hotKey
        editorFontFamily = EditorFontPreference.family(from: defaults)
        editorFontSize = EditorFontPreference.size(from: defaults)
        libraryFolderLabel = NSTextField(labelWithString: "")
        chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
        fontFamilyPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        fontSizeField = NSTextField(string: "")
        fontSizeStepper = NSStepper()
        hotKeyRecorder = HotKeyRecorder(hotKey: hotKey)
        chooseFolder = { _, _ in }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        chooseFolder = { [weak self] root, completion in
            self?.presentOpenPanel(startingAt: root, completion: completion)
        }
        chooseButton.target = self
        chooseButton.action = #selector(chooseButtonWasClicked(_:))
        fontFamilyPopUp.target = self
        fontFamilyPopUp.action = #selector(fontFamilyWasChosen(_:))
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeWasEntered(_:))
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeWasStepped(_:))
        hotKeyRecorder.onChange = { [weak self] recorded in self?.setHotKey(recorded) }
        window.contentView = makeContentView()
        showLibraryRoot()
        showEditorFont()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Library folder (L-1)

    /// Shows `root` as the library folder in use. Nothing is stored or reported.
    public func showLibraryRoot(_ root: URL) {
        libraryRoot = LibraryRootPreference.standardized(root)
        showLibraryRoot()
    }

    /// The user chose `root` as the library folder (L-1, PR-1). A folder that is the current
    /// root, however spelled, changes nothing. Otherwise the folder is stored, shown, and
    /// reported through `onLibraryRootChange`.
    public func setLibraryRoot(_ root: URL) {
        let root = LibraryRootPreference.standardized(root)
        guard root != libraryRoot else { return }
        LibraryRootPreference.set(root, in: defaults)
        libraryRoot = root
        showLibraryRoot()
        onLibraryRootChange?(root)
    }

    // MARK: - Editor font (E-8)

    /// Shows the family and size stored in the defaults (E-8). Nothing is stored.
    public func showEditorFont() {
        editorFontFamily = EditorFontPreference.family(from: defaults)
        editorFontSize = EditorFontPreference.size(from: defaults)
        showEditorFontFamily()
        showEditorFontSize()
    }

    /// The user chose `family`, nil for the system monospaced family (E-8, PR-1). The family
    /// shown changes nothing. Otherwise it is stored and shown; the editor follows the
    /// defaults.
    public func setEditorFontFamily(_ family: String?) {
        let family = family.flatMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard family != editorFontFamily else { return }
        EditorFontPreference.setFamily(family, in: defaults)
        editorFontFamily = family
        showEditorFontFamily()
    }

    /// The user entered `size` (E-8, PR-1). The size shown changes nothing; a size the window
    /// does not accept (`EditorFontPreference.isAcceptableSize`) is not stored and the field
    /// shows the size in use again. Otherwise it is stored and shown; the editor follows the
    /// defaults.
    public func setEditorFontSize(_ size: CGFloat) {
        guard EditorFontPreference.isAcceptableSize(size), size != editorFontSize else {
            showEditorFontSize()
            return
        }
        EditorFontPreference.setSize(size, in: defaults)
        editorFontSize = size
        showEditorFontSize()
    }

    // MARK: - Global hotkey (W-3)

    /// Shows `hotKey` as the global hotkey in use (W-3). Nothing is stored or reported.
    public func showHotKey(_ hotKey: HotKey) {
        self.hotKey = hotKey
        hotKeyRecorder.showHotKey(hotKey)
    }

    /// The user recorded `hotKey` (W-3, PR-1). The combination in use changes nothing.
    /// Otherwise it is stored, shown, and reported through `onHotKeyChange`.
    public func setHotKey(_ hotKey: HotKey) {
        guard hotKey != self.hotKey else { return }
        HotKeyPreference.set(hotKey, in: defaults)
        self.hotKey = hotKey
        hotKeyRecorder.showHotKey(hotKey)
        onHotKeyChange?(hotKey)
    }

    // MARK: - Actions

    @objc private func chooseButtonWasClicked(_ sender: Any?) {
        chooseFolder(libraryRoot) { [weak self] chosen in
            guard let self, let chosen else { return }
            setLibraryRoot(chosen)
        }
    }

    @objc private func fontFamilyWasChosen(_ sender: Any?) {
        guard let item = fontFamilyPopUp.selectedItem, item.title != Self.systemMonospacedTitle else {
            setEditorFontFamily(nil)
            return
        }
        setEditorFontFamily(item.title)
    }

    @objc private func fontSizeWasEntered(_ sender: Any?) {
        let text = fontSizeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(text) else {
            showEditorFontSize()
            return
        }
        setEditorFontSize(CGFloat(size))
    }

    @objc private func fontSizeWasStepped(_ sender: Any?) {
        setEditorFontSize(CGFloat(fontSizeStepper.doubleValue))
    }

    // MARK: - Showing

    private func presentOpenPanel(startingAt root: URL, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = root
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your notes."
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.url : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private func showLibraryRoot() {
        libraryFolderLabel.stringValue = (libraryRoot.path as NSString).abbreviatingWithTildeInPath
        libraryFolderLabel.toolTip = libraryRoot.path
    }

    private func showEditorFontFamily() {
        if let editorFontFamily, fontFamilyPopUp.item(withTitle: editorFontFamily) != nil {
            fontFamilyPopUp.selectItem(withTitle: editorFontFamily)
        } else {
            fontFamilyPopUp.selectItem(withTitle: Self.systemMonospacedTitle)
        }
    }

    private func showEditorFontSize() {
        fontSizeField.stringValue = Self.sizeText(editorFontSize)
        fontSizeStepper.doubleValue = Double(editorFontSize)
    }

    /// `13` for a whole size, `11.5` otherwise.
    private static func sizeText(_ size: CGFloat) -> String {
        size == size.rounded() ? String(Int(size)) : String(Double(size))
    }

    private func makeContentView() -> NSView {
        let folderCaption = NSTextField(labelWithString: "Library folder:")
        folderCaption.alignment = .right
        libraryFolderLabel.lineBreakMode = .byTruncatingMiddle
        libraryFolderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseButton.bezelStyle = .rounded
        let folderRow = NSStackView(views: [folderCaption, libraryFolderLabel, chooseButton])
        folderRow.orientation = .horizontal
        folderRow.alignment = .firstBaseline
        folderRow.spacing = 8

        let fontCaption = NSTextField(labelWithString: "Editor font:")
        fontCaption.alignment = .right
        fontFamilyPopUp.addItem(withTitle: Self.systemMonospacedTitle)
        fontFamilyPopUp.menu?.addItem(.separator())
        fontFamilyPopUp.addItems(withTitles: EditorFontPreference.availableFamilies)
        fontSizeField.alignment = .right
        fontSizeField.cell?.sendsActionOnEndEditing = true
        fontSizeStepper.minValue = Double(EditorFontPreference.minimumSize)
        fontSizeStepper.maxValue = Double(EditorFontPreference.maximumSize)
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.autorepeat = true
        let sizeUnit = NSTextField(labelWithString: "pt")
        let fontRow = NSStackView(views: [fontCaption, fontFamilyPopUp, fontSizeField, fontSizeStepper, sizeUnit])
        fontRow.orientation = .horizontal
        fontRow.alignment = .firstBaseline
        fontRow.spacing = 8
        fontRow.setCustomSpacing(2, after: fontSizeField)

        let hotKeyCaption = NSTextField(labelWithString: "Global hotkey:")
        hotKeyCaption.alignment = .right
        let hotKeyRow = NSStackView(views: [hotKeyCaption, hotKeyRecorder])
        hotKeyRow.orientation = .horizontal
        hotKeyRow.alignment = .firstBaseline
        hotKeyRow.spacing = 8

        let rows = NSStackView(views: [folderRow, fontRow, hotKeyRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            folderRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            folderCaption.widthAnchor.constraint(equalToConstant: 100),
            fontCaption.widthAnchor.constraint(equalToConstant: 100),
            hotKeyCaption.widthAnchor.constraint(equalToConstant: 100),
            fontFamilyPopUp.widthAnchor.constraint(equalToConstant: 200),
            fontSizeField.widthAnchor.constraint(equalToConstant: 48),
            hotKeyRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        return content
    }
}
