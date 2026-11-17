import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import UniformTypeIdentifiers

enum ReadingExportKind: Equatable {
    case png, html, htmlText, share

    var needsTheme: Bool { self == .html || self == .htmlText }
}

extension DocumentViewModel {
    func cancelAdditionalExport() {
        additionalExportTask?.cancel()
        exportPanel?.cancel(nil)
    }

    func clearSharedExport() {
        sharePicker = nil
        if let sharedExportDirectory { try? FileManager.default.removeItem(at: sharedExportDirectory) }
        sharedExportDirectory = nil
    }

    func exportReading(_ kind: ReadingExportKind) {
        guard additionalExportTask == nil, !isExporting, !isPrinting,
            !kind.needsTheme || (format.usesPrintTheme && binder == nil && imageBundle == nil),
            !deferUntilWebIsCaptured(.additional(kind)), !deferUntilReviewEnds(.additional(kind))
        else { return }
        guard isUpToDate else {
            guard error == nil else { return }
            outputAfterReview = .additional(kind)
            if !isRendering { render() }
            return
        }
        additionalExportTask = Task { [weak self] in
            guard let self else { return }
            defer { additionalExportTask = nil }
            _ = await performReadingExport(kind)
        }
    }

    /// The panel-free entry point is also used by DEBUG verification. Only the interactive copy command defaults
    /// to the general pasteboard; its test and DEBUG callers explicitly supply their own board.
    @discardableResult
    func performReadingExport(
        _ kind: ReadingExportKind, destination: URL? = nil, dpi: Double? = nil,
        pasteboard: NSPasteboard = .general
    ) async -> Bool {
        if kind == .share { clearSharedExport() }
        let metadataTitle: String
        if kind.needsTheme {
            guard let title = await beginThemedExport() else { return false }
            metadataTitle = title
        } else {
            guard await beginReadingPDFExport() else { return false }
            metadataTitle = ""
        }
        defer {
            exportPanel = nil
            endReadingExport()
        }
        let originalData = data
        let originalSources = protectedSourceURLs
        let name = String(readingExportName.dropLast(4))
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard data == originalData, protectedSourceURLs == originalSources else { throw CancellationError() }
        }
        do {
            if kind == .share {
                guard let document = exportingDocument, let view = window?.contentView else { return false }
                clearSharedExport()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                sharedExportDirectory = directory
                let file = directory.appendingPathComponent(readingExportName)
                guard let bytes = document.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                try checkCurrent()
                guard Self.canExport(to: file, sourceURLs: originalSources) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try bytes.write(to: file, options: .withoutOverwriting)
                let picker = NSSharingServicePicker(items: [file])
                sharePicker = picker
                picker.show(
                    relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1),
                    of: view, preferredEdge: .minY)
                return true
            }
            if kind == .png {
                guard let document = exportingDocument, let bytes = document.dataRepresentation() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let folderMode = destination != nil || document.pageCount > 1
                let choice: (URL, Double)?
                if let destination {
                    choice = (destination, dpi ?? Double(preferences.exportImageDPI))
                } else {
                    choice = await imageDestination(name: name, folder: folderMode)
                }
                guard let (target, requestedDPI) = choice else { return false }
                try checkCurrent()
                var effective = requestedDPI
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { throw CocoaError(.fileReadCorruptFile) }
                    effective = min(
                        effective,
                        PageImageExporter.effectiveDPI(
                            size: page.bounds(for: .cropBox).size,
                            dpi: requestedDPI))
                }
                guard effective > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
                let access = target.startAccessingSecurityScopedResource()
                defer { if access { target.stopAccessingSecurityScopedResource() } }
                guard Self.canExport(to: target, sourceURLs: originalSources) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let folder = folderMode ? try ExportFiles.newFolder(in: target, name: name) : nil
                var finished = false
                defer { if !finished, let folder { try? FileManager.default.removeItem(at: folder) } }
                for index in 0..<document.pageCount {
                    try checkCurrent()
                    let png = try await PageImageExporter.png(document: bytes, page: index, dpi: effective)
                    try checkCurrent()
                    let file =
                        folder?.appendingPathComponent(
                            ExportFiles.pageName(
                                name, index: index,
                                count: document.pageCount)) ?? target
                    guard Self.canExport(to: file, sourceURLs: originalSources + protectedSourceURLs) else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try png.write(to: file, options: folder == nil ? .atomic : .withoutOverwriting)
                }
                finished = true
                if effective < requestedDPI {
                    showToast(
                        Toast(
                            systemImage: "info.circle",
                            title: String(localized: "Resolution was reduced for this export.")))
                }
                return true
            }
            guard let settings = renderSettings(in: .view) else { return false }
            let source = withFolderAccess(DocumentSource(data: data, fileURL: fileURL, format: format))
            let html = try await HTMLExporter.html(
                source: source, settings: settings, title: metadataTitle)
            try checkCurrent()
            if kind == .html {
                let target: URL?
                if let destination { target = destination } else { target = await htmlDestination(name: name) }
                guard let target else { return false }
                try checkCurrent()
                guard Self.canExport(to: target, sourceURLs: originalSources + protectedSourceURLs) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let access = target.startAccessingSecurityScopedResource()
                defer { if access { target.stopAccessingSecurityScopedResource() } }
                try Data(html.utf8).write(to: target, options: .atomic)
            } else {
                pasteboard.clearContents()
                guard pasteboard.setString(html, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
                showToast(Toast(systemImage: "checkmark", title: String(localized: "Copied")))
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if Task.isCancelled { return false }
            if kind == .share { clearSharedExport() }
            outputError = String(localized: "The document could not be exported.") + "\n" + error.localizedDescription
            return false
        }
    }

    private func imageDestination(name: String, folder: Bool) async -> (URL, Double)? {
        guard let window else { return nil }
        let panel: NSSavePanel
        if folder {
            let open = NSOpenPanel()
            open.canChooseDirectories = true
            open.canChooseFiles = false
            open.allowsMultipleSelection = false
            open.canCreateDirectories = true
            open.isAccessoryViewDisclosed = true
            panel = open
        } else {
            panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = name + ".png"
        }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["72 dpi", "144 dpi", "300 dpi"])
        popup.selectItem(at: [72, 144, 300].firstIndex(of: preferences.exportImageDPI) ?? 1)
        popup.setAccessibilityLabel(String(localized: "Resolution"))
        let accessory = NSStackView(views: [NSTextField(labelWithString: String(localized: "Resolution")), popup])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        popup.sizeToFit()
        accessory.setFrameSize(accessory.fittingSize)
        panel.accessoryView = accessory
        exportPanel = panel
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let url = panel.url, !Task.isCancelled else { return nil }
        let dpi = [72, 144, 300][max(0, popup.indexOfSelectedItem)]
        preferences.exportImageDPI = dpi
        return (url, Double(dpi))
    }

    private func htmlDestination(name: String) async -> URL? {
        guard let window else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = name + ".html"
        exportPanel = panel
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }
}
