import AppKit

final class ViewerApplication: NSApplication {
    #if DEBUG
        override var mainMenu: NSMenu? {
            get { super.mainMenu }
            set {
                DebugMenuDump.willSetMainMenu(from: super.mainMenu, to: newValue)
                super.mainMenu = newValue
            }
        }
    #endif

    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        // AppKit can dispatch a hidden item's effective key directly, bypassing local event monitors.
        if AppKitShell.current == nil, let item = sender as? NSMenuItem, item.action == action,
            DocumentEditMenu.hiddenActions.contains(action),
            item.isHidden || DocumentEditMenu.isInFileMenu(item.menu, of: mainMenu)
        {
            MenuTrace.record(
                "blocked document edit action=\(NSStringFromSelector(action)) id=\(ObjectIdentifier(item).hashValue)")
            return false
        }
        return super.sendAction(action, to: target, from: sender)
    }
}
