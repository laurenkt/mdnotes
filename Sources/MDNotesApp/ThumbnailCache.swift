import CoreGraphics
import Foundation
import ImageIO
import Synchronization

/// Thumbnails of the library's image files for list rows (S-11) and editor attachments (E-9),
/// made off the main thread and kept in memory (PF-8).
///
/// A request names a file and the pixel size wanted (the longest side); the work runs on a
/// background queue with at most `concurrentJobs` in flight, the rest waiting in order. A job
/// reads the file's modification date, serves the cached thumbnail when the date matches the
/// one it was made from, and otherwise downsamples the file with `CGImageSource` (never a full
/// decode of a large image), replaces the stale entry, evicts least recently used entries
/// until the total is under `maximumBytes`, and calls the completion on the main thread.
/// Requests for a file already in flight join it rather than decoding again.
///
/// The main thread only draws cached images: `cachedImage(for:pixelSize:)` touches no file and
/// takes a lock no job holds while doing I/O. It answers with the latest thumbnail made for
/// that path, which a file changed since keeps until a request notices the new date.
public final class ThumbnailCache: Sendable {
    /// PF-8: 50 MB of decoded thumbnails.
    public static let defaultMaximumBytes = 50 * 1024 * 1024
    public static let defaultConcurrentJobs = 2

    /// Called on the main thread with the thumbnail, or nil when the file cannot be read or is
    /// not an image.
    public typealias Completion = @MainActor @Sendable (CGImage?) -> Void
    /// Called on the background queue with the file's URL just before it is downsampled, so a
    /// test can count decodes or hold a job to observe the queue. Never installed in production.
    public typealias Observer = @Sendable (URL) -> Void

    /// One file at one size: what a caller looks up. The date the thumbnail was made from lives
    /// in the entry, so a changed file replaces its entry instead of piling up beside it.
    private struct Slot: Hashable {
        let path: String
        let pixelSize: Int
    }

    private struct Entry {
        let modificationDate: Date
        let image: CGImage
        let bytes: Int
        /// The tick of the last lookup or insertion; the smallest goes first at eviction.
        var lastUse: UInt64
    }

    private struct Job {
        let url: URL
        var completions: [Completion]
    }

    private struct State {
        var entries: [Slot: Entry] = [:]
        var bytes = 0
        var tick: UInt64 = 0
        /// Every request not yet completed, waiting or running, so a repeat joins it.
        var jobs: [Slot: Job] = [:]
        /// Slots waiting for a turn, oldest first.
        var waiting: [Slot] = []
        var running = 0

        mutating func nextTick() -> UInt64 {
            tick += 1
            return tick
        }
    }

    public let maximumBytes: Int
    public let concurrentJobs: Int
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "MDNotes.ThumbnailCache", qos: .userInitiated, attributes: .concurrent)
    private let willGenerate: Observer

    public convenience init(
        maximumBytes: Int = ThumbnailCache.defaultMaximumBytes,
        concurrentJobs: Int = ThumbnailCache.defaultConcurrentJobs
    ) {
        self.init(maximumBytes: maximumBytes, concurrentJobs: concurrentJobs, willGenerate: { _ in })
    }

    public init(maximumBytes: Int, concurrentJobs: Int, willGenerate: @escaping Observer) {
        self.maximumBytes = maximumBytes
        self.concurrentJobs = max(1, concurrentJobs)
        self.willGenerate = willGenerate
    }

    // MARK: - Lookup

    /// The latest thumbnail made for the file at `url` at `pixelSize`, or nil when none is
    /// cached. Touches no file, so the main thread may call it while drawing (PF-8). Counts as
    /// a use for eviction.
    public func cachedImage(for url: URL, pixelSize: Int) -> CGImage? {
        let slot = Slot(path: url.path, pixelSize: pixelSize)
        return state.withLock { state in
            guard let entry = state.entries[slot] else { return nil }
            let tick = state.nextTick()
            state.entries[slot]?.lastUse = tick
            return entry.image
        }
    }

    /// Decoded bytes held, across every entry.
    public var bytes: Int { state.withLock { $0.bytes } }

    /// Number of thumbnails held.
    public var count: Int { state.withLock { $0.entries.count } }

    /// What an image costs the cache: its decoded pixel buffer.
    public static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    // MARK: - Source size

    /// An image file's own size (E-9): its pixels, and its points, the pixels over its DPI
    /// scale as `NSImageRep.size` reports them (a 144 DPI screenshot is half its pixels in
    /// points; a file that states no DPI is 72, one point a pixel). Both are as the image is
    /// shown, after its orientation, as the thumbnails are.
    public struct SourceSize: Sendable, Equatable {
        public let pixels: CGSize
        public let points: CGSize

        public init(pixels: CGSize, points: CGSize) {
            self.pixels = pixels
            self.points = points
        }
    }

    /// Reads the size of the image file at `url` from its header, decoding nothing, and calls
    /// `completion` on the main thread with it, or with nil when the file is not an image
    /// ImageIO can read. The read runs on the background queue; the main thread never touches
    /// the file (PF-8).
    public func requestSourceSize(_ url: URL, completion: @escaping @MainActor @Sendable (SourceSize?) -> Void) {
        queue.async {
            let size = Self.sourceSize(of: url)
            DispatchQueue.main.async { completion(size) }
        }
    }

    /// The size of the image file at `url`, read from its header; nil when it is not an image
    /// ImageIO can read. Does file I/O: never call it on the main thread.
    public static func sourceSize(of url: URL) -> SourceSize? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0, height > 0
        else { return nil }
        let dpi = { (key: CFString) -> Double in
            guard let value = (properties[key] as? NSNumber)?.doubleValue, value > 0 else { return 72 }
            return value
        }
        var pixels = CGSize(width: width, height: height)
        var points = CGSize(
            width: width * 72 / dpi(kCGImagePropertyDPIWidth), height: height * 72 / dpi(kCGImagePropertyDPIHeight))
        // EXIF orientations 5 to 8 turn the image a quarter: its shown width is its stored height.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            pixels = CGSize(width: pixels.height, height: pixels.width)
            points = CGSize(width: points.height, height: points.width)
        }
        return SourceSize(pixels: pixels, points: points)
    }

    // MARK: - Requests

    /// Asks for the thumbnail of the file at `url` with its longest side at most `pixelSize`
    /// pixels. Returns at once; `completion` runs later on the main thread, with the cached
    /// image when the file's modification date still matches, otherwise with a fresh one, or
    /// nil when the file is unreadable or not an image.
    public func request(_ url: URL, pixelSize: Int, completion: @escaping Completion) {
        let slot = Slot(path: url.path, pixelSize: pixelSize)
        state.withLock { state in
            if state.jobs[slot] != nil {
                state.jobs[slot]?.completions.append(completion)
                return
            }
            state.jobs[slot] = Job(url: url, completions: [completion])
            state.waiting.append(slot)
            startWaitingJobs(&state)
        }
    }

    /// Starts waiting jobs while fewer than `concurrentJobs` run. Called under the lock.
    private func startWaitingJobs(_ state: inout State) {
        while state.running < concurrentJobs, !state.waiting.isEmpty {
            let slot = state.waiting.removeFirst()
            guard let job = state.jobs[slot] else { continue }
            state.running += 1
            queue.async { self.run(slot, url: job.url) }
        }
    }

    /// One job, on the background queue: date, lookup, decode, store, then hand over on main.
    private func run(_ slot: Slot, url: URL) {
        let image = thumbnail(for: slot, url: url)
        let completions = state.withLock { state -> [Completion] in
            let completions = state.jobs.removeValue(forKey: slot)?.completions ?? []
            state.running -= 1
            startWaitingJobs(&state)
            return completions
        }
        DispatchQueue.main.async {
            for completion in completions { completion(image) }
        }
    }

    private func thumbnail(for slot: Slot, url: URL) -> CGImage? {
        // Read through `FileManager`, which stats the file every time; `URL.resourceValues`
        // caches per URL and would keep reporting the date it saw first.
        guard
            let modificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                as? Date
        else { return nil }
        let cached = state.withLock { state -> CGImage? in
            guard let entry = state.entries[slot] else { return nil }
            guard entry.modificationDate == modificationDate else {
                // The file changed: the old thumbnail must not outlive it, even if the new
                // file turns out not to be an image.
                state.entries.removeValue(forKey: slot)
                state.bytes -= entry.bytes
                return nil
            }
            let tick = state.nextTick()
            state.entries[slot]?.lastUse = tick
            return entry.image
        }
        if let cached { return cached }
        willGenerate(url)
        guard let image = Self.downsample(url, pixelSize: slot.pixelSize) else { return nil }
        store(image, at: slot, modificationDate: modificationDate)
        return image
    }

    /// Puts `image` in `slot`, replacing what was there, then evicts least recently used
    /// entries until the total fits. An image that alone exceeds the bound is handed to the
    /// caller but not kept.
    private func store(_ image: CGImage, at slot: Slot, modificationDate: Date) {
        let bytes = Self.cost(of: image)
        state.withLock { state in
            if let old = state.entries.removeValue(forKey: slot) { state.bytes -= old.bytes }
            guard bytes <= maximumBytes else { return }
            state.entries[slot] = Entry(
                modificationDate: modificationDate, image: image, bytes: bytes, lastUse: state.nextTick())
            state.bytes += bytes
            while state.bytes > maximumBytes,
                let oldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse })
            {
                state.entries.removeValue(forKey: oldest.key)
                state.bytes -= oldest.value.bytes
            }
        }
    }

    /// Downsamples the file at `url` so its longest side is at most `pixelSize`, decoding only
    /// what the thumbnail needs. Honours the file's orientation. Nil when the file is not an
    /// image ImageIO can read.
    private static func downsample(_ url: URL, pixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, pixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
