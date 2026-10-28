import AppKit
import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering

enum PreviewMode: String, CaseIterable { case sheets, pages }

@Observable
final class DocumentViewModel {
    let fileURL: URL?
    private(set) var format: DocumentFormat
    private var data: Data
    let preferences: AppPreferences
    let library: UserLibrary
    var layoutID: String
    var themeID: String
    var presetID: String
    var appearanceOverride: AppAppearance?
    var previewMode: PreviewMode = .sheets
    private(set) var result: RenderResult?
    private(set) var renderedSettings: RenderSettings?
    private(set) var isRendering = false
    private(set) var isPrinting = false
    private(set) var isExporting = false
    var error: String?
    var outputError: String?
    var notice: String?
    @ObservationIgnored weak var window: NSWindow?
    private let renderer: DocumentRenderer
    private var renderTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var printCompletion: PrintCompletion?
    private var printOperation: NSPrintOperation?
    private var exportingDocument: PDFDocument?

    init(
        data: Data, fileURL: URL?, format: DocumentFormat,
        preferences: AppPreferences, library: UserLibrary, renderer: DocumentRenderer = DocumentRenderer()
    ) {
        self.data = data
        self.fileURL = fileURL
        self.format = format
        self.preferences = preferences
        self.library = library
        self.renderer = renderer
        layoutID =
            PrintLayout.presets.contains(where: { $0.id == preferences.layoutID })
            ? preferences.layoutID : PrintLayout.a4Single.id
        themeID = library.themes.contains(where: { $0.id == preferences.themeID }) ? preferences.themeID : "standard"
        presetID = library.presets.contains(where: { $0.id == preferences.presetID }) ? preferences.presetID : "none"
        #if DEBUG
            DebugSnapshot.configure(self)
        #endif
    }

    var appearance: AppAppearance { appearanceOverride ?? preferences.appearance }
    var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    var layout: PrintLayout { PrintLayout.presets.first { $0.id == layoutID } ?? .a4Single }
    var renderSettings: RenderSettings? {
        guard
            let theme = library.themes.first(where: { $0.id == (format.usesPrintTheme ? themeID : "standard") })
                ?? library.themes.first(where: { $0.id == "standard" }),
            let preset = library.presets.first(where: { $0.id == (format.usesHTMLPreset ? presetID : "none") })
                ?? library.presets.first(where: { $0.id == "none" })
        else { return nil }
        return RenderSettings(
            layout: layout, theme: theme, preset: preset,
            options: PrintOptions(
                marginsInMillimeters: preferences.margin, showsPageNumbers: preferences.pageNumbers,
                rotatesBackSides: preferences.rotateBack),
            allowsJavaScriptInHTML: preferences.allowsJavaScript)
    }
    var canOutput: Bool {
        result != nil && !isRendering && !isPrinting && !isExporting && error == nil
            && renderedSettings == renderSettings
    }
    var previewDocument: PDFDocument? {
        previewMode == .sheets ? result?.sheetDocument : result?.logicalDocument
    }
    var summary: String? {
        guard let result, let renderedSettings else { return nil }
        return Self.summaryText(result.summary, layout: renderedSettings.layout, locale: Locale(identifier: language))
    }

    func start() {
        if watcher == nil, let fileURL {
            watcher = FileWatcher(url: fileURL) { [weak self] event in
                guard let self, self.watcher != nil else { return }
                switch event {
                case .changed: reload()
                case .removed: notice = String(localized: "The file is missing. The last preview is still available.")
                }
            }
        }
        render()
    }

    func stop() {
        renderTask?.cancel()
        noticeTask?.cancel()
        watcher?.stop()
        watcher = nil
    }

    func cycleAppearance() { appearanceOverride = appearance.next }

    func reload() {
        renderTask?.cancel()
        renderer.clearCache()
        if let fileURL {
            do {
                data = try Data(contentsOf: fileURL)
                notice = nil
            } catch {
                isRendering = false
                notice =
                    String(localized: "The file could not be reloaded. The last preview is still available.")
                    + "\n" + error.localizedDescription
                return
            }
        }
        render()
    }

    func reloadLibrary() {
        if !library.themes.contains(where: { $0.id == themeID }) { themeID = "standard" }
        if !library.presets.contains(where: { $0.id == presetID }) { presetID = "none" }
        reload()
    }

    func reopenAsText() {
        format = .plainText
        renderer.clearCache()
        render()
    }

    func render() {
        renderTask?.cancel()
        guard let settings = renderSettings else {
            error = String(localized: "Print styles could not be loaded. Reload them in Settings.")
            isRendering = false
            return
        }
        error = nil
        isRendering = true
        let source = DocumentSource(data: data, fileURL: fileURL, format: format)
        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await renderer.render(source, settings: settings)
                try Task.checkCancellation()
                result = output
                renderedSettings = settings
                isRendering = false
            } catch is CancellationError {
                // A superseding request owns the progress indicator.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = Self.message(for: error)
                isRendering = false
            }
        }
    }

    func printDocument(quick: Bool = false) {
        guard canOutput, let result, let renderedSettings, let window else { return }
        outputError = nil
        guard
            let operation = PrintJobFactory().printOperation(
                for: result.sheetDocument, layout: renderedSettings.layout, showsPrintPanel: !quick)
        else {
            outputError = String(localized: "The print job could not be created.")
            return
        }
        isPrinting = true
        let printer = operation.printInfo.printer.name
        let completion = PrintCompletion { [weak self] success in
            guard let self else { return }
            isPrinting = false
            printOperation = nil
            printCompletion = nil
            if quick {
                showNotice(
                    success
                        ? String(format: String(localized: "Sent to %@"), printer)
                        : String(localized: "The print job was cancelled or could not be sent."))
            }
        }
        printCompletion = completion
        printOperation = operation
        operation.runModal(
            for: window, delegate: completion,
            didRun: #selector(PrintCompletion.didRun(_:success:context:)), contextInfo: nil)
    }

    func exportPDF() {
        guard let renderedSettings, let window, beginPDFExport() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Self.exportName(
            fileURL: fileURL, layout: renderedSettings.layout, language: language)
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.completePDFExport(to: response == .OK ? panel.url : nil)
        }
    }

    func beginPDFExport() -> Bool {
        guard canOutput, let result else { return false }
        // Keep the selected output stable even if the file reloads while the save panel is open.
        exportingDocument = result.sheetDocument
        isExporting = true
        outputError = nil
        return true
    }

    func completePDFExport(to url: URL?) {
        guard isExporting, let exportingDocument else { return }
        defer {
            self.exportingDocument = nil
            isExporting = false
        }
        guard let url else { return }
        do {
            let sources =
                NSDocumentController.shared.documents.compactMap(\.fileURL)
                + [fileURL].compactMap { $0 }
            guard Self.canExport(to: url, sourceURLs: sources) else { throw CocoaError(.fileWriteNoPermission) }
            guard let data = exportingDocument.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        } catch {
            outputError = String(localized: "The PDF could not be exported.") + "\n" + error.localizedDescription
        }
    }

    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.notice = nil
        }
    }

    static func canExport(to destination: URL, sourceURLs: [URL]) -> Bool {
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        let destinationID = try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier
        return !sourceURLs.contains { source in
            if source.resolvingSymlinksInPath().standardizedFileURL == destination { return true }
            // File identity also catches alternate casing and hard links on the same volume.
            guard let destinationID = destinationID as? NSObject,
                let sourceID = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
            else { return false }
            return destinationID.isEqual(sourceID)
        }
    }

    static func exportName(fileURL: URL?, layout: PrintLayout, language: String) -> String {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Document")
        return "\(name)（\(layout.displayName(language: language))）.pdf"
    }

    static func summaryText(_ summary: PrintSummary, layout: PrintLayout, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let bindingKey =
            switch layout.duplex {
            case .none: "Single-sided"
            case .longEdge: "Duplex, long edge"
            case .shortEdge: "Duplex, short edge"
            }
        let binding = bundle.localizedString(forKey: bindingKey, value: nil, table: nil)
        let template = bundle.localizedString(forKey: "%ld pages → %@ %ld sheets (%@)", value: nil, table: nil)
        return String(
            format: template, locale: locale,
            summary.logicalPageCount, summary.paper.displayName, summary.sheetCount, binding)
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? DocumentRenderer.RenderingError else { return error.localizedDescription }
        switch error {
        case .invalidPDF: return String(localized: "This PDF could not be opened.")
        case .encryptedPDF: return String(localized: "Encrypted PDFs cannot be printed. Open an unlocked copy.")
        case .textDecodingFailed: return String(localized: "The text encoding could not be read without data loss.")
        case .invalidMargins:
            return String(localized: "The margins are too large for this page. Change them in Settings.")
        case .image: return String(localized: "This image could not be opened.")
        case .unsupportedFormat: return String(localized: "This document format is not supported.")
        case .pagination(.timedOut):
            return String(localized: "Loading or pagination timed out. Try reloading the document.")
        case .pagination(.loadFailed(let reason)):
            return String(localized: "The document could not be loaded.") + "\n" + reason
        case .pagination, .paginationFailed:
            return String(localized: "The document could not be paginated. Try reloading it.")
        case .composition: return String(localized: "The pages could not be arranged on the paper.")
        }
    }
}

private final class PrintCompletion: NSObject {
    let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }

    @objc func didRun(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        completion(success)
    }
}
