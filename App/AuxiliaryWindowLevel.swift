import AppKit

/// Documents own their levels; only ordinary auxiliary windows borrow the floating level.
final class AuxiliaryWindowLevel: NSObject {
    static let shared = AuxiliaryWindowLevel()
    private let documents = NSHashTable<NSWindow>.weakObjects()
    private let raised = NSHashTable<NSWindow>.weakObjects()

    init(observesNotifications: Bool = true) {
        super.init()
        if observesNotifications {
            for name in [
                NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowChanged(_:)), name: name, object: nil)
            }
        }
    }

    func registerDocument(_ window: NSWindow) {
        documents.add(window)
        raised.remove(window)
    }

    static func shouldRaise(
        isDocument: Bool, isPanel: Bool, isVisible: Bool, isTitled: Bool, hasParent: Bool, level: NSWindow.Level
    ) -> Bool {
        !isDocument && !isPanel && isVisible && isTitled && !hasParent && level == .normal
    }

    func refresh(windows: [NSWindow], excluding closed: NSWindow? = nil) {
        let hasFloatingDocument = documents.allObjects.contains {
            $0 !== closed && $0.isVisible && $0.level == .floating
        }
        for window in raised.allObjects {
            // Another owner changing the level takes control back from us.
            if window.level != .floating || documents.contains(window) {
                raised.remove(window)
            } else if !hasFloatingDocument {
                window.level = .normal
                raised.remove(window)
            }
        }
        guard hasFloatingDocument else { return }
        for window in windows where window !== closed {
            if Self.shouldRaise(
                isDocument: documents.contains(window), isPanel: window is NSPanel,
                isVisible: window.isVisible, isTitled: window.styleMask.contains(.titled),
                hasParent: window.parent != nil || window.sheetParent != nil, level: window.level
            ) {
                raised.add(window)
                window.level = .floating
            }
        }
    }

    @objc private func windowChanged(_ notification: Notification) {
        let closed = notification.name == NSWindow.willCloseNotification ? notification.object as? NSWindow : nil
        if let closed {
            documents.remove(closed)
            raised.remove(closed)
        }
        refresh(windows: NSApp.windows, excluding: closed)
    }
}
