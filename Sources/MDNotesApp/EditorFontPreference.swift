import AppKit

/// The editor font preference (E-8): a family name and a point size, each read from
/// `UserDefaults`. Either may be absent. The default is the system monospaced font at 13 pt;
/// an absent or unusable family keeps the system monospaced family, and an absent or unusable
/// size keeps 13 pt, so the two preferences fall back independently.
///
/// The Preferences window (PR-1) writes the preference through `setFamily(_:in:)` and
/// `setSize(_:in:)`; `MainView` re-reads it whenever the defaults change, so the editor
/// follows a change at once.
public enum EditorFontPreference {
    /// `UserDefaults` key holding the font family name, e.g. `Menlo`. Absent means the system
    /// monospaced font.
    nonisolated public static let familyDefaultsKey = "EditorFontFamily"
    /// `UserDefaults` key holding the point size as a number. Absent means `defaultSize`.
    nonisolated public static let sizeDefaultsKey = "EditorFontSize"
    /// The default point size (E-8).
    nonisolated public static let defaultSize: CGFloat = 13
    /// The smallest size the Preferences window accepts.
    nonisolated public static let minimumSize: CGFloat = 6
    /// The largest size the Preferences window accepts.
    nonisolated public static let maximumSize: CGFloat = 72

    /// The font the editor should use, resolved from `defaults`.
    @MainActor
    public static func font(from defaults: UserDefaults = .standard) -> NSFont {
        let size = self.size(from: defaults)
        guard let family = family(from: defaults), let font = font(family: family, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    /// The stored family name, or nil when absent or blank, which means the system monospaced
    /// family. The name is not checked against the installed fonts; `font(from:)` does that.
    nonisolated public static func family(from defaults: UserDefaults = .standard) -> String? {
        guard let family = defaults.string(forKey: familyDefaultsKey) else { return nil }
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The stored size, or `defaultSize` when absent or not a positive finite number.
    nonisolated public static func size(from defaults: UserDefaults = .standard) -> CGFloat {
        guard let number = defaults.object(forKey: sizeDefaultsKey) as? NSNumber else { return defaultSize }
        let size = CGFloat(number.doubleValue)
        return size.isFinite && size > 0 ? size : defaultSize
    }

    /// Stores `family` as the editor font family (E-8, PR-1); nil, or a blank name, removes
    /// the preference so the system monospaced family is used.
    nonisolated public static func setFamily(_ family: String?, in defaults: UserDefaults = .standard) {
        let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: familyDefaultsKey)
        } else {
            defaults.set(trimmed, forKey: familyDefaultsKey)
        }
    }

    /// Stores `size` as the editor font size (E-8, PR-1). A size that is not a positive finite
    /// number is not stored.
    nonisolated public static func setSize(_ size: CGFloat, in defaults: UserDefaults = .standard) {
        guard size.isFinite, size > 0 else { return }
        defaults.set(Double(size), forKey: sizeDefaultsKey)
    }

    /// Whether the Preferences window accepts `size`: a finite number within `minimumSize`
    /// to `maximumSize`.
    nonisolated public static func isAcceptableSize(_ size: CGFloat) -> Bool {
        size.isFinite && size >= minimumSize && size <= maximumSize
    }

    /// The installed font families a user can choose from, sorted by name. Families whose
    /// names start with `.` are the system's private faces and are left out.
    @MainActor
    public static var availableFamilies: [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The regular face of `family`, or nil when no such family is installed.
    @MainActor
    private static func font(family: String, size: CGFloat) -> NSFont? {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }
}
