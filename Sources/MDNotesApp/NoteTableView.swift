import AppKit

/// The note list's table view. `NSTableView.keyDown` handles arrows, Return and Tab itself
/// rather than through `interpretKeyEvents`, so the keys S-7 and S-8 give a meaning are
/// intercepted here before it sees them; each one is handed to a closure the window
/// controller installs, and every other key keeps its `NSTableView` behaviour.
@MainActor
public final class NoteTableView: NSTableView {
    /// Up arrow with the first row selected (S-7: return to the search field).
    public var onMoveUpFromFirstRow: (@MainActor () -> Void)?
    /// Tab or Enter with a row selected (S-8: move focus to the editor).
    public var onActivateSelectedRow: (@MainActor () -> Void)?
    /// Escape (S-7: clear the query and return to the search field).
    public var onCancel: (@MainActor () -> Void)?

    public override func keyDown(with event: NSEvent) {
        if let handler = handler(for: event) {
            handler()
        } else {
            super.keyDown(with: event)
        }
    }

    /// The closure an unmodified press of one of the flow keys maps to in the current
    /// selection state, or nil when the table's own handling should run.
    private func handler(for event: NSEvent) -> (@MainActor () -> Void)? {
        guard Self.hasNoCommandModifiers(event), let key = event.charactersIgnoringModifiers?.unicodeScalars.first
        else { return nil }
        switch key {
        case Self.upArrow:
            return selectedRow == 0 ? onMoveUpFromFirstRow : nil
        case Self.carriageReturn, Self.enter, Self.tab:
            return selectedRow >= 0 ? onActivateSelectedRow : nil
        case Self.escape:
            return onCancel
        default:
            return nil
        }
    }

    /// True unless Shift, Control, Option or Command is down. The function and keypad flags
    /// arrow and keypad keys carry do not count.
    private static func hasNoCommandModifiers(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
    }

    private static let upArrow: UnicodeScalar = "\u{F700}"  // NSUpArrowFunctionKey
    private static let carriageReturn: UnicodeScalar = "\r"
    private static let enter: UnicodeScalar = "\u{03}"
    private static let tab: UnicodeScalar = "\t"
    private static let escape: UnicodeScalar = "\u{1B}"
}
