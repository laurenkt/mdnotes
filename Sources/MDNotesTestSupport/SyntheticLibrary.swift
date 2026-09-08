import Foundation

/// Generates a deterministic fake notes library on disk for tests and benchmarks.
/// The shape mirrors the real library: flat mostly, some nesting, inline `#tags`,
/// `[[wikilinks]]`, an `i/` folder of images that a share of the notes embed (S-11, PF-8),
/// and a few large notes.
public enum SyntheticLibrary {
    public struct Options: Sendable {
        public var noteCount: Int
        public var seed: UInt64
        public var nestedFraction: Double
        public var largeNoteCount: Int
        public var largeNoteBytes: Int
        /// Share of notes whose body embeds a generated PNG of its own under `i/` (PF-8: the
        /// list and editor gates run with 10 % of notes embedding an image).
        public var imageFraction: Double

        public init(
            noteCount: Int,
            seed: UInt64 = 42,
            nestedFraction: Double = 0.2,
            largeNoteCount: Int = 5,
            largeNoteBytes: Int = 1_000_000,
            imageFraction: Double = 0.1
        ) {
            self.noteCount = noteCount
            self.seed = seed
            self.nestedFraction = nestedFraction
            self.largeNoteCount = largeNoteCount
            self.largeNoteBytes = largeNoteBytes
            self.imageFraction = imageFraction
        }
    }

    /// Pixel size of every generated image: wider than tall, so a square thumbnail has to crop.
    public static let imageWidth = 64
    public static let imageHeight = 40

    private static let words: [String] = [
        "kubernetes", "operator", "linux", "golang", "flashcard", "guggenheim", "kupka", "latency",
        "deploy", "cluster", "note", "meeting", "idea", "recipe", "travel", "london", "paris",
        "deptford", "foundry", "bishopsgate", "airfoil", "uat", "glossary", "microsoft", "apple",
        "osi", "network", "packet", "socket", "thread", "actor", "swift", "appkit", "markdown",
    ]

    /// Creates the library at `root` (which must not exist) and returns the list of relative paths.
    @discardableResult
    public static func generate(at root: URL, options: Options) throws -> [String] {
        var rng = SplitMix64(seed: options.seed)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("i"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Trash"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)

        var paths: [String] = []
        paths.reserveCapacity(options.noteCount)
        for i in 0..<options.noteCount {
            let nested = rng.nextDouble() < options.nestedFraction
            let title = "\(words[Int(rng.next() % UInt64(words.count))]) \(i)"
            let rel = nested ? "daily/\(2020 + i % 7)/\(title).md" : "\(title).md"
            paths.append(rel)
        }

        for (i, rel) in paths.enumerated() {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let isLarge = i < options.largeNoteCount
            var image: String? = nil
            if rng.nextDouble() < options.imageFraction {
                let name = imageName(forNoteAt: i)
                try pngData(seed: i, width: imageWidth, height: imageHeight)
                    .write(to: root.appendingPathComponent("i/\(name)"))
                image = name
            }
            let body = makeBody(
                index: i, paths: paths, rng: &rng, targetBytes: isLarge ? options.largeNoteBytes : 400, image: image)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        // A non-note file and an ignored-folder file, to make sure filters are exercised.
        try "not a note".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "trashed".write(to: root.appendingPathComponent("Trash/old.md"), atomically: true, encoding: .utf8)
        return paths
    }

    /// The file under `i/` the note at `index` embeds, when it embeds one.
    public static func imageName(forNoteAt index: Int) -> String {
        "img-\(index).png"
    }

    private static func makeBody(
        index: Int, paths: [String], rng: inout SplitMix64, targetBytes: Int, image: String?
    ) -> String {
        var out = ""
        out.reserveCapacity(targetBytes + 64)
        out += "# Heading \(index)\n\n"
        if let image { out += "![[\(image)]]\n\n" }
        while out.utf8.count < targetBytes {
            let w = words[Int(rng.next() % UInt64(words.count))]
            switch rng.next() % 20 {
            case 0:
                let target = paths[Int(rng.next() % UInt64(paths.count))]
                out += "[[\(NoteTitle.fromRelativePath(target))]] "
            case 1:
                out += "#\(w) "
            case 2:
                out += "\n\n"
            default:
                out += w + " "
            }
        }
        return out
    }
}

// MARK: - Generated PNGs

extension SyntheticLibrary {
    /// A valid 8-bit RGB PNG of `width` by `height` pixels whose colours depend on `seed`: a
    /// gradient with a diagonal band, so two images are told apart and a thumbnail of one is
    /// recognisable in a snapshot. Written by hand with stored (uncompressed) deflate blocks,
    /// so it needs nothing but Foundation and is byte-for-byte deterministic.
    public static func pngData(seed: Int, width: Int, height: Int) -> Data {
        precondition(width > 0 && height > 0)
        var raw = Data(capacity: height * (1 + width * 3))
        for y in 0..<height {
            raw.append(0)  // filter: none
            for x in 0..<width {
                let onBand = abs(x * height - y * width) < 4 * height
                let shade = UInt8(truncatingIfNeeded: (x * 255 / max(1, width - 1) + seed * 37))
                let cross = UInt8(truncatingIfNeeded: (y * 255 / max(1, height - 1) + seed * 91))
                if onBand {
                    raw.append(contentsOf: [255, 255, 255])
                } else {
                    raw.append(contentsOf: [shade, cross, UInt8(truncatingIfNeeded: seed * 53 + 60)])
                }
            }
        }
        var header = Data()
        header.append(bigEndian: UInt32(width))
        header.append(bigEndian: UInt32(height))
        header.append(contentsOf: [8, 2, 0, 0, 0])  // 8 bits, truecolour, deflate, no filter, no interlace
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(chunk: "IHDR", header)
        png.append(chunk: "IDAT", zlibStored(raw))
        png.append(chunk: "IEND", Data())
        return png
    }

    /// A zlib stream holding `bytes` in stored blocks: no compression, always valid.
    private static func zlibStored(_ bytes: Data) -> Data {
        var out = Data([0x78, 0x01])  // deflate, 32 KB window, no preset dictionary
        var offset = 0
        repeat {
            let length = min(65535, bytes.count - offset)
            let isLast = offset + length >= bytes.count
            out.append(isLast ? 1 : 0)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8(length >> 8))
            out.append(UInt8(~length & 0xFF))
            out.append(UInt8((~length >> 8) & 0xFF))
            out.append(bytes[bytes.startIndex + offset..<bytes.startIndex + offset + length])
            offset += length
        } while offset < bytes.count
        out.append(bigEndian: adler32(bytes))
        return out
    }

    private static func adler32(_ bytes: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    fileprivate static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    fileprivate static func crc32(_ bytes: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

extension Data {
    fileprivate mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [
            UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    /// One PNG chunk: length, type, data, CRC over type and data.
    fileprivate mutating func append(chunk type: String, _ body: Data) {
        var typed = Data(type.utf8)
        typed.append(body)
        append(bigEndian: UInt32(body.count))
        append(typed)
        append(bigEndian: SyntheticLibrary.crc32(typed))
    }
}

enum NoteTitle {
    static func fromRelativePath(_ rel: String) -> String {
        let name = rel.split(separator: "/").last.map(String.init) ?? rel
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }
}

/// Tiny deterministic PRNG so synthetic libraries are reproducible across runs.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
