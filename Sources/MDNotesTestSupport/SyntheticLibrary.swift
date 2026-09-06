import Foundation

/// Generates a deterministic fake notes library on disk for tests and benchmarks.
/// The shape mirrors the real library: flat mostly, some nesting, inline `#tags`,
/// `[[wikilinks]]`, an `i/` folder, and a few large notes.
public enum SyntheticLibrary {
    public struct Options: Sendable {
        public var noteCount: Int
        public var seed: UInt64
        public var nestedFraction: Double
        public var largeNoteCount: Int
        public var largeNoteBytes: Int

        public init(
            noteCount: Int,
            seed: UInt64 = 42,
            nestedFraction: Double = 0.2,
            largeNoteCount: Int = 5,
            largeNoteBytes: Int = 1_000_000
        ) {
            self.noteCount = noteCount
            self.seed = seed
            self.nestedFraction = nestedFraction
            self.largeNoteCount = largeNoteCount
            self.largeNoteBytes = largeNoteBytes
        }
    }

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
            let body = makeBody(index: i, paths: paths, rng: &rng, targetBytes: isLarge ? options.largeNoteBytes : 400)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        // A non-note file and an ignored-folder file, to make sure filters are exercised.
        try "not a note".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "trashed".write(to: root.appendingPathComponent("Trash/old.md"), atomically: true, encoding: .utf8)
        return paths
    }

    private static func makeBody(index: Int, paths: [String], rng: inout SplitMix64, targetBytes: Int) -> String {
        var out = ""
        out.reserveCapacity(targetBytes + 64)
        out += "# Heading \(index)\n\n"
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
