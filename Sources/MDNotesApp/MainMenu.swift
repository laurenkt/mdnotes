import AppKit

/// The menu bar, built in code (P-2) and installed by the app delegate at launch. Every item
/// sends its action down the responder chain with no target of its own, so an item is enabled
/// exactly when something in the chain of the key window answers to it: the main window's
/// controller for the note and view items, the delegate for Preferences, the application
/// for hiding and quitting, and whatever has focus for the Edit menu.
///
/// The window handles Cmd-L, Cmd-R, Cmd-Delete, Cmd-Shift-B and Cmd-, itself before the menu
/// is asked (`MainView.performKeyEquivalent`); the items here show those shortcuts and take
/// them when the window declines, as a disabled item lets a key go on to the focused view.
/// There is no File menu and no Save item: the search field creates notes (S-1) and autosave
/// writes them (E-4).
@MainActor
public enum MainMenu {
    /// The application's name as the menu titles use it.
    public static let appName = "MDNotes"

    public static let appMenuTitle = appName
    public static let editMenuTitle = "Edit"
    public static let noteMenuTitle = "Note"
    public static let viewMenuTitle = "View"
    public static let windowMenuTitle = "Window"

    public static let searchItemTitle = "Search"
    public static let renameItemTitle = "Rename Note"
    public static let deleteItemTitle = "Delete Note"
    /// The backlinks item's title while the strip is expanded; `validateMenuItem` swaps in
    /// `showBacklinksItemTitle` while it is collapsed (K-6).
    public static let hideBacklinksItemTitle = "Hide Backlinks"
    public static let showBacklinksItemTitle = "Show Backlinks"
    /// E-8: the View menu's font size items, Cmd-plus, Cmd-minus and Cmd-0.
    public static let biggerItemTitle = "Bigger"
    public static let smallerItemTitle = "Smaller"
    public static let actualSizeItemTitle = "Actual Size"

    /// The Delete key as a menu item spells it (`NSBackspaceCharacter`), shown as ⌫.
    public static let deleteKeyEquivalent = "\u{8}"

    /// Builds the whole menu bar: the application menu, Edit, Note, View and Window. The
    /// Window menu is returned separately so the caller can hand it to the application as its
    /// windows menu.
    public static func make() -> (mainMenu: NSMenu, windowMenu: NSMenu) {
        let main = NSMenu(title: "Main")
        let window = makeWindowMenu()
        for menu in [makeAppMenu(), makeEditMenu(), makeNoteMenu(), makeViewMenu(), window] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return (main, window)
    }

    private static func makeAppMenu() -> NSMenu {
        let menu = NSMenu(title: appMenuTitle)
        menu.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        // PR-1: Cmd-, reaches the delegate's `showPreferences(_:)`.
        menu.addItem(item("Settings\u{2026}", #selector(AppDelegate.showPreferences(_:)), ","))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: editMenuTitle)
        // E-7: undo and redo reach the text view's undo manager through the responder chain.
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func makeNoteMenu() -> NSMenu {
        let menu = NSMenu(title: noteMenuTitle)
        // S-7: Cmd-L focuses the search field from anywhere.
        menu.addItem(item(searchItemTitle, #selector(MainWindowController.focusSearchField(_:)), "l"))
        menu.addItem(.separator())
        // R-1: Cmd-R edits the selected note's title; D-1: Cmd-Delete moves it to the Trash.
        menu.addItem(item(renameItemTitle, #selector(MainWindowController.renameNote(_:)), "r"))
        menu.addItem(item(deleteItemTitle, #selector(MainWindowController.deleteNote(_:)), deleteKeyEquivalent))
        return menu
    }

    private static func makeViewMenu() -> NSMenu {
        let menu = NSMenu(title: viewMenuTitle)
        // E-8: the editor's font size. AppKit lets Cmd-= stand in for Cmd-plus, as it does
        // for every app that shows ⌘+.
        menu.addItem(item(biggerItemTitle, #selector(MainWindowController.makeTextBigger(_:)), "+"))
        menu.addItem(item(smallerItemTitle, #selector(MainWindowController.makeTextSmaller(_:)), "-"))
        menu.addItem(item(actualSizeItemTitle, #selector(MainWindowController.makeTextActualSize(_:)), "0"))
        menu.addItem(.separator())
        // K-6: Cmd-Shift-B collapses or expands the backlinks strip.
        menu.addItem(
            item(
                hideBacklinksItemTitle, #selector(MainWindowController.toggleBacklinks(_:)), "b",
                [.command, .shift]))
        return menu
    }

    private static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: windowMenuTitle)
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        // W-4: closing the window quits the app.
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
