import AppKit
import SurimonoCore

/// Observed by SwiftUI callers through the controller; menu defaults remain in the menu declarations.
enum ShortcutHints {
    static func keys(_ operations: [ShortcutOperationID], controller: ShortcutController = .shared) -> String {
        operations.flatMap { controller.localKeys(for: $0) }.map { controller.layout.display($0) }
            .joined(separator: " / ")
    }

    static func help(_ title: String, _ operations: [ShortcutOperationID], controller: ShortcutController = .shared)
        -> String
    {
        let hint = keys(operations, controller: controller)
        return hint.isEmpty ? title : String.localizedStringWithFormat(String(localized: "%1$@ (%2$@)"), title, hint)
    }

    static func announce(_ message: String?) {
        guard let message, let application = NSApp else { return }
        NSAccessibility.post(
            element: application, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    static let layouts: [ShortcutOperationID] = [
        .printLayoutSingle, .printLayoutDuplex, .printLayoutBookletLarge, .printLayoutBookletSmall,
        .printLayoutTwoUpLarge, .printLayoutHandout,
    ]

    static func layout(_ layout: PrintLayout, index: Int, compact: Bool) -> ShortcutOperationID {
        if compact {
            if layout.kind == .fourUp { return .printLayoutFourUp }
            if PrintLayout.compactPresets(in: layout.series).contains(where: { $0.id == layout.id }) {
                return .printLayoutTwoUpSmall
            }
        }
        return layouts[index]
    }
}
