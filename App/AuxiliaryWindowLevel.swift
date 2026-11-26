import AppKit

/// Documents own their levels; only ordinary auxiliary windows borrow the floating level.
final class AuxiliaryWindowLevel: NSObject {
    static let shared = AuxiliaryWindowLevel()
    private let documents = NSHashTable<NSWindow>.weakObjects()
    private let raised = NSHashTable<NSWindow>.weakObjects()

    private let borrowedSpaces = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    private static let spaceRoles: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .moveToActiveSpace, .fullScreenPrimary, .fullScreenAuxiliary, .fullScreenNone,
    ]

    init(observesNotifications: Bool = true) {
        super.init()
        if observesNotifications {
            for name in [
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowChanged(_:)), name: name, object: nil)
            }
        }
    }

    func registerDocument(_ window: NSWindow) {
        restoreSpaces(of: window)
        documents.add(window)
        raised.remove(window)
    }

    static func shouldRaise(
        isDocument: Bool, isPanel: Bool, isVisible: Bool, isTitled: Bool, hasParent: Bool, level: NSWindow.Level
    ) -> Bool {
        !isDocument && !isPanel && isVisible && isTitled && !hasParent && level == .normal
    }

    func refresh(windows: [NSWindow], excluding closed: NSWindow? = nil, presenting: NSWindow? = nil) {
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
        let hasAllSpacesDocument = documents.allObjects.contains {
            $0 !== closed && $0.isVisible && $0.collectionBehavior.contains(.canJoinAllSpaces)
        }
        for window in windows where window !== closed && !window.styleMask.contains(.fullScreen) {
            let eligible =
                raised.contains(window)
                || Self.shouldRaise(
                    isDocument: documents.contains(window), isPanel: window is NSPanel,
                    isVisible: window.isVisible || window === presenting,
                    isTitled: window.styleMask.contains(.titled),
                    hasParent: window.parent != nil || window.sheetParent != nil,
                    level: window.level)
            if hasAllSpacesDocument && eligible {
                let original = window.collectionBehavior
                let behavior = original.subtracting(Self.spaceRoles).union([.canJoinAllSpaces, .fullScreenAuxiliary])
                if original != behavior {
                    if borrowedSpaces.object(forKey: window) == nil {
                        borrowedSpaces.setObject(
                            NSNumber(value: original.intersection(Self.spaceRoles).rawValue), forKey: window)
                    }
                    window.collectionBehavior = behavior
                }
            } else {
                restoreSpaces(of: window)
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

    private func restoreSpaces(of window: NSWindow) {
        guard let saved = borrowedSpaces.object(forKey: window) else { return }
        borrowedSpaces.removeObject(forKey: window)
        let behavior = window.collectionBehavior.subtracting(Self.spaceRoles)
            .union(NSWindow.CollectionBehavior(rawValue: saved.uintValue))
        if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
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
