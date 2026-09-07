import AppKit
import Carbon.HIToolbox

/// A key combination for the global hotkey (W-3): a virtual key code and the modifier keys
/// held with it. The default is Ctrl-Cmd-N.
///
/// Only Command, Control, Option and Shift count as modifiers; the other flags a key event
/// carries (Function, Caps Lock, the numeric keypad) are dropped, so an arrow key or a keypad
/// key records as the key alone. A combination needs Command, Control or Option: a plain key,
/// or Shift with a key, would swallow ordinary typing in every application, so the recorder
/// refuses it.
public struct HotKey: Equatable, Sendable {
    /// The modifier flags a hotkey can carry.
    public static let modifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    /// The virtual key code, as `NSEvent.keyCode` and Carbon `kVK_*` name it.
    public let keyCode: UInt16
    /// The modifiers held with the key, within `modifierMask`.
    public let modifiers: NSEvent.ModifierFlags

    /// Ctrl-Cmd-N (W-3).
    public static let `default` = HotKey(keyCode: UInt16(kVK_ANSI_N), modifiers: [.control, .command])

    /// - Parameters:
    ///   - keyCode: the virtual key code.
    ///   - modifiers: the modifiers; anything outside `modifierMask` is dropped.
    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.modifierMask)
    }

    /// The combination a key press in the recorder names, or nil when the press carries none
    /// of Command, Control and Option.
    public init?(recording event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.modifierMask)
        guard Self.isAcceptable(modifiers) else { return nil }
        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }

    /// Whether `modifiers` hold at least one of Command, Control and Option.
    public static func isAcceptable(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    /// The modifiers as Carbon's `RegisterEventHotKey` takes them.
    public var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// The combination as a menu shows it: modifier glyphs in the standard order (Control,
    /// Option, Shift, Command) and the key's name, e.g. `⌃⌘N`.
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// The name of a key: a glyph or a name for the keys that have one, otherwise the character
    /// the key produces on the current keyboard layout without modifiers, upper-cased. A key
    /// the layout does not name shows its code in brackets.
    public static func keyName(for keyCode: UInt16) -> String {
        if let name = specialKeyNames[keyCode] { return name }
        if let character = character(for: keyCode), !character.isEmpty {
            return character.uppercased()
        }
        return "[\(keyCode)]"
    }

    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Return): "↩", UInt16(kVK_ANSI_KeypadEnter): "⌤", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Space): "Space", UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_DownArrow): "↓", UInt16(kVK_UpArrow): "↑", UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_Help): "Help", UInt16(kVK_ANSI_KeypadClear): "⌧",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    /// What `keyCode` types on the current ASCII-capable keyboard layout with no modifiers, or
    /// nil when the layout cannot be read.
    private static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, units.count, &length, &units)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: units, count: length)
        // Control characters (Return, Tab and so on reach here only if the table misses one)
        // have no useful spelling.
        return text.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) ? text : nil
    }
}

/// The global hotkey preference (W-3, PR-1): the combination read from `UserDefaults`. Absent,
/// or unusable, means the default, Ctrl-Cmd-N. The Preferences window's recorder writes it and
/// `AppDelegate` reads it at launch and re-registers when the recorder reports a change.
///
/// Stored as two numbers, the key code and the modifier flags. The two are one preference:
/// unless both are present and make an acceptable combination the default is used.
public enum HotKeyPreference {
    /// `UserDefaults` key holding the virtual key code as a number.
    nonisolated public static let keyCodeDefaultsKey = "GlobalHotKeyKeyCode"
    /// `UserDefaults` key holding the modifier flags (`NSEvent.ModifierFlags.rawValue`) as a
    /// number.
    nonisolated public static let modifiersDefaultsKey = "GlobalHotKeyModifiers"

    /// The combination to register, resolved from `defaults`.
    public static func hotKey(from defaults: UserDefaults = .standard) -> HotKey {
        guard let keyCodeNumber = defaults.object(forKey: keyCodeDefaultsKey) as? NSNumber,
            let modifiersNumber = defaults.object(forKey: modifiersDefaultsKey) as? NSNumber
        else { return .default }
        let keyCode = keyCodeNumber.int64Value
        let rawModifiers = modifiersNumber.int64Value
        guard keyCode >= 0, keyCode < 0x80, rawModifiers >= 0, rawModifiers <= Int64(UInt32.max) else {
            return .default
        }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(rawModifiers))
        guard modifiers.isSubset(of: HotKey.modifierMask), HotKey.isAcceptable(modifiers) else { return .default }
        return HotKey(keyCode: UInt16(keyCode), modifiers: modifiers)
    }

    /// Remembers `hotKey` as the combination to register at the next launch.
    public static func set(_ hotKey: HotKey, in defaults: UserDefaults = .standard) {
        defaults.set(Int(hotKey.keyCode), forKey: keyCodeDefaultsKey)
        defaults.set(Int(hotKey.modifiers.rawValue), forKey: modifiersDefaultsKey)
    }
}
