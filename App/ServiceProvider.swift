import AppKit
import SurimonoCore

/// Answers the Services menu's items, which Info.plist's NSServices declares. Nothing is written anywhere: selected text
/// opens from memory, as the clipboard's does, and files take the way of any other file.
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider(router: .shared, activate: { NSApp.activate() })

    private let router: OpenRouter
    private let activate: () -> Void

    init(router: OpenRouter, activate: @escaping () -> Void) {
        self.router = router
        self.activate = activate
    }

    /// The name the release and a development build each answer under, from their own NSServices.
    static var portName: String? {
        let services = Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]]
        return services?.first?["NSPortName"] as? String
    }

    func register() {
        guard let name = Self.portName else { return }
        NSRegisterServicesProvider(self, name)
    }

    @objc(openSelection:userData:error:)
    func openSelection(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        open(pasteboard, printing: false, error: error)
    }

    @objc(printSelection:userData:error:)
    func printSelection(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        open(pasteboard, printing: true, error: error)
    }

    private func open(
        _ pasteboard: NSPasteboard, printing: Bool, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard router.open(ClipboardWindows.content(from: pasteboard), printing: printing) else {
            error.pointee = String(localized: "There is nothing to open in the selection.") as NSString
            return
        }
        activate()
    }
}
