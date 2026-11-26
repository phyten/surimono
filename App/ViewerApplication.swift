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

    override func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) -> Bool {
        // Settings, including its previously archived identifier, opens only on request.
        guard ViewerFileDocument.recognizes(window: identifier) else { return false }
        return super.restoreWindow(withIdentifier: identifier, state: state, completionHandler: completionHandler)
    }
}
