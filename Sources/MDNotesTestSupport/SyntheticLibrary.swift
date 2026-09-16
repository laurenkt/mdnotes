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
        /// How many generated PNGs of its own each large note embeds besides, one per paragraph
        /// spread evenly through its body (E-9: the editor gate runs on a 1 MB note with 50).
        public var largeNoteEmbeds: Int

        public init(
            noteCount: Int,
            seed: UInt64 = 42,
            nestedFraction: Double = 0.2,
            largeNoteCount: Int = 5,
            largeNoteBytes: Int = 1_000_000,
            imageFraction: Double = 0.1,
            largeNoteEmbeds: Int = 0
        ) {
            self.noteCount = noteCount
            self.seed = seed
            self.nestedFraction = nestedFraction
            self.largeNoteCount = largeNoteCount
            self.largeNoteBytes = largeNoteBytes
            self.imageFraction = imageFraction
            self.largeNoteEmbeds = largeNoteEmbeds
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
            var embeds: [String] = []
            if isLarge {
                for k in 0..<options.largeNoteEmbeds {
                    let name = imageName(forNoteAt: i, embed: k)
                    try pngData(seed: i * 1_000 + k + 1, width: imageWidth, height: imageHeight)
                        .write(to: root.appendingPathComponent("i/\(name)"))
                    embeds.append(name)
                }
            }
            let body = makeBody(
                index: i, paths: paths, rng: &rng, targetBytes: isLarge ? options.largeNoteBytes : 400, image: image,
                embeds: embeds, rich: isLarge)
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

    /// The `embed`th file under `i/` the large note at `index` embeds through `largeNoteEmbeds`.
    public static func imageName(forNoteAt index: Int, embed: Int) -> String {
        "img-\(index)-\(embed).png"
    }

    /// The body: a heading, the note's own image if it has one, then words, tags, wikilinks
    /// and paragraph breaks until `targetBytes` is reached. `embeds` are spread through the
    /// body at even intervals, each `![[name]]` a paragraph of its own. A `rich` body (the
    /// large notes', PF-3) carries every other ED-1 construct too: every
    /// `richConstructSpacing`th paragraph break is followed by the next block of
    /// `richConstructs`, so headings of every level, emphasis, links, images, lists, quotes,
    /// tables, code and thematic breaks (after the blank line ED-8 asks for, so the rules band
    /// the note per ED-10) recur evenly through the text. The blocks' words come from an RNG of
    /// their own, seeded by the note's index, so the notes after a rich one read the shared
    /// RNG exactly as they did before the blocks existed and their bodies stay as they were.
    private static func makeBody(
        index: Int, paths: [String], rng: inout SplitMix64, targetBytes: Int, image: String?, embeds: [String],
        rich: Bool = false
    ) -> String {
        var out = ""
        out.reserveCapacity(targetBytes + 64)
        out += "# Heading \(index)\n\n"
        if let image { out += "![[\(image)]]\n\n" }
        var nextEmbed = 0
        let spacing = embeds.isEmpty ? Int.max : max(1, targetBytes / (embeds.count + 1))
        var richRNG = SplitMix64(seed: UInt64(index) &+ 1)
        var paragraphs = 0
        var constructs = 0
        while out.utf8.count < targetBytes {
            if nextEmbed < embeds.count, out.utf8.count >= spacing * (nextEmbed + 1) {
                out += "\n\n![[\(embeds[nextEmbed])]]\n\n"
                nextEmbed += 1
                continue
            }
            let w = words[Int(rng.next() % UInt64(words.count))]
            switch rng.next() % 20 {
            case 0:
                let target = paths[Int(rng.next() % UInt64(paths.count))]
                out += "[[\(NoteTitle.fromRelativePath(target))]] "
            case 1:
                out += "#\(w) "
            case 2:
                out += "\n\n"
                paragraphs += 1
                if rich, paragraphs % richConstructSpacing == 0 {
                    out += richConstruct(constructs, rng: &richRNG, paths: paths)
                    out += "\n\n"
                    constructs += 1
                }
            default:
                out += w + " "
            }
        }
        // A body that filled up before every embed had its turn gets the rest at the end.
        for name in embeds[nextEmbed...] { out += "\n\n![[\(name)]]\n\n" }
        return out
    }

    /// Every `richConstructSpacing`th paragraph break of a rich body is followed by a block.
    public static let richConstructSpacing = 4

    /// A word from `rng`.
    private static func word(_ rng: inout SplitMix64) -> String {
        words[Int(rng.next() % UInt64(words.count))]
    }

    /// `count` words from `rng`, space-separated.
    private static func phrase(_ rng: inout SplitMix64, _ count: Int) -> String {
        (0..<count).map { _ in word(&rng) }.joined(separator: " ")
    }

    /// How many blocks `richConstruct` cycles through.
    static let richConstructCount = 22

    /// The `k`th (modulo `richConstructCount`) block of a rich body; together the blocks are
    /// every construct of ED-1 (wikilinks, embeds and tags are the plain text's own). None
    /// starts or ends with a blank line, the caller adds those, so a thematic break follows a
    /// blank line (ED-8) and is never a setext underline, while a setext underline sits
    /// directly under its text (ED-9).
    private static func richConstruct(_ k: Int, rng: inout SplitMix64, paths: [String]) -> String {
        switch k % richConstructCount {
        case 0: return "## \(phrase(&rng, 3))"
        case 1: return "---"
        case 2: return "### \(phrase(&rng, 2)) `\(word(&rng))`"
        case 3: return "**\(phrase(&rng, 2))** and __\(word(&rng))__ then *\(word(&rng))* and _\(word(&rng))_"
        case 4: return "- \(phrase(&rng, 3))\n  - \(phrase(&rng, 2))\n    - \(word(&rng))\n- \(phrase(&rng, 2))"
        case 5: return "#### \(phrase(&rng, 2))"
        case 6: return "[\(phrase(&rng, 2))](https://example.com/\(word(&rng))) and <https://example.org/\(word(&rng))>"
        case 7: return "> \(phrase(&rng, 5))\n> > \(phrase(&rng, 4))\n> \(phrase(&rng, 3))"
        case 8: return "* * *"
        case 9: return "##### \(phrase(&rng, 2))"
        case 10:
            return
                "1. \(phrase(&rng, 3))\n2. \(phrase(&rng, 2))\n  1. \(word(&rng))\n  2. \(word(&rng))\n3. \(word(&rng))"
        case 11: return "~~\(phrase(&rng, 2))~~ and **\(word(&rng)) *\(word(&rng))* \(word(&rng))**"
        case 12:
            return "| \(word(&rng)) | \(word(&rng)) | \(word(&rng)) |\n|---|:---:|---:|\n"
                + "| \(word(&rng)) | \(word(&rng)) | \(word(&rng)) |\n| \(word(&rng)) | \(word(&rng)) | \(word(&rng)) |"
        case 13: return "###### \(phrase(&rng, 2))"
        case 14: return "```swift\nlet \(word(&rng)) = \(word(&rng))(\(word(&rng)))\n\(word(&rng)).\(word(&rng))()\n```"
        case 15: return "___"
        case 16: return "\(phrase(&rng, 3))\n==="
        case 17: return "- [ ] \(phrase(&rng, 3))\n- [x] \(phrase(&rng, 2))\n  - [ ] \(word(&rng))"
        case 18:
            return "![\(phrase(&rng, 2))](i/\(word(&rng)).png) beside https://example.com/\(word(&rng))/\(word(&rng))"
        case 19: return "\(phrase(&rng, 2))\n---"
        case 20: return "~~~\n\(phrase(&rng, 4))\n~~~"
        default:
            let target = paths[Int(rng.next() % UInt64(paths.count))]
            return "+ \(word(&rng)) `\(word(&rng))` [[\(NoteTitle.fromRelativePath(target))]]"
        }
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
