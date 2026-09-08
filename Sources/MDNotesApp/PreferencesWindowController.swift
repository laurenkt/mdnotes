import AppKit

/// The Preferences window (PR-1): the library folder (L-1), the current root's path and a
/// Choose button that opens a folder chooser; and the global hotkey (W-3), a recorder showing
/// the combination. Nothing else (PR-1): the editor font has no settings, its size is the View
/// menu's (E-8, ADR-0010).
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
@MainActor
public final class PreferencesWindowController: NSWindowController {
    /// Presents a folder chooser starting at the given folder and hands the chosen folder to
    /// the completion, or nil when the user cancelled.
    public typealias FolderChooser = @MainActor (URL, @escaping @MainActor (URL?) -> Void) -> Void

    /// Shows the current library folder's path, abbreviated with `~`.
    public let libraryFolderLabel: NSTextField
    /// Opens the folder chooser.
    public let chooseButton: NSButton
    /// Shows and records the global hotkey (W-3).
    public let hotKeyRecorder: HotKeyRecorder

    /// The library folder the window shows (L-1).
    public private(set) var libraryRoot: URL
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
    ///   - defaults: where the folder and the hotkey are remembered (L-1, W-3).
    public init(libraryRoot: URL, hotKey: HotKey = .default, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.libraryRoot = LibraryRootPreference.standardized(libraryRoot)
        self.hotKey = hotKey
        libraryFolderLabel = NSTextField(labelWithString: "")
        chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
        hotKeyRecorder = HotKeyRecorder(hotKey: hotKey)
        chooseFolder = { _, _ in }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 140),
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
        hotKeyRecorder.onChange = { [weak self] recorded in self?.setHotKey(recorded) }
        window.contentView = makeContentView()
        showLibraryRoot()
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

        let hotKeyCaption = NSTextField(labelWithString: "Global hotkey:")
        hotKeyCaption.alignment = .right
        let hotKeyRow = NSStackView(views: [hotKeyCaption, hotKeyRecorder])
        hotKeyRow.orientation = .horizontal
        hotKeyRow.alignment = .firstBaseline
        hotKeyRow.spacing = 8

        let rows = NSStackView(views: [folderRow, hotKeyRow])
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
            hotKeyCaption.widthAnchor.constraint(equalToConstant: 100),
            hotKeyRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        return content
    }
}
