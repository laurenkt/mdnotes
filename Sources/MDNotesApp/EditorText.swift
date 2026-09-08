import AppKit
import Foundation

/// The editor's text as the file holds it (E-9, ADR-0012). The text storage may carry
/// display-only runs, each a line of its own holding a thumbnail attachment below an image
/// embed, that are not in the file: a line break and the attachment character (U+FFFC), both
/// carrying `displayOnlyAttribute`. Every path that reads text out of the view goes through
/// this one type, so none of them sees those characters: the save (E-4) writes `string`, and
/// so does the undo bookkeeping that compares a note's text with what it was (E-7); a copy
/// writes `string(inStorageRange:)` of the selection; the styler scans `units` and maps token
/// ranges back with `storageRange(forFileRange:)` (E-2, E-3); link and tag parsing map a
/// caret or click's storage index with `fileIndex(forStorageIndex:)` (K-3, T-4).
///
/// Two coordinate systems meet here. *Storage* indices are the text view's: the selection,
/// clicks, attribute ranges. *File* indices are into `units` and `string`, the text the file
/// holds and the text `MarkdownScanner` sees. With no run present the two are identical and
/// every mapping is the identity. A storage index inside a run maps to the file index the run
/// sits at; a file index at which a run sits maps to the storage index before the run, so a
/// range ending there leaves the run out and one starting there begins with the file's next
/// character.
///
/// Runs are found by their attachment character and told from a U+FFFC the file itself holds
/// by the marker attribute, which is why a run is only ever made by
/// `EditorController.addAttachment`, which puts both in. Line-scoped readers of the storage
/// that work relative to the caret (the completion rules, K-4 and T-3) need no mapping: a run
/// is never inside a line of the file's text, because it begins with its own line break.
///
/// Building one copies the storage's units out in bulk (a fraction of a millisecond on a 1 MB
/// note, see `units(of:)`) and scans them once; nothing is cached, so build it per operation,
/// not per character.
public struct EditorText: Sendable {
    /// Marks every character the editor shows but the file does not hold. Its value is `true`.
    nonisolated public static let displayOnlyAttribute = NSAttributedString.Key("MDNotesDisplayOnly")

    /// U+FFFC, the object replacement character `NSTextAttachment` is attached to.
    nonisolated static let attachmentCharacter: UInt16 = 0xFFFC

    /// The file's text as UTF-16 units: the storage's characters with every display-only run
    /// left out. What `MarkdownScanner` scans.
    public let units: [UInt16]

    /// The display-only runs as storage ranges, ascending, non-overlapping and non-adjacent
    /// (adjacent runs are one range). Empty when the storage shows no attachment.
    public let displayOnlyRanges: [NSRange]

    /// The text of `storage` as the file holds it.
    public init(storage: NSTextStorage) {
        let all = Self.units(of: storage)
        let whole = NSRange(location: 0, length: all.count)
        var runs: [NSRange] = []
        var cursor = 0
        while let found = Self.indexOfAttachmentCharacter(in: all, from: cursor) {
            var run = NSRange(location: NSNotFound, length: 0)
            let marked = storage.attribute(Self.displayOnlyAttribute, at: found, longestEffectiveRange: &run, in: whole)
            guard marked != nil, run.location != NSNotFound, run.length > 0 else {
                cursor = found + 1
                continue
            }
            if let last = runs.last, NSMaxRange(last) >= run.location {
                runs[runs.count - 1] = NSUnionRange(last, run)
            } else {
                runs.append(run)
            }
            cursor = NSMaxRange(run)
        }
        displayOnlyRanges = runs
        units = runs.isEmpty ? all : Self.stripping(runs, from: all)
    }

    /// True when the storage shows at least one attachment.
    public var hasDisplayOnlyRuns: Bool { !displayOnlyRanges.isEmpty }

    /// The file's text.
    public var string: String { String(utf16CodeUnits: units, count: units.count) }

    /// The file's text within a range of file indices, clamped to the text.
    public func string(inFileRange range: NSRange) -> String {
        let start = min(max(range.location, 0), units.count)
        let end = min(max(start + range.length, start), units.count)
        return units[start..<end].withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(utf16CodeUnits: base, count: buffer.count)
        }
    }

    /// The file's text under a range of storage indices: what a copy of that selection carries
    /// (E-9), with any display-only run it covers left out.
    public func string(inStorageRange range: NSRange) -> String {
        string(inFileRange: fileRange(forStorageRange: range))
    }

    // MARK: - Mapping

    /// The file index of storage index `index`. An index inside a display-only run maps to
    /// the file index the run sits at.
    public func fileIndex(forStorageIndex index: Int) -> Int {
        var removed = 0
        for run in displayOnlyRanges {
            if index < run.location { break }
            if index < NSMaxRange(run) { return run.location - removed }
            removed += run.length
        }
        return index - removed
    }

    /// The storage index of file index `index`. A file index at which a display-only run sits
    /// maps to the storage index before the run.
    public func storageIndex(forFileIndex index: Int) -> Int {
        var added = 0
        for run in displayOnlyRanges {
            if index <= run.location - added { break }
            added += run.length
        }
        return index + added
    }

    /// `range`, a range of storage indices, as file indices. Display-only runs inside it are
    /// not counted; a range covering only part of a run is empty.
    public func fileRange(forStorageRange range: NSRange) -> NSRange {
        let start = fileIndex(forStorageIndex: range.location)
        let end = fileIndex(forStorageIndex: NSMaxRange(range))
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// `range`, a range of file indices, as storage indices. The result covers every
    /// display-only run that sits strictly inside `range` and none that sits at either end.
    public func storageRange(forFileRange range: NSRange) -> NSRange {
        let start = storageIndex(forFileIndex: range.location)
        let end = storageIndex(forFileIndex: NSMaxRange(range))
        return NSRange(location: start, length: max(end - start, 0))
    }

    // MARK: - Units

    /// The storage's text as UTF-16 units, copied out in one call. A `String` bridged from
    /// the storage iterates its units one message at a time, which on a 1 MB note costs more
    /// than the whole PF-3 budget; the bulk copy is a fraction of a millisecond.
    static func units(of storage: NSTextStorage) -> [UInt16] {
        let length = storage.length
        let backing = storage.mutableString
        return [UInt16](unsafeUninitializedCapacity: length) { buffer, initialized in
            if let base = buffer.baseAddress, length > 0 {
                backing.getCharacters(base, range: NSRange(location: 0, length: length))
            }
            initialized = length
        }
    }

    /// The first attachment character at or after `start`, or nil. A plain loop over the
    /// buffer: on a 1 MB note without attachments this is the whole cost of building the text
    /// beyond the copy, and stays well inside PF-3.
    private static func indexOfAttachmentCharacter(in units: [UInt16], from start: Int) -> Int? {
        units.withUnsafeBufferPointer { buffer in
            var index = start
            while index < buffer.count {
                if buffer[index] == attachmentCharacter { return index }
                index += 1
            }
            return nil
        }
    }

    /// `units` without the characters in `runs`, which are ascending and disjoint.
    private static func stripping(_ runs: [NSRange], from units: [UInt16]) -> [UInt16] {
        let removed = runs.reduce(0) { $0 + $1.length }
        var stripped: [UInt16] = []
        stripped.reserveCapacity(units.count - removed)
        var cursor = 0
        for run in runs {
            stripped.append(contentsOf: units[cursor..<run.location])
            cursor = NSMaxRange(run)
        }
        stripped.append(contentsOf: units[cursor...])
        return stripped
    }
}
