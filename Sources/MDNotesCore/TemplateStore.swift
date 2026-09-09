import Foundation

/// The templates of one library (TP-1): the `.md` files directly inside `templates/` under
/// the root, each named by its filename without the extension. Nothing deeper counts, hidden
/// files are skipped as everywhere else (L-3), and a template is never a note: the scanner
/// leaves `templates/` alone and the watcher reports what happens in it by name, in
/// `LibraryChanges.templates`, rather than as note ids (TP-7).
///
/// This is the disk view only. `names()` lists the folder as it is now, so the owner re-lists
/// on every watcher batch that names a template; the folder holds a handful of files, and one
/// directory read is cheaper than tracking additions and removals by hand. `read(_:)` hands a
/// file to `TemplateParser` (TP-2). Synchronous file I/O throughout: call it off the main
/// thread (PF-6).
public struct TemplateStore: Sendable {
    /// The folder directly under the root that holds templates (TP-1, L-3).
    public static let folderName = "templates"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `templates/` under the root, whether or not it exists.
    public var directory: URL {
        root.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// The templates on disk right now, by name, sorted case-insensitively with the exact
    /// spelling as the tie-breaker. A library without a `templates/` folder has no templates
    /// and lists nothing; a folder that exists but cannot be listed throws.
    public func names() throws -> [String] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.nameKey, .isDirectoryKey], options: [])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return []
        }
        var names: [String] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.nameKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard let name = Self.name(forFileName: values?.name ?? entry.lastPathComponent) else { continue }
            names.append(name)
        }
        return names.sorted { a, b in
            let (fa, fb) = (CaseFolding.fold(a), CaseFolding.fold(b))
            return fa == fb ? a < b : fa < fb
        }
    }

    /// The file behind the template called `name`.
    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name + LibraryScanner.noteExtension, isDirectory: false)
    }

    /// Reads and parses the template called `name` (TP-2). A file that cannot be read or is
    /// not UTF-8 throws; one that reads but is not a usable template is `.failure` with the
    /// rejection whose `message` the list shows inline.
    public func read(_ name: String) throws -> Result<TemplateParser.Template, TemplateParser.Rejection> {
        let data = try Data(contentsOf: url(for: name))
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url(for: name).path])
        }
        do {
            return .success(try TemplateParser.parse(text))
        } catch {
            return .failure(error)
        }
    }

    /// The name of the template a file at root-relative `relativePath` (with `/` separators)
    /// would be, or nil when that path is not a template: anything not directly inside
    /// `templates/`, not `.md`, or hidden (TP-1, L-3).
    public static func name(forRelativePath relativePath: String) -> String? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == folderName else { return nil }
        return name(forFileName: String(components[1]))
    }

    /// `fileName` without `.md`, or nil for a hidden file, a non-note extension, or `.md` alone.
    private static func name(forFileName fileName: String) -> String? {
        guard !fileName.hasPrefix("."), fileName.hasSuffix(LibraryScanner.noteExtension) else { return nil }
        let name = String(fileName.dropLast(LibraryScanner.noteExtension.count))
        return name.isEmpty ? nil : name
    }
}
