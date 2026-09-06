import AppKit

/// The editor font preference (E-8): a family name and a point size, each read from
/// `UserDefaults`. Either may be absent. The default is the system monospaced font at 13 pt;
/// an absent or unusable family keeps the system monospaced family, and an absent or unusable
/// size keeps 13 pt, so the two preferences fall back independently.
///
/// Nothing here writes the preference: the Preferences window (PR-1, M5.3) does that, and
/// `MainView` re-reads it whenever the defaults change.
public enum EditorFontPreference {
    /// `UserDefaults` key holding the font family name, e.g. `Menlo`. Absent means the system
    /// monospaced font.
    nonisolated public static let familyDefaultsKey = "EditorFontFamily"
    /// `UserDefaults` key holding the point size as a number. Absent means `defaultSize`.
    nonisolated public static let sizeDefaultsKey = "EditorFontSize"
    /// The default point size (E-8).
    nonisolated public static let defaultSize: CGFloat = 13

    /// The font the editor should use, resolved from `defaults`.
    @MainActor
    public static func font(from defaults: UserDefaults = .standard) -> NSFont {
        let size = self.size(from: defaults)
        guard let family = family(from: defaults), let font = font(family: family, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    /// The stored family name, or nil when absent or blank.
    private static func family(from defaults: UserDefaults) -> String? {
        guard let family = defaults.string(forKey: familyDefaultsKey) else { return nil }
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The stored size, or `defaultSize` when absent or not a positive finite number.
    private static func size(from defaults: UserDefaults) -> CGFloat {
        guard let number = defaults.object(forKey: sizeDefaultsKey) as? NSNumber else { return defaultSize }
        let size = CGFloat(number.doubleValue)
        return size.isFinite && size > 0 ? size : defaultSize
    }

    /// The regular face of `family`, or nil when no such family is installed.
    @MainActor
    private static func font(family: String, size: CGFloat) -> NSFont? {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }
}
