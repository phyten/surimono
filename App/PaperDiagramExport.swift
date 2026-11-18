import AppKit
import SurimonoCore
import SurimonoRendering
import UniformTypeIdentifiers

enum PaperDiagramAction: CaseIterable {
    case saveSVG, savePNG, copyPNG

    var title: String {
        switch self {
        case .saveSVG: String(localized: "Save Diagram as SVG…")
        case .savePNG: String(localized: "Save Diagram as PNG…")
        case .copyPNG: String(localized: "Copy Diagram as PNG")
        }
    }
}

extension DocumentViewModel {
    func exportDiagram(_ diagram: RenderedDiagram, action: PaperDiagramAction) {
        guard let window, beginDiagramExport() else { return }
        let sources = protectedSourceURLs
        let name = diagram.suggestedName(documentName: readingExportName)
        additionalExportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                additionalExportTask = nil
                exportPanel = nil
                endReadingExport()
            }
            do {
                try Task.checkCancellation()
                let destination: URL?
                if action == .copyPNG {
                    destination = nil
                } else {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [action == .saveSVG ? .svg : .png]
                    panel.nameFieldStringValue = name + (action == .saveSVG ? ".svg" : ".png")
                    exportPanel = panel
                    guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
                    destination = url
                }
                try Task.checkCancellation()
                let bytes: Data
                if action == .saveSVG {
                    bytes = Data(diagram.svg.utf8)
                } else {
                    bytes = try await WebPaginator.diagramPNG(diagram)
                }
                try Task.checkCancellation()
                if let destination {
                    let scoped = destination.startAccessingSecurityScopedResource()
                    defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                    guard Self.canExport(to: destination, sourceURLs: sources + protectedSourceURLs) else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try bytes.write(to: destination, options: .atomic)
                } else {
                    let board = NSPasteboard.general
                    board.clearContents()
                    guard board.setData(bytes, forType: .png) else { throw CocoaError(.fileWriteUnknown) }
                    showToast(Toast(systemImage: "checkmark", title: String(localized: "Copied")))
                }
            } catch {
                if !Task.isCancelled {
                    outputError =
                        String(localized: "The document could not be exported.") + "\n" + error.localizedDescription
                }
            }
        }
    }
}
