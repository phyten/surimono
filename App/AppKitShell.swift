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

    private var canOpenSettings: Bool {
        ShortcutDispatcher.shared.canPerform(.operation(.appSettings))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(openSettings(_:)) && canOpenSettings
    }

    @objc func openSettings(_ sender: Any?) {
        guard canOpenSettings else { return }
        showSettings(sender)
        if !NSApp.isActive { NSApp.activate() }
    }

    var hasOpenSettings: Bool {
        guard let window = settings?.window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    func showSettings(_ sender: Any?) {
        settingsController().showWindow(sender)
    }

    func settingsController() -> SettingsWindowController {
        if let settings { return settings }
        let window = SettingsWindowController.makeWindow(for: environment.settingsView)
        let controller = SettingsWindowController(window: window, editor: environment.arrangementEditor)
        settings = controller
        return controller
    }
}
