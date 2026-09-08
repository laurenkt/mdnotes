import AppKit

/// The editor font (E-8, ADR-0010): the system font for prose and the system monospaced font
/// for code, both at one point size read from `UserDefaults`. There is no family preference;
/// the v1 `EditorFontFamily` default is deleted at launch through `deleteStaleFamily(in:)`.
///
/// The size is 13 pt by default and moves in whole points between `minimumSize` and
/// `maximumSize` through the View menu's Bigger, Smaller and Actual Size (`bigger(in:)`,
/// `smaller(in:)`, `resetSize(in:)`). A stored size outside that range, from v1's wider
/// Settings field, is read as the nearest bound. `MainView` re-reads the preference whenever
/// the defaults change, so the editor follows a change at once.
public enum EditorFontPreference {
    /// `UserDefaults` key holding the point size as a number. Absent means `defaultSize`.
    nonisolated public static let sizeDefaultsKey = "EditorFontSize"
    /// The v1 family key (E-8, ADR-0010). Never read; removed at launch.
    nonisolated public static let staleFamilyDefaultsKey = "EditorFontFamily"
    /// The default point size (E-8).
    nonisolated public static let defaultSize: CGFloat = 13
    /// The smallest size Smaller reaches (E-8).
    nonisolated public static let minimumSize: CGFloat = 9
    /// The largest size Bigger reaches (E-8).
    nonisolated public static let maximumSize: CGFloat = 36
    /// How far one Bigger or Smaller moves the size.
    nonisolated public static let sizeStep: CGFloat = 1

    /// The font prose is set in: the system font at the stored size (E-8).
    @MainActor
    public static func font(from defaults: UserDefaults = .standard) -> NSFont {
        NSFont.systemFont(ofSize: size(from: defaults))
    }

    /// The font inline and fenced code are set in: the system monospaced font at `size`, the
    /// same size as the prose around it (E-8, E-2).
    @MainActor
    public static func codeFont(ofSize size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The stored size clamped to `minimumSize`...`maximumSize`, or `defaultSize` when absent
    /// or not a finite number.
    nonisolated public static func size(from defaults: UserDefaults = .standard) -> CGFloat {
        guard let number = defaults.object(forKey: sizeDefaultsKey) as? NSNumber else { return defaultSize }
        let size = CGFloat(number.doubleValue)
        return size.isFinite ? clamped(size) : defaultSize
    }

    /// Stores `size`, clamped to the range, as the editor font size (E-8). A size that is not
    /// a finite number is not stored.
    nonisolated public static func setSize(_ size: CGFloat, in defaults: UserDefaults = .standard) {
        guard size.isFinite else { return }
        defaults.set(Double(clamped(size)), forKey: sizeDefaultsKey)
    }

    /// Bigger: one step up, stopping at `maximumSize`. Returns the size now stored.
    @discardableResult
    nonisolated public static func bigger(in defaults: UserDefaults = .standard) -> CGFloat {
        let next = clamped(size(from: defaults) + sizeStep)
        setSize(next, in: defaults)
        return next
    }

    /// Smaller: one step down, stopping at `minimumSize`. Returns the size now stored.
    @discardableResult
    nonisolated public static func smaller(in defaults: UserDefaults = .standard) -> CGFloat {
        let next = clamped(size(from: defaults) - sizeStep)
        setSize(next, in: defaults)
        return next
    }

    /// Actual Size: back to `defaultSize`, stored.
    nonisolated public static func resetSize(in defaults: UserDefaults = .standard) {
        setSize(defaultSize, in: defaults)
    }

    /// `size` held within `minimumSize`...`maximumSize`.
    nonisolated public static func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size, minimumSize), maximumSize)
    }

    /// Removes the v1 family preference (E-8, ADR-0010). Called at launch; harmless when the
    /// key is already gone.
    nonisolated public static func deleteStaleFamily(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: staleFamilyDefaultsKey)
    }
}
