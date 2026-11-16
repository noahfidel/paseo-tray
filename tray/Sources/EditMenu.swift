import AppKit

enum EditMenu {
    static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // macOS treats the first item as the app menu.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "PaseoTray")
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: L("Edit", "编辑"))
        for spec in EditMenuSpec.items {
            guard let spec else {
                editMenu.addItem(NSMenuItem.separator())
                continue
            }
            let item = NSMenuItem(title: spec.title, action: NSSelectorFromString(spec.action), keyEquivalent: spec.key)
            item.keyEquivalentModifierMask = spec.shift ? [.command, .shift] : [.command]
            item.target = nil
            editMenu.addItem(item)
        }
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        return mainMenu
    }

    /// Headless check for `--self-check`.
    static func selfCheck() -> Bool {
        func fail(_ reason: String) -> Bool {
            print("edit-menu: FAIL — \(reason)")
            return false
        }
        let menu = makeMainMenu()
        guard menu.items.count == 2, let edit = menu.items[1].submenu else { return fail("missing Edit submenu") }
        let actions = edit.items.filter { !$0.isSeparatorItem }
        let specs = EditMenuSpec.items.compactMap { $0 }
        guard actions.count == specs.count, actions.count == 6 else { return fail("expected 6 actions, got \(actions.count)") }
        // undo:/redo: are answered by the window (it is in the responder chain), the rest by the text view.
        let textView = NSTextView()
        let window = NSWindow()
        for (item, spec) in zip(actions, specs) {
            guard let action = item.action, NSStringFromSelector(action) == spec.action else {
                return fail("wrong action for \(spec.title)")
            }
            let expectedMask: NSEvent.ModifierFlags = spec.shift ? [.command, .shift] : [.command]
            guard item.keyEquivalent == spec.key, item.keyEquivalentModifierMask == expectedMask else {
                return fail("wrong key equivalent for \(spec.action)")
            }
            guard item.target == nil else { return fail("\(spec.action) has a target") }
            guard textView.responds(to: action) || window.responds(to: action) else {
                return fail("neither NSTextView nor NSWindow responds to \(spec.action)")
            }
        }
        print("edit-menu: OK")
        return true
    }
}
