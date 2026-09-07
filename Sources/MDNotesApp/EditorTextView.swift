import AppKit

/// The editor's text view. `NSTextView` gives a Cmd-click and a Cmd-Return no meaning that
/// the editor wants, so the two are intercepted here before it sees them and handed to
/// closures the window controller installs (K-3: open the link under the pointer or the
/// caret). A handler returns true when it acted; otherwise the event keeps its `NSTextView`
/// behaviour. Every other key and click is the text view's own.
@MainActor
public final class EditorTextView: NSTextView {
    /// A click with Command down and no other modifier, with the insertion index the click
    /// lands on: the index `characterIndexForInsertion(at:)` reports, so a click on the right
    /// half of a character gives the index after it, as placing the caret there would (K-3).
    public var onCommandClick: (@MainActor (Int) -> Bool)?

    /// Return or keypad Enter with Command down and no other modifier (K-3).
    public var onCommandReturn: (@MainActor () -> Bool)?

    public override func mouseDown(with event: NSEvent) {
        if Self.hasOnlyCommand(event), let onCommandClick {
            let point = convert(event.locationInWindow, from: nil)
            if onCommandClick(characterIndexForInsertion(at: point)) { return }
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

    /// True when Command is down and Shift, Control and Option are not. The function and
    /// keypad flags a keypad key carries do not count.
    private static func hasOnlyCommand(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command
    }

    private static let carriageReturn: UnicodeScalar = "\r"
    private static let enter: UnicodeScalar = "\u{03}"
}
