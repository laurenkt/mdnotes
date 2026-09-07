import AppKit
import Carbon.HIToolbox

/// The control that shows and records the global hotkey (W-3, PR-1): a button titled with the
/// combination. A click, or Space with the button focused, starts recording; the next key
/// pressed with Command, Control or Option becomes the hotkey and is reported through
/// `onChange`. Escape cancels, Delete restores the default, a key with none of those modifiers
/// is ignored, and losing focus or a second click cancels.
///
/// While recording every key press is the recorder's: it takes them as key equivalents before
/// the window and the menus see them, so typing Cmd-W or Cmd-Q as the hotkey records it rather
/// than closing the window or quitting.
@MainActor
public final class HotKeyRecorder: NSButton {
    /// The title while a combination is awaited.
    public static let recordingTitle = "Type shortcut…"

    /// The combination shown.
    public private(set) var hotKey: HotKey
    /// What Delete restores while recording.
    public let defaultHotKey: HotKey
    /// Whether the next key press is taken as the new combination.
    public private(set) var isRecording = false
    /// Called on the main thread after recording changed the combination.
    public var onChange: (@MainActor (HotKey) -> Void)?

    /// - Parameters:
    ///   - hotKey: the combination to show.
    ///   - defaultHotKey: the one Delete restores.
    public init(hotKey: HotKey, defaultHotKey: HotKey = .default) {
        self.hotKey = hotKey
        self.defaultHotKey = defaultHotKey
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(wasClicked(_:))
        showHotKey()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var acceptsFirstResponder: Bool { true }

    /// Shows `hotKey` without reporting it.
    public func showHotKey(_ hotKey: HotKey) {
        guard !isRecording else {
            self.hotKey = hotKey
            return
        }
        self.hotKey = hotKey
        showHotKey()
    }

    /// Takes focus and waits for a key press.
    public func beginRecording() {
        guard !isRecording else { return }
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        isRecording = true
        title = Self.recordingTitle
    }

    /// Stops waiting; the combination shown is unchanged.
    public func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        showHotKey()
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    public override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    @objc private func wasClicked(_ sender: Any?) {
        if isRecording { cancelRecording() } else { beginRecording() }
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(HotKey.modifierMask)
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            finishRecording(with: defaultHotKey)
            return
        }
        // A key without Command, Control or Option is not a hotkey; keep waiting.
        guard let recorded = HotKey(recording: event) else { return }
        finishRecording(with: recorded)
    }

    private func finishRecording(with recorded: HotKey) {
        isRecording = false
        let changed = recorded != hotKey
        hotKey = recorded
        showHotKey()
        if changed { onChange?(recorded) }
    }

    private func showHotKey() {
        title = hotKey.displayString
        toolTip = "Click, then type the shortcut. Escape cancels; Delete restores \(defaultHotKey.displayString)."
    }
}
