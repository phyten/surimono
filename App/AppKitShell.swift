import AppKit

final class AppKitShell: NSObject, NSMenuItemValidation {
    private(set) static var current: AppKitShell?
    let environment = ViewerEnvironment()
    private let delegate = AppDelegate()
    private lazy var menu = ViewerMainMenu(shell: self)
    private var settings: SettingsWindowController?

    static func run() {
        // AppKit uses the first document controller created as its shared controller.
        let documents = ViewerDocumentController()
        precondition(NSDocumentController.shared === documents)
        let application = ViewerApplication.shared
        let shell = AppKitShell()
        current = shell
        application.delegate = shell.delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(documents) {}
    }

    var menuTrackingDepth: Int { menu.trackingDepth }

    func installMenu() { menu.install() }

    private var canToggleSettings: Bool {
        ShortcutDispatcher.shared.canPerform(.operation(.appSettings))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(toggleSettings(_:)) && canToggleSettings
    }

    @objc func toggleSettings(_ sender: Any?) {
        guard canToggleSettings else { return }
        if let window = settings?.window, window.isKeyWindow {
            window.performClose(sender)
        } else {
            showSettings(sender)
        }
    }

    var hasOpenSettings: Bool {
        guard let window = settings?.window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    func showSettings(_ sender: Any?) {
        let controller = settingsController()
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    func settingsController() -> SettingsWindowController {
        if let settings { return settings }
        let window = SettingsWindowController.makeWindow(for: environment.settingsView)
        // Prefer the AppKit frame. Older installations saved the Settings scene under SwiftUI's name.
        if !window.setFrameUsingName("SurimonoSettings"),
            !window.setFrameUsingName("com_apple_SwiftUI_Settings_window")
        {
            window.center()
        }
        window.setFrameAutosaveName("SurimonoSettings")
        let controller = SettingsWindowController(window: window, editor: environment.arrangementEditor)
        settings = controller
        return controller
    }
}
