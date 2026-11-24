import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import UniformTypeIdentifiers

enum ReadingExportKind: Equatable {
    case png, html, htmlText, richText, share

    var needsTheme: Bool { self == .html || self == .htmlText || self == .richText }
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

    func canExportReading(_ kind: ReadingExportKind) -> Bool {
        additionalExportTask == nil && canRequestReadingOutput
            && (!kind.needsTheme || (format.usesPrintTheme && binder == nil && imageBundle == nil))
    }

    func exportReading(_ kind: ReadingExportKind) {
        guard canExportReading(kind),
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
            _ = await performReadingExport(kind, pasteboard: kind == .richText || kind == .htmlText ? .general : nil)
        }
    }

    /// The panel-free entry point is also used by DEBUG verification. Only the interactive copy command writes
    /// to the general pasteboard. File exports need no board.
    @discardableResult
    func performReadingExport(
        _ kind: ReadingExportKind, destination: URL? = nil, dpi: Double? = nil,
        pasteboard: NSPasteboard? = nil, deliverSharedFile: ((URL) -> Void)? = nil
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
                guard case .reading(let bytes) = pendingPDF, let view = window?.contentView else { return false }
                clearSharedExport()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                sharedExportDirectory = directory
                let file = directory.appendingPathComponent(readingExportName)
                try checkCurrent()
                guard Self.canExport(to: file, sourceURLs: originalSources) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try bytes.write(to: file, options: .withoutOverwriting)
                if let deliverSharedFile {
                    deliverSharedFile(file)
                    return true
                }
                let picker = NSSharingServicePicker(items: [file])
                sharePicker = picker
                picker.show(
                    relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1),
                    of: view, preferredEdge: .minY)
                return true
            }
            if kind == .png {
                guard case .reading(let bytes) = pendingPDF, let document = PDFDocument(data: bytes) else {
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
            let source = withFolderAccess(
                DocumentSource(data: data, fileURL: fileURL, format: format).named(sourceFileName))
            if kind == .richText {
                let rich = try await HTMLExporter.richText(source: source, settings: settings, title: metadataTitle)
                try checkCurrent()
                if let destination {
                    try writeRichText(rich, to: destination, name: name)
                } else {
                    guard let pasteboard else { return false }
                    try rich.write(to: pasteboard)
                    showToast(Toast(systemImage: "checkmark", title: String(localized: "Copied")))
                }
                return true
            }
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
                guard let pasteboard else { return false }
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

    private func writeRichText(_ export: RichTextExport, to folder: URL, name: String) throws {
        let fm = FileManager.default
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileNoSuchFile)
        }
        let base = folder.appendingPathComponent(name)
        let package = base.appendingPathExtension("rtfd")
        let files = [base.appendingPathExtension("rtf"), base.appendingPathExtension("html"), package]
        guard files.allSatisfy({ Self.canExport(to: $0, sourceURLs: protectedSourceURLs) }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // Stage the package privately. Moving into place and exclusive file writes never replace an existing export.
        let stage = folder.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let staged = stage.appendingPathComponent(package.lastPathComponent)
        try export.rtfd.write(to: staged, options: .atomic, originalContentsURL: nil)
        var created = [URL]()
        do {
            try export.rtf.write(to: files[0], options: .withoutOverwriting)
            created.append(files[0])
            try Data(export.html.utf8).write(to: files[1], options: .withoutOverwriting)
            created.append(files[1])
            try fm.moveItem(at: staged, to: package)
        } catch {
            for file in created { try? fm.removeItem(at: file) }
            throw error
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
