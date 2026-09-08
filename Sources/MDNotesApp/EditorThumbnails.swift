import AppKit
import Foundation
import MDNotesCore

/// The thumbnail below an image embed (E-9): an attachment that remembers which embed target
/// it was made for and which file it shows, so the reconciliation can tell whether it still
/// belongs below the line it is on, and a click knows what to open. Only `EditorThumbnails`
/// makes these; a display-only attachment of any other class is left where it is.
public final class ThumbnailAttachment: NSTextAttachment {
    /// The embed's target text, as `![[target]]` spells it, trimmed.
    public let target: String
    /// The image file the thumbnail is of.
    public let url: URL

    public init(target: String, url: URL, image: NSImage, size: NSSize) {
        self.target = target
        self.url = url
        super.init(data: nil, ofType: nil)
        self.image = image
        bounds = NSRect(origin: .zero, size: size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Keeps the editor's inline thumbnails (E-9, ADR-0012) in step with its text: every image
/// embed whose target resolves to an image file gets a `ThumbnailAttachment` on the line below
/// it, through `EditorController.addAttachment`, and loses it through `removeAttachments` once
/// the embed's text no longer names that target.
///
/// The work is a reconciliation of the paragraphs an edit touched, run once the edit is over.
/// The storage delegate reports every character edit (typing, paste, undo, a load); the ranges
/// are collected and reconciled on the next turn of the main run loop, never inside the
/// storage's own processing, where characters must not be changed. A keystroke in a paragraph
/// that holds no embed, attachment or fence is told apart on the storage's string alone and
/// costs nothing more (PF-3); otherwise the paragraphs are scanned as the styler scans them
/// (E-3), so an embed inside a code span or fenced block is no embed. For each embed line the
/// thumbnails below it are compared with the embeds on it by target: a thumbnail whose target
/// is no longer there goes, and a target without one is looked up.
///
/// A lookup is asynchronous: the library finds the file the target names off the main thread
/// (I-2, PF-6), and `cache` decodes or serves the thumbnail (PF-8); nothing is reserved until
/// the image is in hand, so typing is never blocked on it (E-9). When the image arrives the
/// text may have moved on, so the embed is found again by its text, in every place the text
/// now has it, and a thumbnail is placed below each such line that still lacks one. A lookup
/// already in flight for a target is joined, and a note switch drops every outstanding one.
@MainActor
public final class EditorThumbnails {
    /// E-9: the most a thumbnail may measure, in points.
    public static let maximumSize = NSSize(width: 240, height: 160)

    /// PF-8: where thumbnails come from. Shared with the list's rows (S-11).
    public let cache: ThumbnailCache

    /// The editor whose attachments these are; set by the controller once it exists.
    weak var editor: EditorController?

    /// Targets whose lookup is in flight, each with the embed texts that named it, so the
    /// image can be placed below every line spelling the embed once it arrives.
    private var pending: [String: Set<String>] = [:]
    /// Bumped by `reset()`; a lookup result tagged with an older value is dropped.
    private var generation = 0
    /// The storage range the edits since the last reconciliation touched, or nil.
    private var dirty: NSRange?
    private var isScheduled = false

    init(cache: ThumbnailCache) {
        self.cache = cache
    }

    // MARK: - Sizing

    /// The point size a thumbnail of `pixels` is shown at on a display of `scale` (E-9): its
    /// natural size at that scale, shrunk to fit `maximumSize` with its proportions kept, and
    /// never enlarged.
    public static func displaySize(forPixelSize pixels: CGSize, scale: CGFloat) -> NSSize {
        let scale = max(1, scale)
        let natural = NSSize(width: pixels.width / scale, height: pixels.height / scale)
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let ratio = min(1, maximumSize.width / natural.width, maximumSize.height / natural.height)
        return NSSize(width: natural.width * ratio, height: natural.height * ratio)
    }

    /// The window's scale, or Retina for a window off screen.
    private var scale: CGFloat {
        max(1, editor?.textView.window?.backingScaleFactor ?? 2)
    }

    /// Pixels on the thumbnail's longest side: the widest it can be shown at the window's scale.
    private var pixelSize: Int {
        Int(ceil(Self.maximumSize.width * scale))
    }

    // MARK: - Lookup by character

    /// The thumbnail whose attachment character is at storage index `index`, or nil when the
    /// character is not one (E-9: a click on it opens the image).
    public func attachment(atCharacter index: Int) -> ThumbnailAttachment? {
        guard let storage = editor?.textView.textStorage, index >= 0, index < storage.length else { return nil }
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        guard attributes[EditorText.displayOnlyAttribute] != nil else { return nil }
        return attributes[.attachment] as? ThumbnailAttachment
    }

    // MARK: - Edits

    /// The text is about to be replaced: whatever was being looked up is for a text that is
    /// going away.
    func reset() {
        generation += 1
        pending = [:]
        dirty = nil
    }

    /// The storage's characters changed in `editedRange` (in the new text) by `delta`. The
    /// range is kept, moved past any edits that follow, and reconciled on the next turn of the
    /// main run loop.
    func textDidChange(in editedRange: NSRange, changeInLength delta: Int) {
        if let dirty {
            self.dirty = NSUnionRange(Self.adjust(dirty, forEdit: editedRange, delta: delta), editedRange)
        } else {
            dirty = editedRange
        }
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reconcileNow() }
        }
    }

    /// Reconciles the edits reported since the last time, now rather than on the next run loop
    /// turn. Nothing happens when none is outstanding.
    public func reconcileNow() {
        isScheduled = false
        guard let range = dirty else { return }
        dirty = nil
        reconcile(range)
    }

    /// `range`, a storage range from before an edit at `edit` changed the length by `delta`,
    /// moved to cover the same text after it. A start or end inside the replaced text lands at
    /// the replacement's edge.
    static func adjust(_ range: NSRange, forEdit edit: NSRange, delta: Int) -> NSRange {
        let end = NSMaxRange(range)
        let start = range.location <= edit.location ? range.location : max(edit.location, range.location + delta)
        let newEnd = end <= edit.location ? end : max(NSMaxRange(edit), end + delta)
        return NSRange(location: start, length: max(newEnd - start, 0))
    }

    // MARK: - Reconciliation

    /// Brings the thumbnails in the paragraphs around `range`, a storage range, in step with
    /// the embeds there.
    private func reconcile(_ range: NSRange) {
        guard let editor, let storage = editor.textView.textStorage, storage.length > 0 else { return }
        let backing = storage.mutableString
        let clamped = Self.clamp(range, to: storage.length)
        guard Self.mayAffectThumbnails(backing, around: clamped) else { return }

        let text = EditorText(storage: storage)
        let paragraphs = MarkdownScanner.paragraphRange(
            in: text.units, editedRange: text.fileRange(forStorageRange: clamped))
        let storageParagraphs = text.storageRange(forFileRange: paragraphs)

        // The embeds on each line of the paragraphs, by the storage index the line starts at:
        // target to the embed's text.
        var desired: [Int: [String: String]] = [:]
        for token in MarkdownScanner.scan(text.units, in: paragraphs) {
            guard case .wikilink(let targetRange, _, true) = token.kind else { continue }
            let line = Self.lineStart(of: text.storageIndex(forFileIndex: token.range.location), in: backing)
            desired[line, default: [:]][text.string(inFileRange: targetRange)] = text.string(inFileRange: token.range)
        }
        // The thumbnails below each line: a run begins with the line break that ends the line.
        var attached: [Int: [(index: Int, target: String)]] = [:]
        for run in text.displayOnlyRanges
        where run.location >= storageParagraphs.location && run.location <= NSMaxRange(storageParagraphs) {
            let line = Self.lineStart(of: run.location, in: backing)
            for (index, thumbnail) in Self.thumbnails(in: run, of: storage) {
                attached[line, default: []].append((index, thumbnail.target))
            }
        }

        var stale: [Int] = []
        for (line, thumbnails) in attached {
            let wanted = desired[line] ?? [:]
            stale += thumbnails.filter { wanted[$0.target] == nil }.map(\.index)
        }
        // Later ones first, so a removal never moves an earlier one.
        for index in stale.sorted(by: >) {
            editor.removeAttachments(in: NSRange(location: index, length: 0))
        }
        for (line, embeds) in desired {
            let shown = Set((attached[line] ?? []).map(\.target))
            for (target, embedText) in embeds where !shown.contains(target) {
                request(target, spelled: embedText)
            }
        }
    }

    /// Whether the blank-line paragraph of `backing` around `range` holds anything a thumbnail
    /// depends on: an embed opener, an attachment character, or a fence line that could put an
    /// embed below it into code or take it out (E-3). Answered on the storage's string alone,
    /// so a keystroke in ordinary prose costs no more than this.
    static func mayAffectThumbnails(_ backing: NSString, around range: NSRange) -> Bool {
        let length = backing.length
        let before = backing.range(
            of: "\n\n", options: .backwards, range: NSRange(location: 0, length: min(range.location, length)))
        let start = before.location == NSNotFound ? 0 : NSMaxRange(before)
        let from = min(NSMaxRange(range), length)
        let after = backing.range(of: "\n\n", options: [], range: NSRange(location: from, length: length - from))
        let end = after.location == NSNotFound ? length : after.location
        let paragraph = NSRange(location: start, length: max(end - start, 0))
        return ["![[", "\u{FFFC}", "```", "~~~"].contains {
            backing.range(of: $0, options: [], range: paragraph).location != NSNotFound
        }
    }

    // MARK: - Lookup

    /// Looks the target up, unless a lookup for it is already in flight, which this joins:
    /// the library finds the file off the main thread (I-2), the cache makes or serves the
    /// thumbnail (PF-8), and the image is placed below every line spelling an embed of the
    /// target that still lacks one.
    private func request(_ target: String, spelled embedText: String) {
        if pending[target] != nil {
            pending[target]?.insert(embedText)
            return
        }
        guard let library = editor?.library else { return }
        pending[target] = [embedText]
        let generation = generation
        let pixelSize = pixelSize
        library.locateEmbed(target) { [weak self] url in
            guard let self, generation == self.generation else { return }
            guard let url, ImageStore.isImageFile(url.path) else {
                pending[target] = nil
                return
            }
            cache.request(url, pixelSize: pixelSize) { [weak self] image in
                guard let self, generation == self.generation else { return }
                let embedTexts = pending.removeValue(forKey: target) ?? []
                guard let image else { return }
                place(image, of: url, for: target, spelled: embedTexts)
            }
        }
    }

    /// Puts a thumbnail of `image` below every line that spells an embed of `target` in one of
    /// the ways in `embedTexts` and has none for it yet. The embed is found again by its text,
    /// since the text may have changed since the lookup began; a match inside code is not an
    /// embed. Lines are handled last first, so an insertion never moves an earlier line.
    private func place(_ image: CGImage, of url: URL, for target: String, spelled embedTexts: Set<String>) {
        guard let editor, let storage = editor.textView.textStorage else { return }
        let text = EditorText(storage: storage)
        let backing = storage.mutableString
        var lines: Set<Int> = []
        for embedText in embedTexts {
            let pattern = Array(embedText.utf16)
            for location in Self.occurrences(of: pattern, in: text.units)
            where Self.isEmbed(of: target, at: location, in: text) {
                lines.insert(Self.lineStart(of: text.storageIndex(forFileIndex: location), in: backing))
            }
        }
        let size = Self.displaySize(forPixelSize: CGSize(width: image.width, height: image.height), scale: scale)
        for line in lines.sorted(by: >) where !hasThumbnail(for: target, belowLineContaining: line, in: text) {
            let attachment = ThumbnailAttachment(
                target: target, url: url, image: NSImage(cgImage: image, size: size), size: size)
            editor.addAttachment(attachment, belowLineContaining: line)
        }
    }

    /// Whether a thumbnail for `target` already sits below the line containing storage index
    /// `index`, among the runs that follow the line as `addAttachment` chains them.
    private func hasThumbnail(for target: String, belowLineContaining index: Int, in text: EditorText) -> Bool {
        guard let storage = editor?.textView.textStorage else { return false }
        var contentsEnd = 0
        storage.mutableString.getLineStart(
            nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
        var at = contentsEnd
        while let run = text.displayOnlyRanges.first(where: { $0.location == at }) {
            if Self.thumbnails(in: run, of: storage).contains(where: { $0.thumbnail.target == target }) { return true }
            at = NSMaxRange(run)
        }
        return false
    }

    /// Whether the token at file index `location` of `text` is an embed of `target`, scanning
    /// the paragraphs around it as the styler does, so a spelling inside code is not one.
    private static func isEmbed(of target: String, at location: Int, in text: EditorText) -> Bool {
        let paragraphs = MarkdownScanner.paragraphRange(
            in: text.units, editedRange: NSRange(location: location, length: 0))
        return MarkdownScanner.scan(text.units, in: paragraphs).contains { token in
            guard case .wikilink(let targetRange, _, true) = token.kind, token.range.location == location else {
                return false
            }
            return text.string(inFileRange: targetRange) == target
        }
    }

    /// The thumbnails in `run`, a display-only run of `storage`, with their character indices.
    private static func thumbnails(in run: NSRange, of storage: NSTextStorage) -> [(
        index: Int, thumbnail: ThumbnailAttachment
    )] {
        let backing = storage.mutableString
        var found: [(Int, ThumbnailAttachment)] = []
        for index in run.location..<NSMaxRange(run) where backing.character(at: index) == EditorText.attachmentCharacter
        {
            if let thumbnail = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ThumbnailAttachment {
                found.append((index, thumbnail))
            }
        }
        return found
    }

    /// The storage index the line containing `index` starts at.
    private static func lineStart(of index: Int, in backing: NSMutableString) -> Int {
        var start = 0
        backing.getLineStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: index, length: 0))
        return start
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    /// Every index at which `pattern` occurs in `units`. A plain search: on a 1 MB note it is
    /// a fraction of a millisecond, and runs once per thumbnail that arrives.
    static func occurrences(of pattern: [UInt16], in units: [UInt16]) -> [Int] {
        guard let first = pattern.first, pattern.count <= units.count else { return [] }
        var found: [Int] = []
        units.withUnsafeBufferPointer { haystack in
            pattern.withUnsafeBufferPointer { needle in
                var index = 0
                let last = haystack.count - needle.count
                while index <= last {
                    if haystack[index] == first {
                        var k = 1
                        while k < needle.count, haystack[index + k] == needle[k] { k += 1 }
                        if k == needle.count { found.append(index) }
                    }
                    index += 1
                }
            }
        }
        return found
    }
}
