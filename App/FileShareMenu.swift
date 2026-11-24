import AppKit

/// The standalone sharing-service query is deprecated. Present the system picker
/// from an action we own, so a tracked File menu never retains a previous document's payload.
final class FileShareMenu: NSObject, NSMenuItemValidation {
    enum Content: Equatable {
        case files([URL])
        case readingPDF
    }

    let item = NSMenuItem(title: String(localized: "Share…"), action: #selector(share(_:)), keyEquivalent: "")
    private let dispatcher: ShortcutDispatcher
    private let deliver: @MainActor (DocumentViewModel, Content) -> Void

    init(
        dispatcher: ShortcutDispatcher = .shared,
        deliver: @escaping @MainActor (DocumentViewModel, Content) -> Void = FileShareMenu.present
    ) {
        self.dispatcher = dispatcher
        self.deliver = deliver
        super.init()
        item.target = self
    }

    private func selection() -> (DocumentViewModel, Content)? {
        guard let model = dispatcher.documentForMenuCommand, model.window?.contentView != nil else { return nil }
        let urls = model.fileURL.map { [$0] } ?? model.sourceURLs
        if !urls.isEmpty { return (model, .files(urls)) }
        return model.canExportReading(.share) ? (model, .readingPDF) : nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem === item && selection() != nil
    }

    @objc private func share(_ sender: NSMenuItem) {
        guard sender === item, let (model, content) = selection() else { return }
        deliver(model, content)
    }

    private static func present(_ model: DocumentViewModel, _ content: Content) {
        switch content {
        case .files(let urls):
            guard let view = model.window?.contentView else { return }
            let picker = NSSharingServicePicker(items: urls)
            model.clearSharedExport()
            model.sourceSharePicker = picker
            picker.show(
                relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1),
                of: view, preferredEdge: .minY)
        case .readingPDF:
            model.exportReading(.share)
        }
    }
}
