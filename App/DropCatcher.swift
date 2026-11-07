import AppKit
import SwiftUI

/// Receives file drags for the whole window. Mouse events pass through it, so nothing below notices it, but AppKit
/// looks for a drag's destination without hit testing and finds it above the paper and the live web page, which would
/// otherwise take the drag and refuse it.
struct DropCatcher: NSViewRepresentable {
    let session: DropSession
    /// The window's own part: the new drag's plan is decided by the model, which knows what the window holds.
    let onEnter: ([URL], CGPoint) -> Bool
    let onPerform: () -> Bool

    func makeNSView(context: Context) -> DropCatcherView {
        DropCatcherView()
    }

    func updateNSView(_ view: DropCatcherView, context: Context) {
        view.session = session
        view.onEnter = onEnter
        view.onPerform = onPerform
    }
}

final class DropCatcherView: NSView {
    var session: DropSession?
    var onEnter: (([URL], CGPoint) -> Bool)?
    var onPerform: (() -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// From the top-left of the window's content, as SwiftUI's global frames are.
    private func point(of info: NSDraggingInfo) -> CGPoint {
        let height = window?.contentView?.bounds.height ?? bounds.height
        return CGPoint(x: info.draggingLocation.x, y: height - info.draggingLocation.y)
    }

    private func urls(of info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        session?.size = window?.contentView?.bounds.size ?? bounds.size
        return onEnter?(urls(of: sender), point(of: sender)) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        session?.move(to: point(of: sender)) == true ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        session?.end()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        session?.end()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { session?.end() }
        session?.move(to: point(of: sender))
        // Reading the files now, at the drop, is what gives a sandboxed app access to them.
        _ = urls(of: sender)
        return onPerform?() == true
    }
}
