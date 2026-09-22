import AppKit

/// The note list's table view. `NSTableView.keyDown` handles arrows, Return and Tab itself
/// rather than through `interpretKeyEvents`, so the keys S-7 and S-8 give a meaning are
/// intercepted here before it sees them; each one is handed to a closure the window
/// controller installs, and every other key keeps its `NSTableView` behaviour.
///
/// R-4: a right-click or Ctrl-click asks `contextMenuForRow` for the clicked row's menu. The
/// menu is shown through `NSTableView`'s own path, so `clickedRow` names the row and AppKit
/// draws its clicked-row outline while the selection stays as it was. Empty space, and a row
/// the closure gives no menu (a template row, TP-5), show nothing.
@MainActor
public final class NoteTableView: NSTableView {
    /// Up arrow with the first row selected (S-7: return to the search field).
    public var onMoveUpFromFirstRow: (@MainActor () -> Void)?
    /// Tab or Enter with a row selected (S-8: move focus to the editor).
    public var onActivateSelectedRow: (@MainActor () -> Void)?
    /// Escape (S-7: clear the query and return to the search field).
    public var onCancel: (@MainActor () -> Void)?
    /// R-4: the context menu for the row at the given index, or nil for none.
    public var contextMenuForRow: (@MainActor (Int) -> NSMenu?)?

    /// R-4: the clicked row's menu, installed as the table's `menu` so that `super` records
    /// `clickedRow` and returns it. Nil, recording nothing, off the rows or for a row with no
    /// menu.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let rowMenu = contextMenuForRow?(row) else { return nil }
        menu = rowMenu
        return super.menu(for: event)
    }

    /// The menu was made for one row and one click; it is not kept for the next.
    public override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        if self.menu === menu { self.menu = nil }
    }

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
