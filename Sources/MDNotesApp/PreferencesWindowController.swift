import AppKit

/// The Preferences window (PR-1). This task gives it the library folder (L-1): the current
/// root's path and a Choose button that opens a folder chooser. The editor font and the global
/// hotkey join it in M5.3.
///
/// The window shows the root the app is on, handed to it by `AppDelegate` through
/// `showLibraryRoot(_:)`. Choosing a folder writes `LibraryRootPreference`, so the folder is
/// remembered across launches (L-1), and reports it through `onLibraryRootChange`;
/// `AppDelegate` tears down the library controller and rebuilds it on the new root. The
/// chooser itself is `chooseFolder`, an `NSOpenPanel` sheet by default; headless tests replace
/// it with a closure that answers at once, and drive the same path through the button.
@MainActor
public final class PreferencesWindowController: NSWindowController {
    /// Presents a folder chooser starting at the given folder and hands the chosen folder to
    /// the completion, or nil when the user cancelled.
    public typealias FolderChooser = @MainActor (URL, @escaping @MainActor (URL?) -> Void) -> Void

    /// Shows the current library folder's path, abbreviated with `~`.
    public let libraryFolderLabel: NSTextField
    /// Opens the folder chooser.
    public let chooseButton: NSButton

    /// The library folder the window shows (L-1).
    public private(set) var libraryRoot: URL

    /// Called on the main thread after a different folder has been chosen and stored, with the
    /// new root.
    public var onLibraryRootChange: (@MainActor (URL) -> Void)?

    /// How the Choose button asks for a folder. Replaced by tests.
    public var chooseFolder: FolderChooser

    private let defaults: UserDefaults

    /// - Parameters:
    ///   - libraryRoot: the root in use, shown until `showLibraryRoot(_:)` says otherwise.
    ///   - defaults: where a chosen folder is remembered (L-1).
    public init(libraryRoot: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.libraryRoot = LibraryRootPreference.standardized(libraryRoot)
        libraryFolderLabel = NSTextField(labelWithString: "")
        chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
        chooseFolder = { _, _ in }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 90),
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
        window.contentView = makeContentView()
        showLibraryRoot()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

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

    @objc private func chooseButtonWasClicked(_ sender: Any?) {
        chooseFolder(libraryRoot) { [weak self] chosen in
            guard let self, let chosen else { return }
            setLibraryRoot(chosen)
        }
    }

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
        let caption = NSTextField(labelWithString: "Library folder:")
        caption.alignment = .right
        libraryFolderLabel.lineBreakMode = .byTruncatingMiddle
        libraryFolderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseButton.bezelStyle = .rounded
        let row = NSStackView(views: [caption, libraryFolderLabel, chooseButton])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            caption.widthAnchor.constraint(equalToConstant: 100),
        ])
        return content
    }
}
