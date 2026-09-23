import Cocoa

/// The app is faceless (LSUIElement) and starts without a menu bar. AppKit routes ⌘-shortcuts
/// through the main menu's key equivalents, so a window without one gets no ⌘C, ⌘V, ⌘Z or ⌘A.
/// Installed when the settings window shows.
enum MainMenu {
    static func install() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About mmco", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide mmco", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit mmco", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "mmco"))

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Shift Right", action: #selector(ShellTextView.shiftRight(_:)), keyEquivalent: "]")
        edit.addItem(withTitle: "Shift Left", action: #selector(ShellTextView.shiftLeft(_:)), keyEquivalent: "[")
        edit.addItem(withTitle: "Toggle Comment", action: #selector(ShellTextView.toggleComment(_:)), keyEquivalent: "/")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(findItem("Find…", tag: .showFindInterface, key: "f"))
        find.addItem(findItem("Find and Replace…", tag: .replace, key: "f", modifiers: [.command, .option]))
        find.addItem(findItem("Find Next", tag: .nextMatch, key: "g"))
        find.addItem(findItem("Find Previous", tag: .previousMatch, key: "G"))
        find.addItem(findItem("Use Selection for Find", tag: .setSearchString, key: "e"))
        edit.addItem(submenu(find, title: "Find"))
        main.addItem(submenu(edit, title: "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func findItem(_ title: String, tag: NSTextFinder.Action, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag.rawValue
        return item
    }
}
