import AppKit
import SwiftUI

/// Constrain the hosted view to the same viewport even when testing a control wider than the panel.
@MainActor
final class OrgReadingTestWindow<Content: View> {
    let window: NSWindow
    let host: NSHostingView<Content>

    init(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: content())
        host.sizingOptions = []
        window.contentView = host
        host.layoutSubtreeIfNeeded()
    }

    func views<T: NSView>(_ type: T.Type, in root: NSView? = nil) -> [T] {
        func descendants(_ view: NSView) -> [T] {
            guard !view.isHidden else { return [] }
            let children = view.subviews.flatMap(descendants)
            if let match = view as? T { return [match] + children }
            return children
        }
        return descendants(root ?? host)
    }
}
