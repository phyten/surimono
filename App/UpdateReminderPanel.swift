import AppKit

// Surimono hides document title bars, so a title-bar accessory would hide the reminder too. A small nonactivating
// panel stays visible while the reader works, without taking keyboard focus or appearing over another app.
final class UpdateReminderPanel: NSPanel {
    private let showUpdate: () -> Void
    private var activationObserver: (any NSObjectProtocol)?

    init(showUpdate: @escaping () -> Void) {
        self.showUpdate = showUpdate
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = String(localized: "Update Available")
        hidesOnDeactivate = true
        level = .floating
        let button = NSButton(
            title: String(localized: "Show Update…"), target: self, action: #selector(showAvailableUpdate))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(button)
        if let contentView {
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }
        if let screen = NSScreen.main {
            setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 16, y: screen.visibleFrame.minY + 16))
        }
    }

    func showWhenActive() {
        if NSApp.isActive { orderFront(nil) }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.orderFront(nil) }
        }
    }

    override func close() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        super.close()
    }

    override var canBecomeKey: Bool { false }

    @objc private func showAvailableUpdate() { showUpdate() }
}
