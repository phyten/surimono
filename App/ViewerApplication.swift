import AppKit

final class ViewerApplication: NSApplication {
    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        // AppKit can dispatch a hidden item's effective key directly, bypassing local event monitors.
        if let item = sender as? NSMenuItem, item.action == action, DocumentEditMenu.hiddenActions.contains(action),
            item.isHidden || DocumentEditMenu.isInFileMenu(item.menu, of: mainMenu)
        {
            MenuTrace.record(
                "blocked document edit action=\(NSStringFromSelector(action)) id=\(ObjectIdentifier(item).hashValue)")
            return false
        }
        return super.sendAction(action, to: target, from: sender)
    }
}
