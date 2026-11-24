import AppKit
import SwiftUI
import Testing

/// Constrain the hosted view to the same viewport even when testing a control wider than the panel.
@MainActor
final class OrgReadingTestWindow {
    let window: NSWindow
    let host: NSView

    init<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // A hosted test has no external accessibility client to request SwiftUI's virtual elements.
        let view = NSHostingView(rootView: content().environment(\.accessibilityEnabled, true))
        view.sizingOptions = []
        host = view
        window.contentView = host
        host.layoutSubtreeIfNeeded()
    }

    static func elements(in root: NSView) -> [any NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: Any) -> [any NSAccessibilityProtocol] {
            guard let node = object as? any NSAccessibilityProtocol,
                visited.insert(ObjectIdentifier(node)).inserted
            else { return [] }
            let view = object as? NSView
            guard view?.isHiddenOrHasHiddenAncestor != true else { return [] }
            // Some controls are virtual children of the host, others live in embedded AppKit views.
            let children = (node.accessibilityChildren() ?? []) + (view?.subviews ?? [])
            return [node] + children.flatMap(walk)
        }
        return walk(root)
    }

    /// The file override is the only checked toggle in this fixture. Return frames in window coordinates.
    func checkedToggleFrames(label: String) -> [CGRect] {
        let nodes = Self.elements(in: host)
        let toggles = nodes.filter {
            ($0.accessibilityRole() == .checkBox || [$0.accessibilityTitle(), $0.accessibilityLabel()].contains(label))
                && $0.accessibilityValue() is NSNumber && !$0.accessibilityFrame().isEmpty
        }
        if !toggles.isEmpty {
            return toggles.filter {
                $0.isAccessibilityEnabled() && ($0.accessibilityValue() as? NSNumber)?.intValue == 1
            }.map { window.convertFromScreen($0.accessibilityFrame()) }
        }

        // On macOS 26 the checked control exposes AXUnknown and nil. Use cell state where available.
        // Menu selections also carry state. Their semantic AX node may be separate from the backing view.
        let menuRoles: [NSAccessibility.Role] = [.popUpButton, .menuButton, .comboBox]
        let menus = nodes.filter { node in menuRoles.contains { $0 == node.accessibilityRole() } }
            .map { window.convertFromScreen($0.accessibilityFrame()) }
        return nodes.compactMap { node in
            guard let control = node as? NSControl, control.isEnabled, let cell = control.cell,
                cell.state == .on, !control.bounds.isEmpty,
                !menuRoles.contains(where: { $0 == cell.accessibilityRole() })
            else { return nil }
            let frame = control.convert(control.bounds, to: nil)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            return menus.contains(where: { $0.contains(center) }) ? nil : frame
        }
    }

    func click(_ frame: CGRect) throws {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                "click=\(point) frame=\(frame)\n\(diagnostic())")
            window.sendEvent(event)
        }
    }

    static func diagnostic(in root: NSView) -> String {
        let nodes = elements(in: root).map { node in
            let cell = (node as? NSControl)?.cell
            return "\(type(of: node)) role=\(node.accessibilityRole()?.rawValue ?? "-") "
                + "id=\(node.accessibilityIdentifier() ?? "-") label=\(node.accessibilityLabel() ?? "-") "
                + "title=\(node.accessibilityTitle() ?? "-") value=\(String(describing: node.accessibilityValue())) "
                + "enabled=\(node.isAccessibilityEnabled()) frame=\(node.accessibilityFrame())"
                + (cell.map { " cellRole=\($0.accessibilityRole()?.rawValue ?? "-") cellState=\($0.state.rawValue)" }
                    ?? "")
        }
        return "bounds=\(root.bounds)\n" + nodes.joined(separator: "\n")
    }

    func diagnostic() -> String {
        let roots = [host] + window.sheets.compactMap(\.contentView)
        return "scale=\(window.backingScaleFactor) sheets=\(window.sheets.count)\n"
            + roots.map(Self.diagnostic(in:)).joined(separator: "\n")
    }

    func wait(
        _ detail: @autoclosure () -> String, until condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "\(detail())\n\(diagnostic())", sourceLocation: sourceLocation)
    }
}
