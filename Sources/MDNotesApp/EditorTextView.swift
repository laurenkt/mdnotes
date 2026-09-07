import AppKit

/// The editor's text view. `NSTextView` gives a Cmd-click and a Cmd-Return no meaning that
/// the editor wants, so the two are intercepted here before it sees them and handed to
/// closures the window controller installs (K-3: open the link under the pointer or the
/// caret), and a plain click on a character is offered to a third before the text view places
/// the caret with it (T-4: a click on a tag searches for it). A handler returns true when it
/// acted; otherwise the event keeps its `NSTextView` behaviour. Every other key and click is
/// the text view's own.
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
