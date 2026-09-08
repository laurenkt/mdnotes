import AppKit

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
/// file's path. Text pastes and drops keep their `NSTextView` behaviour.
///
/// A copy, cut or drag of a selection that covers a display-only thumbnail attachment (E-9)
/// writes the text as the file holds it, through `EditorText`, so the attachment characters
/// never leave the view. Without an attachment on show the selection is written as
/// `NSTextView` writes it.
@MainActor
public final class EditorTextView: NSTextView {
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

    /// The pasteboard `paste(_:)` looks for an image on: the general one. Tests point it at a
    /// private pasteboard so they leave the user's clipboard alone.
    public var pasteboard: NSPasteboard = .general

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

    // MARK: - Image paste and drop (I-1)

    /// `NSTextView` enables Paste only for the types it reads itself, which for a plain text
    /// view are text types: with an image and nothing else on the clipboard the menu item is
    /// disabled and Cmd-V, which goes through the same validation, is dead, so `paste(_:)` is
    /// never reached. Paste is enabled here whenever the pasteboard carries an image the
    /// handler could take and the shown note is writable; every other item, and Paste over
    /// anything else, is validated as `NSTextView` validates it.
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), acceptsImagePaste() { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// Cmd-V and the menu item. An image on the pasteboard goes to `onInsertImage`; anything
    /// else, or an image the handler declines, is pasted as `NSTextView` pastes it.
    public override func paste(_ sender: Any?) {
        if isEditable, let onInsertImage, let image = ImagePasteboard.image(on: pasteboard), onInsertImage(image) {
            return
        }
        super.paste(sender)
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
        event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command
    }

    /// True when none of Shift, Control, Option and Command is down.
    private static func hasNoModifiers(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
    }

    private static let carriageReturn: UnicodeScalar = "\r"
    private static let enter: UnicodeScalar = "\u{03}"
}
