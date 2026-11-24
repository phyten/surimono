import AppKit
import UniformTypeIdentifiers

/// File > Share always owns its row. The picker gets explicit items because NSDocument's standard
/// sharing path can save or relocate the document and does not cover bundle or clipboard windows.
final class FileShareMenu: NSObject, NSMenuItemValidation {
    let item = NSMenuItem(title: String(localized: "Share"), action: nil, keyEquivalent: "")
    private var picker: NSSharingServicePicker?
    private var standardItem: NSMenuItem?
    private var payload: [Any] = []
    private var source: Source?
    private weak var model: DocumentViewModel?

    private enum Source: Equatable {
        case empty, pendingPDF
        case pdf(String)
        case files([URL])

        init(_ model: DocumentViewModel?) {
            guard let model else {
                self = .empty
                return
            }
            let urls = model.fileURL.map { [$0] } ?? model.sourceURLs
            if !urls.isEmpty {
                self = .files(urls)
            } else if !model.canExportReading(.share) {
                self = .empty
            } else if model.canExportReadingPDF && !model.showsWeb {
                self = .pdf(model.readingExportName)
            } else {
                self = .pendingPDF
            }
        }
    }

    func update(for model: DocumentViewModel?) {
        let next = Source(model)
        guard next != source || self.model !== model else { return }
        source = next
        self.model = model
        picker = nil
        standardItem = nil
        payload = []
        let menu = NSMenu(title: item.title)
        item.submenu = menu
        item.isEnabled = next != .empty
        switch next {
        case .empty: return
        case .pendingPDF:
            // Capture, pagination and smart-removal review must finish through the existing export command.
            let pdf = menu.addItem(
                withTitle: String(localized: "Share PDF…"), action: #selector(sharePDF), keyEquivalent: "")
            pdf.target = self
            return
        case .pdf(let name):
            guard let model else { return }
            let provider = NSItemProvider()
            provider.suggestedName = name
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all
            ) {
                [weak model] completion in
                Task { @MainActor [weak model] in
                    // Generate the same private PDF as Export > Share PDF only when a service asks for it.
                    guard let model, model.window != nil, !model.showsWeb, model.canExportReadingPDF,
                        model.canExportReading(.share),
                        await model.performReadingExport(.share, deliverSharedFile: { completion($0, false, nil) })
                    else {
                        completion(nil, false, CocoaError(.userCancelled))
                        return
                    }
                }
                return nil
            }
            payload = [provider]
        case .files(let urls): payload = urls
        }

        let picker = NSSharingServicePicker(items: payload)
        self.picker = picker
        let standard = picker.standardShareMenuItem
        standardItem = standard
        if standard.menu == nil, let services = standard.submenu, services.supermenu == nil {
            // Transfer only from this unattached item. A submenu cannot have two owners.
            standard.submenu = nil
            item.submenu = services
            return
        }
        // macOS 15 supports the picker item, but the API also permits a plain action that opens
        // a popover. Keep the File row icon-free with a real submenu in either presentation.
        for service in NSSharingService.sharingServices(forItems: payload) {
            let row = menu.addItem(
                withTitle: service.menuItemTitle, action: #selector(performService(_:)), keyEquivalent: "")
            row.image = service.image
            row.representedObject = service
            row.target = self
        }
        if menu.items.isEmpty, standard.menu == nil, standard.submenu == nil { menu.addItem(standard) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.menu === item.submenu, let model, DocumentWindows.shared.currentModel === model,
            NSApp.modalWindow == nil,
            NSApp.keyWindow?.attachedSheet == nil
        else { return false }
        if menuItem.action == #selector(sharePDF) { return model.canExportReading(.share) }
        return source == Source(model) && menuItem.representedObject is NSSharingService
    }

    @objc private func performService(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let service = sender.representedObject as? NSSharingService,
            service.canPerform(withItems: payload)
        else { return }
        service.perform(withItems: payload)
    }

    @objc private func sharePDF(_ sender: NSMenuItem) {
        if validateMenuItem(sender) { model?.exportReading(.share) }
    }
}
