import AppKit
import SwiftUI

/// Receives file drags for the whole window. Mouse events pass through it, so nothing below notices it, but AppKit
/// looks for a drag's destination without hit testing and finds it above the paper and the live web page, which would
/// otherwise take the drag and refuse it.
struct DropCatcher: NSViewRepresentable {
    weak var model: DocumentViewModel?

    func makeNSView(context: Context) -> DropCatcherView {
        DropCatcherView()
    }

    func updateNSView(_ view: DropCatcherView, context: Context) {
        view.model = model
    }

    static func dismantleNSView(_ view: DropCatcherView, coordinator: ()) {
        view.model = nil
    }
}

final class DropCatcherView: NSView {
    weak var model: DocumentViewModel?
    private var session: DropSession? { model?.drop }

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
        guard let model, !model.isWindowClosed else { return [] }
        session?.size = window?.contentView?.bounds.size ?? bounds.size
        return model.dragEntered(urls(of: sender), at: point(of: sender)) ? .copy : []
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
        guard let model, !model.isWindowClosed else { return false }
        defer { session?.end() }
        session?.move(to: point(of: sender))
        // Reading the files now, at the drop, is what gives a sandboxed app access to them.
        _ = urls(of: sender)
        return model.performDrop()
    }
}
