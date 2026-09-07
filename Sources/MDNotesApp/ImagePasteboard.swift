import AppKit
import MDNotesCore
import UniformTypeIdentifiers

/// An image offered to the editor by a paste or a drop (I-1), as it sits on the pasteboard:
/// nothing has been read from disk or decoded yet, so taking one is cheap on the main thread.
/// `encoded()` does the reading and converting, off the main thread (PF-6).
public enum ImageSource: Hashable, Sendable {
    /// Image bytes off the pasteboard, with the file extension of the format they are in
    /// (`png`, `jpg`, `tiff`, ...).
    case data(Data, fileExtension: String)
    /// An image file on disk, to be copied into the library.
    case file(URL)

    /// Why a source could not be turned into bytes to store.
    public enum Failure: Error, Hashable, Sendable {
        /// The data is in no format `NSBitmapImageRep` can decode, so it cannot be re-encoded.
        case undecodable
    }

    /// The bytes to store and the extension to store them under. PNG and JPEG data are stored
    /// as they are, under `png` and `jpg`; data in any other format (TIFF, which is what most
    /// apps put on the clipboard, GIF, HEIC) is re-encoded as PNG so the library holds one
    /// lossless format that everything opens. A file is copied byte for byte under its own
    /// extension, lowercased. Reads the file and decodes the data: call it off the main thread
    /// (PF-6).
    public func encoded() throws -> (bytes: [UInt8], fileExtension: String) {
        switch self {
        case .file(let url):
            return (Array(try Data(contentsOf: url)), ImageStore.normalizedExtension(url.pathExtension))
        case .data(let data, let fileExtension):
            switch ImageStore.normalizedExtension(fileExtension) {
            case "png": return (Array(data), "png")
            case "jpg", "jpeg": return (Array(data), "jpg")
            default:
                guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:])
                else { throw Failure.undecodable }
                return (Array(png), "png")
            }
        }
    }
}

/// Reads the image a pasteboard offers (I-1). Used by `EditorTextView` for the general
/// pasteboard on paste and for the drag pasteboard on drop.
public enum ImagePasteboard {
    /// The image on `pasteboard`, or nil when it offers none. An image file comes first: a
    /// file URL whose extension names an image type (a drag from the Finder, or a copied
    /// file). Then image data, preferring PNG, then JPEG, then TIFF, then any other type
    /// `NSImage` can read. A pasteboard holding only text, or a file that is not an image, is
    /// nil, and the paste or drop is the text view's own.
    @MainActor
    public static func image(on pasteboard: NSPasteboard) -> ImageSource? {
        if let url = imageFileURL(on: pasteboard) { return .file(url) }
        for type in preferredDataTypes(on: pasteboard) {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            return .data(data, fileExtension: fileExtension(for: type))
        }
        return nil
    }

    /// True when `image(on:)` would find an image, without reading any data.
    @MainActor
    public static func hasImage(on pasteboard: NSPasteboard) -> Bool {
        imageFileURL(on: pasteboard) != nil || !preferredDataTypes(on: pasteboard).isEmpty
    }

    /// The first file URL on the pasteboard whose extension is an image type. Decided from the
    /// name alone, so no file is touched on the main thread (PF-6).
    @MainActor
    private static func imageFileURL(on pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls.first { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
    }

    /// The image data types `pasteboard` offers, best first.
    @MainActor
    private static func preferredDataTypes(on pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let available = Set(pasteboard.types ?? [])
        var ordered: [NSPasteboard.PasteboardType] = [.png, jpeg, .tiff]
        for identifier in NSImage.imageTypes {
            let type = NSPasteboard.PasteboardType(identifier)
            if !ordered.contains(type) { ordered.append(type) }
        }
        return ordered.filter(available.contains)
    }

    private static let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    /// The extension for data of `type`: the type's preferred one, or `tiff` for an identifier
    /// with none (the old TIFF pasteboard type maps to `public.tiff`, which has one).
    private static func fileExtension(for type: NSPasteboard.PasteboardType) -> String {
        switch type {
        case .png: return "png"
        case jpeg: return "jpg"
        case .tiff: return "tiff"
        default: return UTType(type.rawValue)?.preferredFilenameExtension ?? "tiff"
        }
    }
}
