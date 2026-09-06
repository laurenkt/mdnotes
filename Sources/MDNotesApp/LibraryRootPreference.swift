import Foundation

/// The library folder preference (L-1): the root the app opens at launch, read from
/// `UserDefaults`. Absent means the default, `~/Documents/MDnotes`. The Preferences window
/// (PR-1) writes it, and `AppDelegate` reads it once at launch and rebuilds the library when
/// the Preferences window reports a change.
///
/// Stored as a plain path (P-4: not sandboxed, so no bookmark is needed). A blank stored value
/// is treated as absent.
public enum LibraryRootPreference {
    /// `UserDefaults` key holding the root folder's path.
    nonisolated public static let defaultsKey = "LibraryRoot"

    /// The root to open, resolved from `defaults`: the stored folder, or the default root when
    /// nothing usable is stored.
    nonisolated public static func root(from defaults: UserDefaults = .standard) -> URL {
        guard let path = defaults.string(forKey: defaultsKey) else { return LibraryController.defaultRoot }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return LibraryController.defaultRoot }
        return standardized(URL(fileURLWithPath: trimmed, isDirectory: true))
    }

    /// Remembers `root` as the folder to open at the next launch (L-1).
    nonisolated public static func set(_ root: URL, in defaults: UserDefaults = .standard) {
        defaults.set(standardized(root).path, forKey: defaultsKey)
    }

    /// One form of a folder URL, so two spellings of the same folder compare equal: a file URL,
    /// standardized, marked as a directory, with no trailing slash.
    nonisolated public static func standardized(_ root: URL) -> URL {
        URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true)
    }
}
