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
/// The File menu holds `New from Template` (TP-6) and Close; there is no New item and no Save
/// item, as the search field creates notes (S-1) and autosave writes them (E-4). The Window
/// menu is the standard one: Minimize, Zoom, Bring All to Front and the windows AppKit lists.
///
/// The `New from Template` submenu is filled as it opens (TP-6): its `TemplateMenuDelegate`
/// asks for the library's template names each time AppKit is about to show it, so it follows
/// `templates/` on disk (TP-7) and the library in use (L-1) with nothing to keep in step.
/// Every template is one row, sending `newFromTemplate(_:)` down the responder chain with
/// the name as its `representedObject`; with none there is one disabled `No Templates` row.
@MainActor
public enum MainMenu {
    /// The application's name as the menu titles use it.
    public static let appName = "MDNotes"

    public static let appMenuTitle = appName
    public static let fileMenuTitle = "File"
    public static let editMenuTitle = "Edit"
    public static let noteMenuTitle = "Note"
    public static let viewMenuTitle = "View"
    public static let windowMenuTitle = "Window"

    /// TP-6: `File > New from Template`. The submenu lists the library's templates by name
    /// (`fillTemplatesMenu`); with none it holds one disabled row, `noTemplatesItemTitle`,
    /// which is also what `make()` builds before any library is open.
    public static let newFromTemplateItemTitle = "New from Template"
    public static let noTemplatesItemTitle = "No Templates"
    public static let closeItemTitle = "Close"

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

    /// Builds the whole menu bar: the application menu, File, Edit, Note, View and Window. The
    /// Window menu is returned separately so the caller can hand it to the application as its
    /// windows menu, and the `New from Template` submenu so the caller can give it a
    /// `TemplateMenuDelegate` (TP-6); until then it holds the `No Templates` row.
    public static func make() -> (mainMenu: NSMenu, windowMenu: NSMenu, templatesMenu: NSMenu) {
        let main = NSMenu(title: "Main")
        let window = makeWindowMenu()
        let templates = NSMenu(title: newFromTemplateItemTitle)
        fillTemplatesMenu(templates, names: [])
        for menu in [makeAppMenu(), makeFileMenu(templates), makeEditMenu(), makeNoteMenu(), makeViewMenu(), window] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return (main, window, templates)
    }

    /// Replaces the rows of the `New from Template` submenu with one per name in `names`, in
    /// that order (TP-6): each sends `MainWindowController.newFromTemplate(_:)` down the
    /// responder chain with its name as `representedObject` and shows no shortcut. With no
    /// names the one row is `noTemplatesItemTitle`, action-less so the menu leaves it disabled.
    public static func fillTemplatesMenu(_ menu: NSMenu, names: [String]) {
        menu.removeAllItems()
        guard !names.isEmpty else {
            menu.addItem(NSMenuItem(title: noTemplatesItemTitle, action: nil, keyEquivalent: ""))
            return
        }
        for name in names {
            let item = item(name, #selector(MainWindowController.newFromTemplate(_:)))
            item.representedObject = name
            menu.addItem(item)
        }
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

    private static func makeFileMenu(_ templates: NSMenu) -> NSMenu {
        let menu = NSMenu(title: fileMenuTitle)
        // TP-6: the submenu lists the templates by name (`fillTemplatesMenu`); the item itself
        // only opens it.
        let newFromTemplate = NSMenuItem(title: newFromTemplateItemTitle, action: nil, keyEquivalent: "")
        newFromTemplate.submenu = templates
        menu.addItem(newFromTemplate)
        menu.addItem(.separator())
        // W-4: closing the window hides it; the delegate declines to quit on the last close.
        menu.addItem(item(closeItemTitle, #selector(NSWindow.performClose(_:)), "w"))
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

    /// The standard Window menu. AppKit appends the open windows below `Bring All to Front`
    /// once the menu is the application's windows menu.
    private static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: windowMenuTitle)
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
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

/// Fills the `New from Template` submenu each time AppKit is about to show it (TP-6): the
/// names `templateNames` returns now become its rows through `MainMenu.fillTemplatesMenu`.
/// The application delegate makes one over the library controller in use, so the submenu
/// follows `templates/` on disk (TP-7) and a change of library (L-1) without being told.
/// `NSMenu.delegate` is weak: the owner keeps this alive.
@MainActor
public final class TemplateMenuDelegate: NSObject, NSMenuDelegate {
    /// The template names to list, in menu order, asked for on every showing.
    public var templateNames: @MainActor () -> [String]

    public init(templateNames: @escaping @MainActor () -> [String]) {
        self.templateNames = templateNames
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        MainMenu.fillTemplatesMenu(menu, names: templateNames())
    }
}
