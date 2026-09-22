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
    /// The image file's own size, in pixels and in points (E-9): what the thumbnail is fitted
    /// from whenever the editor's size changes.
    public let source: ThumbnailCache.SourceSize
    /// The thumbnail as the cache handed it over: the cache answers with this very object
    /// while the file is unchanged, so a later answer that is another object means the file
    /// changed (X-1). Replaced when the thumbnail is refitted and asked for at a new size.
    public private(set) var cgImage: CGImage
    /// The pixel size `cgImage` was asked of the cache at: the key it is cached under.
    public private(set) var pixelSize: Int

    public init(
        target: String, url: URL, source: ThumbnailCache.SourceSize, cgImage: CGImage, pixelSize: Int, size: NSSize
    ) {
        self.target = target
        self.url = url
        self.source = source
        self.cgImage = cgImage
        self.pixelSize = pixelSize
        super.init(data: nil, ofType: nil)
        image = NSImage(cgImage: cgImage, size: size)
        bounds = NSRect(origin: .zero, size: size)
    }

    /// Shows the thumbnail at `size` points, drawing the image it has until a sharper one is
    /// handed over. The layout of its character must be invalidated for the line to follow.
    func resize(to size: NSSize) {
        bounds = NSRect(origin: .zero, size: size)
        image = NSImage(cgImage: cgImage, size: size)
    }

    /// Replaces the drawn image with `cgImage`, asked of the cache at `pixelSize`, at the size
    /// already shown.
    func show(_ cgImage: CGImage, pixelSize: Int) {
        self.cgImage = cgImage
        self.pixelSize = pixelSize
        image = NSImage(cgImage: cgImage, size: bounds.size)
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
///
/// An image file that changes on disk without the note changing is heard of through
/// `imagesDidChange` (X-1): the thumbnails of it are asked for again and replaced or dropped,
/// and embeds without one are looked up again in case theirs has just arrived.
///
/// Each thumbnail is drawn aspect-locked at the largest size no bigger than the image's own
/// point size, the text's usable width and the editor's visible height, never enlarged (E-9,
/// ADR-0021); the cache is asked for it at that size times the window's scale. `refit` fits
/// them again when the editor's size or font size changes.
@MainActor
public final class EditorThumbnails {
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
    /// Every thumbnail placed and not yet gone: what `refit` resizes.
    private let live = NSHashTable<ThumbnailAttachment>.weakObjects()
    /// The box the thumbnails were last fitted to.
    private var fittedBox = NSSize.zero
    /// Thumbnails whose image is being asked for again at a new pixel size.
    private var sharpening: Set<ObjectIdentifier> = []

    init(cache: ThumbnailCache) {
        self.cache = cache
    }

    // MARK: - Sizing

    /// The size a thumbnail of an image `points` big is drawn at (E-9): the largest with the
    /// image's proportions that is no bigger than `points` itself nor `box`; never enlarged.
    /// A side of `box` that is not positive (an editor not laid out yet) bounds nothing.
    public static func displaySize(forPointSize points: CGSize, fitting box: NSSize) -> NSSize {
        guard points.width > 0, points.height > 0 else { return .zero }
        var ratio: CGFloat = 1
        if box.width > 0 { ratio = min(ratio, box.width / points.width) }
        if box.height > 0 { ratio = min(ratio, box.height / points.height) }
        return NSSize(width: points.width * ratio, height: points.height * ratio)
    }

    /// The pixel size to ask the cache for a thumbnail drawn at `size` points of an image
    /// `source` big, on a display of `scale`: the drawn size's longest side times the scale,
    /// and never more than the image's own longest side, which is the image in full.
    public static func pixelSize(forDrawnSize size: NSSize, of source: ThumbnailCache.SourceSize, scale: CGFloat)
        -> Int
    {
        let wanted = Int(ceil(max(size.width, size.height) * max(1, scale)))
        let full = Int(ceil(max(source.pixels.width, source.pixels.height)))
        return max(1, min(wanted, full))
    }

    /// The box every thumbnail fits in (E-9): the text container's usable width, margins
    /// (the text container inset) and line fragment padding excluded, by the height of the
    /// editor scroll view's visible area. A side not known yet is zero, bounding nothing.
    public var fitBox: NSSize {
        guard let textView = editor?.textView, let container = textView.textContainer else { return .zero }
        let containerWidth =
            container.widthTracksTextView
            ? textView.bounds.width - 2 * textView.textContainerInset.width : container.size.width
        let width = max(0, containerWidth - 2 * container.lineFragmentPadding)
        let height = max(0, textView.enclosingScrollView?.contentView.bounds.height ?? 0)
        return NSSize(width: width, height: height)
    }

    /// The window's scale, or Retina for a window off screen.
    private var scale: CGFloat {
        max(1, editor?.textView.window?.backingScaleFactor ?? 2)
    }

    // MARK: - Refitting

    /// Fits every thumbnail on show to the editor as it is now (E-9): each whose drawn size
    /// changes is resized at once, drawing the image it has, its line laid out again, and its
    /// image asked for again at the new pixel size, off the main thread (PF-8). Called when the
    /// editor's width or visible height changes (a window resize, a split drag) and when the
    /// font size does; a call that finds the box as it was does nothing, so a frame change
    /// that is only the text growing costs a comparison, unless `force` asks for every
    /// thumbnail to be checked (a font size change).
    public func refit(force: Bool = false) {
        let box = fitBox
        guard force || box != fittedBox else { return }
        fittedBox = box
        let changed = live.allObjects.filter {
            Self.displaySize(forPointSize: $0.source.points, fitting: box) != $0.bounds.size
        }
        guard !changed.isEmpty, let textView = editor?.textView, let storage = textView.textStorage,
            let layoutManager = textView.layoutManager
        else { return }
        let resizing = Set(changed.map(ObjectIdentifier.init))
        var resized: [ThumbnailAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let thumbnail = value as? ThumbnailAttachment, resizing.contains(ObjectIdentifier(thumbnail))
            else { return }
            thumbnail.resize(to: Self.displaySize(forPointSize: thumbnail.source.points, fitting: box))
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
            resized.append(thumbnail)
        }
        // One that is no longer in the text is forgotten rather than asked for again.
        for thumbnail in changed where !resized.contains(where: { $0 === thumbnail }) { live.remove(thumbnail) }
        for thumbnail in resized { sharpen(thumbnail) }
    }

    /// Asks the cache for `thumbnail`'s image at the pixel size its drawn size wants, unless it
    /// has that already or is being asked for; the answer replaces the drawn image, and if the
    /// size moved on while it was made, the next one is asked for. One request per thumbnail
    /// is in flight at a time, so a live resize never queues a decode per frame.
    private func sharpen(_ thumbnail: ThumbnailAttachment) {
        let key = ObjectIdentifier(thumbnail)
        guard !sharpening.contains(key) else { return }
        let wanted = Self.pixelSize(forDrawnSize: thumbnail.bounds.size, of: thumbnail.source, scale: scale)
        guard wanted != thumbnail.pixelSize else { return }
        sharpening.insert(key)
        let generation = generation
        cache.request(thumbnail.url, pixelSize: wanted) { [weak self, weak thumbnail] image in
            guard let self else { return }
            sharpening.remove(key)
            guard generation == self.generation, let thumbnail, live.contains(thumbnail), let image else { return }
            thumbnail.show(image, pixelSize: wanted)
            editor?.textView.setNeedsDisplay(editor?.textView.visibleRect ?? .zero)
            sharpen(thumbnail)
        }
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
        live.removeAllObjects()
        sharpening = []
    }

    /// The storage's characters changed in `editedRange` (in the new text) by `delta`. The
    /// range is kept, moved past any edits that follow, and reconciled on the next turn of the
    /// main run loop.
    func textDidChange(in editedRange: NSRange, changeInLength delta: Int) {
        if let dirty {
            self.dirty = Self.adjust(dirty, forEdit: editedRange, delta: delta)
        }
        scheduleReconcile(of: editedRange)
    }

    /// Adds `range`, a storage range of the text as it is now, to what the next reconciliation
    /// covers, and schedules one on the next turn of the main run loop unless one is due.
    private func scheduleReconcile(of range: NSRange) {
        dirty = dirty.map { NSUnionRange($0, range) } ?? range
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reconcileNow() }
        }
    }

    /// X-1: the image files at `paths`, root-relative to the editor's library, arrived, changed
    /// or went behind the app's back, without the note changing. Every thumbnail on show of one
    /// of them is asked for again through the cache, which notices the file's new date: an
    /// answer that is the same image means the file is as it was, any other means it changed
    /// or is gone, and the thumbnail is removed and its line reconciled, so the target is
    /// looked up afresh and gets the new image where it still resolves. The whole text is
    /// reconciled too, since an embed without a thumbnail may name a file that has just
    /// arrived (E-9). Nothing happens without a library or a text.
    public func imagesDidChange(_ paths: Set<String>) {
        guard let editor, let root = editor.library?.root, let storage = editor.textView.textStorage,
            storage.length > 0
        else { return }
        let changed = Set(paths.map { root.appendingPathComponent($0, isDirectory: false).standardizedFileURL.path })
        let text = EditorText(storage: storage)
        let generation = generation
        for run in text.displayOnlyRanges {
            for (_, thumbnail) in Self.thumbnails(in: run, of: storage)
            where changed.contains(thumbnail.url.standardizedFileURL.path) {
                cache.request(thumbnail.url, pixelSize: thumbnail.pixelSize) { [weak self] image in
                    guard let self, generation == self.generation else { return }
                    if let image, image === thumbnail.cgImage { return }
                    remove(thumbnail)
                }
            }
        }
        scheduleReconcile(of: NSRange(location: 0, length: storage.length))
    }

    /// Takes `thumbnail` off the text, wherever it sits now, and has the line it was below
    /// reconciled, so its target is looked up again.
    private func remove(_ thumbnail: ThumbnailAttachment) {
        guard let editor, let storage = editor.textView.textStorage else { return }
        let text = EditorText(storage: storage)
        for run in text.displayOnlyRanges {
            for (index, found) in Self.thumbnails(in: run, of: storage) where found === thumbnail {
                editor.removeAttachments(in: NSRange(location: index, length: 0))
                // The run began with the line break ending the embed's line; its location now
                // ends that line, so the reconciliation covers the embed.
                scheduleReconcile(of: NSRange(location: run.location, length: 0))
                return
            }
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
    /// the library finds the file off the main thread (I-2), the cache reads its size and then
    /// makes or serves the thumbnail at the pixel size the editor draws it at (PF-8, E-9), and
    /// the image is placed below every line spelling an embed of the target that still lacks
    /// one.
    private func request(_ target: String, spelled embedText: String) {
        if pending[target] != nil {
            pending[target]?.insert(embedText)
            return
        }
        guard let library = editor?.library else { return }
        pending[target] = [embedText]
        let generation = generation
        library.locateEmbed(target) { [weak self] url in
            guard let self, generation == self.generation else { return }
            guard let url, ImageStore.isImageFile(url.path) else {
                pending[target] = nil
                return
            }
            cache.requestSourceSize(url) { [weak self] source in
                guard let self, generation == self.generation else { return }
                guard let source else {
                    pending[target] = nil
                    return
                }
                let size = Self.displaySize(forPointSize: source.points, fitting: fitBox)
                let pixelSize = Self.pixelSize(forDrawnSize: size, of: source, scale: scale)
                cache.request(url, pixelSize: pixelSize) { [weak self] image in
                    guard let self, generation == self.generation else { return }
                    let embedTexts = pending.removeValue(forKey: target) ?? []
                    guard let image else { return }
                    place(image, at: pixelSize, of: url, source: source, for: target, spelled: embedTexts)
                }
            }
        }
    }

    /// Puts a thumbnail of `image` below every line that spells an embed of `target` in one of
    /// the ways in `embedTexts` and has none for it yet. The embed is found again by its text,
    /// since the text may have changed since the lookup began; a match inside code is not an
    /// embed. Lines are handled last first, so an insertion never moves an earlier line. Each
    /// is fitted to the editor as it is now; if that has changed since `image` was asked for
    /// at `pixelSize`, the image is asked for again at the size it is drawn at.
    private func place(
        _ image: CGImage, at pixelSize: Int, of url: URL, source: ThumbnailCache.SourceSize, for target: String,
        spelled embedTexts: Set<String>
    ) {
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
        let size = Self.displaySize(forPointSize: source.points, fitting: fitBox)
        for line in lines.sorted(by: >) where !hasThumbnail(for: target, belowLineContaining: line, in: text) {
            let attachment = ThumbnailAttachment(
                target: target, url: url, source: source, cgImage: image, pixelSize: pixelSize, size: size)
            editor.addAttachment(attachment, belowLineContaining: line)
            live.add(attachment)
            sharpen(attachment)
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
