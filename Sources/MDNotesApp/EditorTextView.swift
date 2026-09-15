import AppKit
import MDNotesCore

/// The editor's text view. `NSTextView` gives a Cmd-click and a Cmd-Return no meaning that
/// the editor wants, so the two are intercepted here before it sees them and handed to
/// closures the window controller installs (K-3: open the link under the pointer or the
/// caret), and a plain click on a character is offered to a third before the text view places
/// the caret with it (T-4: a click on a tag searches for it). A handler returns true when it
/// acted; otherwise the event keeps its `NSTextView` behaviour. Every other key and click is
/// the text view's own.
///
/// A paste or a drop that carries an image (I-1) is intercepted the same way: the image on the
/// pasteboard is handed to `onInsertImage` and, if it takes it, the text view never sees the
/// paste or drop. A plain text view would otherwise ignore image data and insert a dropped
/// file's path. A paste of rich text is converted to markdown before it is inserted (ED-13):
/// HTML through `HTMLToMarkdown`, failing that RTF through `RTFToMarkdown`, and with neither
/// the plain string; Paste and Match Style (Cmd-Shift-V, ED-14) inserts the plain string
/// whatever else is there. Either lands as typed text would: one undoable edit, styled,
/// autosaved. Text drops keep their `NSTextView` behaviour.
///
/// A copy, cut or drag of a selection that covers a display-only thumbnail attachment (E-9)
/// writes the text as the file holds it, through `EditorText`, so the attachment characters
/// never leave the view. Without an attachment on show the selection is written as
/// `NSTextView` writes it.
///
/// While Command is held and the pointer is over a link (ED-12) the cursor is the pointing
/// hand and the link is underlined, solid, over its whole range. The view watches its own
/// mouse moves and modifier changes: the character under the pointer is asked of `linkRange`
/// (installed by the window controller, which knows what a link is) and the underline is a
/// temporary attribute on the layout manager, drawn but never in the storage, so it is not an
/// edit, not undoable and never saved. Releasing Command, moving off the link or leaving the
/// view restores the I-beam and takes the underline away.
///
/// The view is built on TextKit 1 with an `EditorLayoutManager` (ED-8, ED-10), which is what
/// draws the rule extensions and the section bands over the text: the storage, the
/// layout manager and the text container are made here and the view keeps the storage alive,
/// as the owner of a text system built by hand must.
@MainActor
public final class EditorTextView: NSTextView {
    /// The storage the view's text system is built on. `NSTextView` retains only its container,
    /// and the container's layout manager is retained by the storage, so the view holds the
    /// storage to keep the whole system alive.
    private let ownedStorage: NSTextStorage

    /// The view's layout manager, an `EditorLayoutManager` (ED-8).
    public let editorLayoutManager: EditorLayoutManager

    /// A text view over a fresh TextKit 1 system whose layout manager is `layoutManager`: a
    /// text container of `frame`'s width and no height limit (the view is made vertically
    /// resizable by its owner), so the text wraps to the view's width and grows downwards.
    public init(frame: NSRect, layoutManager: EditorLayoutManager) {
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        ownedStorage = storage
        editorLayoutManager = layoutManager
        super.init(frame: frame, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A click with Command down and no other modifier, with the insertion index the click
    /// lands on: the index `characterIndexForInsertion(at:)` reports, so a click on the right
    /// half of a character gives the index after it, as placing the caret there would (K-3).
    public var onCommandClick: (@MainActor (Int) -> Bool)?

    /// Return or keypad Enter with Command down and no other modifier (K-3).
    public var onCommandReturn: (@MainActor () -> Bool)?

    /// A single click with no modifier down that lands on a character of the text, with that
    /// character's index (T-4). A click in the empty space after a line's end or below the last
    /// line, a double or triple click, and a click with Shift down (which extends the
    /// selection) are the text view's own and never reach this.
    public var onClick: (@MainActor (Int) -> Bool)?

    /// An image pasted into or dropped on the editor (I-1). For a drop the caret has been moved
    /// to the drop point first, so the handler inserts at the caret either way. Returns true
    /// when it took the image; false leaves the paste or drop to the text view.
    public var onInsertImage: (@MainActor (ImageSource) -> Bool)?

    /// The pasteboard `paste(_:)` and `pasteAsPlainText(_:)` read: the general one. Tests point
    /// it at a private pasteboard so they leave the user's clipboard alone.
    public var pasteboard: NSPasteboard = .general

    /// ED-12: the storage range of the link containing the character at the given storage
    /// index, or nil when the character is in no link. Installed by the window controller;
    /// with none installed nothing hovers.
    public var linkRange: (@MainActor (Int) -> NSRange?)?

    /// ED-12: the storage range of the link under the pointer while Command is held, which
    /// carries the hover underline; nil while nothing hovers.
    public private(set) var hoveredLinkRange: NSRange?

    /// ED-12: the underline a hovered link shows, as a temporary attribute: a solid single
    /// line over its whole range.
    nonisolated public static let hoverUnderline: NSUnderlineStyle = .single

    private var hoverTrackingArea: NSTrackingArea?

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if Self.hasOnlyCommand(event), let onCommandClick {
            if onCommandClick(characterIndexForInsertion(at: point)) { return }
        }
        if Self.hasNoModifiers(event), event.clickCount == 1, let onClick, let index = characterIndex(under: point),
            onClick(index)
        {
            return
        }
        super.mouseDown(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        if Self.hasOnlyCommand(event), let onCommandReturn,
            let key = event.charactersIgnoringModifiers?.unicodeScalars.first,
            key == Self.carriageReturn || key == Self.enter, onCommandReturn()
        {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Cmd-hover (ED-12)

    /// The view's own tracking area, over its visible rect, for the mouse moves and exits the
    /// hover follows; `NSTextView` asks for none of them itself.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: event.locationInWindow, modifiers: event.modifierFlags)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHover(at: nil, modifiers: event.modifierFlags)
    }

    /// Command pressed or released with the pointer where the event says it is: over a link,
    /// the hover starts or ends with the key.
    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateHover(at: event.locationInWindow, modifiers: event.modifierFlags)
    }

    /// AppKit's cursor-rect pass would put the I-beam back over a hovered link; the pointing
    /// hand stays while one hovers.
    public override func cursorUpdate(with event: NSEvent) {
        if hoveredLinkRange != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// Works out which link, if any, hovers: the one containing the character under
    /// `locationInWindow` (window coordinates; nil when the pointer has left the view) while
    /// `modifiers` is Command alone.
    private func updateHover(at locationInWindow: NSPoint?, modifiers: NSEvent.ModifierFlags) {
        var range: NSRange?
        if let locationInWindow, Self.hasOnlyCommand(modifiers), let linkRange,
            let index = characterIndex(under: convert(locationInWindow, from: nil))
        {
            range = linkRange(index)
        }
        setHoveredLink(range)
    }

    /// Moves the hover underline and the cursor to `range`, or clears both for nil. The
    /// underline is a temporary attribute of the layout manager (drawn, never in the storage);
    /// the old one is removed over what is left of its range should the text have changed.
    private func setHoveredLink(_ range: NSRange?) {
        guard range != hoveredLinkRange else { return }
        if let old = hoveredLinkRange, let storage = textStorage {
            let remaining = NSIntersectionRange(old, NSRange(location: 0, length: storage.length))
            if remaining.length > 0 {
                editorLayoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: remaining)
            }
        }
        hoveredLinkRange = range
        if let range {
            editorLayoutManager.addTemporaryAttribute(
                .underlineStyle, value: Self.hoverUnderline.rawValue, forCharacterRange: range)
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    /// The index of the character drawn under `point` (in the view's coordinates), or nil when
    /// the point is not over one: past the end of a line, below the last line, in the container
    /// inset, or before the text has been laid out in a window. `characterIndexForInsertion(at:)`
    /// names the nearest insertion index wherever the point is; the character on either side of
    /// it is the one under the point if any is, and its rect is asked for to see.
    public func characterIndex(under point: NSPoint) -> Int? {
        guard let window, let storage = textStorage, storage.length > 0 else { return nil }
        let insertion = characterIndexForInsertion(at: point)
        for candidate in [insertion - 1, insertion] where candidate >= 0 && candidate < storage.length {
            let onScreen = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            guard !onScreen.isEmpty else { continue }
            let rect = convert(window.convertFromScreen(onScreen), from: nil)
            if rect.contains(point) { return candidate }
        }
        return nil
    }

    // MARK: - Copy (E-9)

    /// What `copy:`, `cut:` and a drag write for the selection. With a display-only attachment
    /// on show (E-9) the selected ranges are written as the file's text, one string, the
    /// attachment characters left out; otherwise as `NSTextView` writes them.
    public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return super.writeSelection(to: pboard, types: types) }
        let text = EditorText(storage: storage)
        guard text.hasDisplayOnlyRuns else { return super.writeSelection(to: pboard, types: types) }
        let string = selectedRanges.map { text.string(inStorageRange: $0.rangeValue) }.joined(separator: "\n")
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(string, forType: .string)
    }

    // MARK: - Paste (ED-13, ED-14) and image paste and drop (I-1)

    /// `NSTextView` enables Paste only for the types it reads itself, which for a plain text
    /// view are text types: with an image and nothing else on the clipboard the menu item is
    /// disabled and Cmd-V, which goes through the same validation, is dead, so `paste(_:)` is
    /// never reached. Paste is enabled here whenever the pasteboard carries an image the
    /// handler could take, or HTML, RTF or a string to paste (ED-13), and the shown note is
    /// writable; Paste and Match Style (ED-14) whenever it carries an image or a string. Every
    /// other item, and either over anything else, is validated as `NSTextView` validates it.
    /// Reads no data (PF-6): validation runs on every menu open and key press.
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), acceptsImagePaste() || acceptsTextPaste(Self.richTypes) {
            return true
        }
        if item.action == #selector(NSTextView.pasteAsPlainText(_:)), acceptsImagePaste() || acceptsTextPaste([.string])
        {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Cmd-V and the Paste item. What the pasteboard carries decides the paste, in this order:
    /// an image goes to `onInsertImage` (I-1); HTML is converted to markdown, failing that RTF
    /// (ED-13), and the markdown is inserted at the selection; with neither, the plain string
    /// is. Anything else, or an image the handler declines, is pasted as `NSTextView` pastes it.
    public override func paste(_ sender: Any?) {
        if insertsImage() { return }
        if isEditable, let markdown = Self.convertedMarkdown(on: pasteboard) {
            insertText(markdown, replacementRange: selectedRange())
            return
        }
        if insertsPlainString() { return }
        super.paste(sender)
    }

    /// Cmd-Shift-V and the Paste and Match Style item (ED-14): the pasteboard's plain-text
    /// form, whatever else it carries. Image data is still an image (I-1); with no string and
    /// no image the paste is `NSTextView`'s own.
    public override func pasteAsPlainText(_ sender: Any?) {
        if insertsImage() { return }
        if insertsPlainString() { return }
        super.pasteAsPlainText(sender)
    }

    /// The markdown for the richest text form `pasteboard` carries (ED-13): HTML, else RTF.
    /// Nil when it carries neither, or when what it carries does not decode or holds no text,
    /// so the paste falls through to the plain string. Runs on the main thread, bounded by
    /// PF-9.
    private static func convertedMarkdown(on pasteboard: NSPasteboard) -> String? {
        if let html = pasteboard.string(forType: .html), let markdown = HTMLToMarkdown.markdown(fromHTML: html),
            !markdown.isEmpty
        {
            return markdown
        }
        if let rtf = pasteboard.data(forType: .rtf), let markdown = RTFToMarkdown.markdown(fromRTF: rtf),
            !markdown.isEmpty
        {
            return markdown
        }
        return nil
    }

    /// Hands an image on `pasteboard` to `onInsertImage` (I-1); true when it took it.
    private func insertsImage() -> Bool {
        guard isEditable, let onInsertImage, let image = ImagePasteboard.image(on: pasteboard) else { return false }
        return onInsertImage(image)
    }

    /// Inserts the pasteboard's string at the selection as typed text (one undoable edit,
    /// styled, autosaved); false when there is none to insert or no writable note.
    private func insertsPlainString() -> Bool {
        guard isEditable, let string = pasteboard.string(forType: .string), !string.isEmpty else { return false }
        insertText(string, replacementRange: selectedRange())
        return true
    }

    /// The text forms Paste converts or inserts, ED-13's order.
    private static let richTypes: [NSPasteboard.PasteboardType] = [.html, .rtf, .string]

    /// True when `pasteboard` offers one of `types` and there is an editable text to paste into.
    private func acceptsTextPaste(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        isEditable && pasteboard.availableType(from: types) != nil
    }

    /// `NSTextView` registers for images and files once it is editable, but under the old type
    /// names (`NSFilenamesPboardType`, `Apple PNG pasteboard type`); the modern file URL type and
    /// every image type `NSImage` reads are added so a drag from any source reaches
    /// `draggingEntered`. Called by AppKit whenever editability changes.
    public override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        guard isEditable else { return }
        var types = registeredDraggedTypes
        let images = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        for type in [NSPasteboard.PasteboardType.fileURL] + images where !types.contains(type) {
            types.append(type)
        }
        registerForDraggedTypes(types)
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        return acceptsImageDrop(sender) ? .copy : operation
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Super moves the drop caret with the pointer; the operation is ours to answer.
        let operation = super.draggingUpdated(sender)
        return acceptsImageDrop(sender) ? .copy : operation
    }

    public override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsImageDrop(sender) || super.prepareForDragOperation(sender)
    }

    /// A drop carrying an image (I-1): the caret moves to the insertion index under the
    /// pointer, as a dropped text would land there, and the image goes to `onInsertImage`.
    /// Anything else, or an image the handler declines, is dropped as `NSTextView` drops it.
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isEditable, let onInsertImage, let image = ImagePasteboard.image(on: sender.draggingPasteboard) {
            let point = convert(sender.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            if onInsertImage(image) { return true }
        }
        return super.performDragOperation(sender)
    }

    /// True when the drag carries an image and there is a handler and an editable text to
    /// drop it into.
    private func acceptsImageDrop(_ sender: any NSDraggingInfo) -> Bool {
        isEditable && onInsertImage != nil && ImagePasteboard.hasImage(on: sender.draggingPasteboard)
    }

    /// True when `pasteboard` carries an image and there is a handler and an editable text to
    /// paste it into. Reads no data (PF-6): validation runs on every menu open and key press.
    private func acceptsImagePaste() -> Bool {
        isEditable && onInsertImage != nil && ImagePasteboard.hasImage(on: pasteboard)
    }

    /// True when Command is down and Shift, Control and Option are not. The function and
    /// keypad flags a keypad key carries do not count.
    private static func hasOnlyCommand(_ event: NSEvent) -> Bool {
        hasOnlyCommand(event.modifierFlags)
    }

    private static func hasOnlyCommand(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .control, .option, .command]) == .command
    }

    /// True when none of Shift, Control, Option and Command is down.
    private static func hasNoModifiers(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
    }

    private static let carriageReturn: UnicodeScalar = "\r"
    private static let enter: UnicodeScalar = "\u{03}"
}
