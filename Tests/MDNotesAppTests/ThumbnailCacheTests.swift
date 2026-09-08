import AppKit
import Foundation
import MDNotesApp
import Synchronization
import XCTest

/// `ThumbnailCache` against real PNG files in a temp folder (PF-8): a miss downsamples with
/// ImageIO to the pixel size asked for, a hit is served without decoding, the bound evicts the
/// least recently used entry, a changed modification date invalidates, and a request returns
/// before any work is done with at most two jobs running. Every completion arrives on main.
@MainActor
final class ThumbnailCacheTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    /// Decodes seen by the cache under test, counted by its `willGenerate` observer.
    private final class Decodes: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-thumbnails-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Miss and hit

    func testPF8_missDownsamplesToRequestedPixelSizeAndCaches() async throws {
        let url = try writePNG("wide.png", seed: 1, width: 64, height: 40)
        let decodes = Decodes()
        let cache = ThumbnailCache(maximumBytes: 1 << 20, concurrentJobs: 2) { _ in decodes.increment() }
        XCTAssertNil(cache.cachedImage(for: url, pixelSize: 16), "nothing is cached before a request")
        XCTAssertEqual(cache.count, 0)

        let thumb = try await image(from: cache, url, pixelSize: 16)
        XCTAssertEqual(thumb.width, 16, "the longest side is the pixel size asked for")
        XCTAssertEqual(thumb.height, 10, "the aspect ratio is kept")
        XCTAssertEqual(decodes.value, 1)
        XCTAssertTrue(cache.cachedImage(for: url, pixelSize: 16) === thumb, "the same image is now cached")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.bytes, ThumbnailCache.cost(of: thumb))
        XCTAssertNil(cache.cachedImage(for: url, pixelSize: 32), "a different size is a different entry")
    }

    func testPF8_smallImageIsNotUpscaled() async throws {
        let url = try writePNG("tiny.png", seed: 1, width: 6, height: 4)
        let cache = ThumbnailCache()
        let thumb = try await image(from: cache, url, pixelSize: 64)
        XCTAssertEqual(thumb.width, 6)
        XCTAssertEqual(thumb.height, 4)
    }

    func testPF8_hitServesCachedImageWithoutDecoding() async throws {
        let url = try writePNG("pic.png", seed: 2)
        let decodes = Decodes()
        let cache = ThumbnailCache(maximumBytes: 1 << 20, concurrentJobs: 2) { _ in decodes.increment() }
        let first = try await image(from: cache, url, pixelSize: 32)
        let second = try await image(from: cache, url, pixelSize: 32)
        XCTAssertTrue(first === second, "a hit hands back the cached image itself")
        XCTAssertEqual(decodes.value, 1, "a hit does not decode")
        XCTAssertEqual(cache.count, 1)
    }

    func testPF8_requestsForTheSameFileInFlightJoinOneDecode() async throws {
        let url = try writePNG("shared.png", seed: 3)
        let decodes = Decodes()
        let cache = ThumbnailCache(maximumBytes: 1 << 20, concurrentJobs: 2) { _ in decodes.increment() }
        let images = Results()
        let done = expectation(description: "three completions")
        done.expectedFulfillmentCount = 3
        for _ in 0..<3 {
            cache.request(url, pixelSize: 32) { image in
                images.append(image)
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 20)
        XCTAssertEqual(decodes.value, 1, "the second and third request joined the first job")
        XCTAssertEqual(images.values.count, 3)
        XCTAssertEqual(images.values.compactMap { $0 }.count, 3)
        XCTAssertTrue(images.values.allSatisfy { $0 === images.values[0] })
    }

    func testPF8_missingOrUndecodableFileCompletesNilAndCachesNothing() async throws {
        let missing = root.appendingPathComponent("missing.png")
        let text = root.appendingPathComponent("text.png")
        try Data("not an image".utf8).write(to: text)
        let decodes = Decodes()
        let cache = ThumbnailCache(maximumBytes: 1 << 20, concurrentJobs: 2) { _ in decodes.increment() }
        let none = await thumbnail(from: cache, missing, pixelSize: 32)
        XCTAssertNil(none)
        XCTAssertEqual(decodes.value, 0, "a file that cannot be read is never decoded")
        let garbage = await thumbnail(from: cache, text, pixelSize: 32)
        XCTAssertNil(garbage)
        XCTAssertEqual(decodes.value, 1, "ImageIO was asked and declined")
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.bytes, 0)
    }

    // MARK: - Eviction

    func testPF8_evictsLeastRecentlyUsedEntryWhenOverTheBound() async throws {
        let a = try writePNG("a.png", seed: 1, width: 32, height: 32)
        let b = try writePNG("b.png", seed: 2, width: 32, height: 32)
        let c = try writePNG("c.png", seed: 3, width: 32, height: 32)
        // Calibrate: what one 32 px thumbnail costs, so the bound below holds exactly two.
        let probe = try await image(from: ThumbnailCache(), a, pixelSize: 32)
        let cost = ThumbnailCache.cost(of: probe)
        XCTAssertGreaterThan(cost, 0)

        let cache = ThumbnailCache(maximumBytes: 2 * cost + cost / 2, concurrentJobs: 2)
        let imageA = try await image(from: cache, a, pixelSize: 32)
        let imageB = try await image(from: cache, b, pixelSize: 32)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.bytes, 2 * cost)

        // A is older than B but is used again, so B is the least recently used.
        XCTAssertTrue(cache.cachedImage(for: a, pixelSize: 32) === imageA)
        let imageC = try await image(from: cache, c, pixelSize: 32)
        XCTAssertEqual(cache.count, 2)
        XCTAssertLessThanOrEqual(cache.bytes, cache.maximumBytes)
        XCTAssertTrue(cache.cachedImage(for: a, pixelSize: 32) === imageA, "the recently used entry stays")
        XCTAssertNil(cache.cachedImage(for: b, pixelSize: 32), "the least recently used entry went")
        XCTAssertTrue(cache.cachedImage(for: c, pixelSize: 32) === imageC)
        _ = imageB
    }

    func testPF8_imageLargerThanTheBoundIsDeliveredButNotKept() async throws {
        let a = try writePNG("a.png", seed: 1, width: 32, height: 32)
        let probe = try await image(from: ThumbnailCache(), a, pixelSize: 32)
        let cache = ThumbnailCache(maximumBytes: ThumbnailCache.cost(of: probe) / 2, concurrentJobs: 2)
        let image = await thumbnail(from: cache, a, pixelSize: 32)
        XCTAssertNotNil(image)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.bytes, 0)
    }

    // MARK: - Invalidation

    func testPF8_changedModificationDateInvalidatesTheEntry() async throws {
        let url = try writePNG("pic.png", seed: 1)
        let decodes = Decodes()
        let cache = ThumbnailCache(maximumBytes: 1 << 20, concurrentJobs: 2) { _ in decodes.increment() }
        let first = try await image(from: cache, url, pixelSize: 32)
        let originalDate = try modificationDate(of: url)

        // New bytes, newer date: a fresh thumbnail replaces the old one, nothing piles up.
        try writePNG("pic.png", seed: 2)
        try setModificationDate(originalDate.addingTimeInterval(60), of: url)
        let second = try await image(from: cache, url, pixelSize: 32)
        XCTAssertFalse(first === second, "a changed file gets a new thumbnail")
        XCTAssertEqual(decodes.value, 2)
        XCTAssertEqual(cache.count, 1, "the stale entry was replaced, not kept beside the new one")
        XCTAssertEqual(cache.bytes, ThumbnailCache.cost(of: second))
        XCTAssertTrue(cache.cachedImage(for: url, pixelSize: 32) === second)

        // New bytes, same date: the key is the path and the date, so this is a hit.
        try Data("not an image".utf8).write(to: url)
        try setModificationDate(originalDate.addingTimeInterval(60), of: url)
        let third = try await image(from: cache, url, pixelSize: 32)
        XCTAssertTrue(third === second)
        XCTAssertEqual(decodes.value, 2, "the same date means no decode")

        // Newer date on a file that is no image: the old thumbnail must not outlive its file.
        try setModificationDate(originalDate.addingTimeInterval(120), of: url)
        let fourth = await thumbnail(from: cache, url, pixelSize: 32)
        XCTAssertNil(fourth)
        XCTAssertEqual(decodes.value, 3)
        XCTAssertNil(cache.cachedImage(for: url, pixelSize: 32), "the stale thumbnail is gone")
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.bytes, 0)
    }

    // MARK: - Threading

    func testPF8_requestReturnsAtOnceAndAtMostTwoJobsRun() async throws {
        let urls = try (1...5).map { try writePNG("pic\($0).png", seed: $0) }
        let gate = DispatchSemaphore(value: 0)
        let inFlight = Mutex((now: 0, peak: 0))
        let cache = ThumbnailCache(maximumBytes: 1 << 20, concurrentJobs: 2) { _ in
            inFlight.withLock {
                $0.now += 1
                $0.peak = max($0.peak, $0.now)
            }
            gate.wait()
            inFlight.withLock { $0.now -= 1 }
        }

        let images = Results()
        let done = expectation(description: "five completions")
        done.expectedFulfillmentCount = 5
        let started = Date()
        for url in urls {
            cache.request(url, pixelSize: 32) { image in
                XCTAssertTrue(Thread.isMainThread, "completions run on the main thread")
                images.append(image)
                done.fulfill()
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "five requests returned while every job is still held")

        // Two jobs reach the decoder and wait there; the other three queue behind them.
        await waitUntil("two jobs in flight") { inFlight.withLock { $0.now } == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(inFlight.withLock { $0.now }, 2, "a third job does not start while two run")
        XCTAssertEqual(images.values.count, 0, "nothing completed while the jobs are held")

        for _ in urls { gate.signal() }
        await fulfillment(of: [done], timeout: 20)
        XCTAssertEqual(inFlight.withLock { $0.peak }, 2, "never more than two jobs at once")
        XCTAssertEqual(images.values.compactMap { $0 }.count, 5)
        XCTAssertEqual(cache.count, 5)
    }

    func testPF8_hitCompletesOnTheMainThreadToo() async throws {
        let url = try writePNG("pic.png", seed: 1)
        let cache = ThumbnailCache()
        _ = await thumbnail(from: cache, url, pixelSize: 32)
        let done = expectation(description: "hit completion")
        cache.request(url, pixelSize: 32) { image in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(image)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 20)
    }

    // MARK: - Helpers

    /// Completions collected on the main thread.
    @MainActor
    private final class Results {
        private(set) var values: [CGImage?] = []
        func append(_ image: CGImage?) { values.append(image) }
    }

    /// One request, awaited; the completion's image, which must not be nil.
    private func image(from cache: ThumbnailCache, _ url: URL, pixelSize: Int) async throws -> CGImage {
        let result = await thumbnail(from: cache, url, pixelSize: pixelSize)
        return try XCTUnwrap(result, "expected a thumbnail of \(url.lastPathComponent)")
    }

    /// One request, awaited; the completion's image.
    private func thumbnail(from cache: ThumbnailCache, _ url: URL, pixelSize: Int) async -> CGImage? {
        let results = Results()
        let done = expectation(description: "thumbnail of \(url.lastPathComponent)")
        cache.request(url, pixelSize: pixelSize) { image in
            XCTAssertTrue(Thread.isMainThread, "completions run on the main thread")
            results.append(image)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 20)
        return results.values.first ?? nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @discardableResult
    private func writePNG(_ name: String, seed: Int, width: Int = 64, height: Int = 64) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Self.generatedPNG(seed: seed, width: width, height: height).write(to: url)
        return url
    }

    private func modificationDate(of url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func generatedPNG(seed: Int, width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<height {
            for x in 0..<width {
                let shade = CGFloat((x * 40 + y * 60 + seed * 30) % 256) / 255
                rep.setColor(
                    NSColor(deviceRed: shade, green: 1 - shade, blue: CGFloat(seed % 2), alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
