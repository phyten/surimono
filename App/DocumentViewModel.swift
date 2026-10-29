import AppKit
import OSLog
import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering

enum ViewerMode { case view, print }

typealias DocumentSettingsStore = KeyedRecordStore<DocumentSettings>

/// A short message near the bottom of the window, optionally with one action.
struct Toast: Equatable, Identifiable {
    enum Action: Equatable { case resetDocumentSettings }

    let id = UUID()
    var systemImage: String
    var title: String
    var detail: String?
    var action: Action?
}

@Observable
final class DocumentViewModel {
    let fileURL: URL?
    let imageBundle: ImageBundleModel?
    private(set) var unreadableImageURLs: [URL] = []
    private var renderedSourceURLs: [URL] = []
    private(set) var format: DocumentFormat
    private var data: Data
    let preferences: AppPreferences
    let library: UserLibrary
    var layoutID: String
    var themeID: String
    var presetID: String
    var printOptions: PrintOptions
    var mode: ViewerMode = .view
    var viewOptions: ViewOptions
    /// Magnification relative to fitting the current page or spread into the window.
    var zoom: Double = 1
    /// The 0-based index of the first visible logical page.
    var currentPageIndex = 0
    var isMenuPinned = false
    var isAlwaysOnTop = false
    var isDrawerOpen = false
    var isViewOptionsPresented = false
    var toast: Toast?
    private(set) var result: RenderResult?
    private(set) var renderedSettings: RenderSettings?
    private(set) var isRendering = false
    private(set) var isPrinting = false
    private(set) var isExporting = false
    var error: String?
    var outputError: String?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored let paper = PaperController()
    /// The key of the remembered settings: the content hash of the file, of the ZIP, or of the set of images.
    private(set) var contentHash: ContentHash?
    private(set) var hasSavedSettings = false
    @ObservationIgnored let settingsStore: DocumentSettingsStore?
    /// The settings as last loaded, restored, reset or saved; any other value means the user changed something.
    @ObservationIgnored private var settingsBaseline: DocumentSettings?
    @ObservationIgnored private var pendingImageOrder: [String]?
    @ObservationIgnored private var restoredPaperSize: CGSize?
    /// The view mode's paper size when the print mode began; the tray's size is not the document's window size.
    @ObservationIgnored private var viewPaperSizeBeforePrinting: CGSize?
    @ObservationIgnored private var hasSizedWindow = false
    @ObservationIgnored private var didResizeWindow = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var hashTask: Task<Void, Never>?
    @ObservationIgnored private var openFailure: String?
    @ObservationIgnored private var retriedChangedImages = false
    @ObservationIgnored private var hasShownArchiveSummary = false
    private var hasResolvedViewOptions = false
    @ObservationIgnored private var defaultViewOptions: ViewOptions?
    /// The guess shown before the pages are known; a different value then can only come from the user.
    @ObservationIgnored private let initialViewOptions: ViewOptions
    private let renderer: DocumentRenderer
    private var renderTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var printCompletion: PrintCompletion?
    private var printOperation: NSPrintOperation?
    private var exportingDocument: PDFDocument?

    init(
        data: Data, fileURL: URL?, format: DocumentFormat,
        preferences: AppPreferences, library: UserLibrary, renderer: DocumentRenderer = DocumentRenderer(),
        imageBundle: ImageBundleModel? = nil, settingsStore: DocumentSettingsStore? = nil
    ) {
        self.imageBundle = imageBundle
        self.settingsStore = settingsStore
        self.data = data
        self.fileURL = fileURL
        self.format = format
        self.preferences = preferences
        self.library = library
        self.renderer = renderer
        layoutID = Self.defaultLayoutID(preferences)
        themeID = Self.defaultThemeID(preferences, library)
        presetID = Self.defaultPresetID(preferences, library)
        printOptions = preferences.printOptions
        // A guess until the pages are known; most documents have more than two pages.
        let guess = ViewOptions.defaults(
            for: ViewDefaultsContext(
                kind: Self.viewKind(format: format, isBundle: imageBundle != nil), pageCount: 3,
                firstPageSize: PaperSize.a4.size))
        viewOptions = guess
        initialViewOptions = guess
        #if DEBUG
            DebugSnapshot.configure(self)
        #endif
    }

    var sourceURLs: [URL] { imageBundle?.urls ?? [fileURL].compactMap { $0 } }
    var protectedSourceURLs: [URL] {
        NSDocumentController.shared.documents.compactMap(\.fileURL)
            + ImageBundleWindows.shared.sourceURLs + sourceURLs
    }
    var exportName: String {
        imageBundle?.exportName(layout: renderedSettings?.layout ?? layout, language: language)
            ?? Self.exportName(fileURL: fileURL, layout: renderedSettings?.layout ?? layout, language: language)
    }
    var displayName: String {
        imageBundle?.title(language: language) ?? fileURL?.lastPathComponent ?? String(localized: "Document")
    }
    /// "MD", "PDF", "ZIP"…; "IMG" for a bundle of image files.
    var formatBadge: String { imageBundle == nil || format == .zipArchive ? format.badge : "IMG" }

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
            layout: layout, theme: theme, preset: preset, options: printOptions,
            allowsJavaScriptInHTML: preferences.allowsJavaScript)
    }
    var canOutput: Bool {
        result != nil && !isRendering && !isPrinting && !isExporting && error == nil
            && renderedSettings == renderSettings && renderedSourceURLs == sourceURLs
    }
    var summary: String? {
        guard let result, let renderedSettings else { return nil }
        return Self.summaryText(result.summary, layout: renderedSettings.layout, locale: Locale(identifier: language))
    }
    var pageCount: Int { result?.logicalDocument.pageCount ?? 0 }
    var displayUnits: [DisplayUnit] {
        SpreadLayout.units(
            pageCount: pageCount, layout: viewOptions.layout, showsCoverAlone: viewOptions.showsCoverAlone,
            direction: viewOptions.direction)
    }
    /// "3 / 12" for a page, "2–3 / 12" for a spread.
    var pageIndicator: String? {
        guard pageCount > 0 else { return nil }
        let units = displayUnits
        let pages =
            SpreadLayout.unitIndex(containing: currentPageIndex + 1, in: units).map { units[$0].pages }
            ?? [currentPageIndex + 1]
        let shown = pages.count > 1 ? "\(pages[0])–\(pages[pages.count - 1])" : "\(pages[0])"
        return "\(shown) / \(pageCount)"
    }

    func start() {
        if watcher == nil, let fileURL {
            watcher = FileWatcher(url: fileURL) { [weak self] event in
                guard let self, self.watcher != nil else { return }
                switch event {
                case .changed: reload()
                case .removed:
                    showToast(
                        Toast(
                            systemImage: "exclamationmark.triangle",
                            title: String(localized: "The file is missing. The last preview is still available.")),
                        dismissAfter: nil)
                }
            }
        }
        if let imageBundle, imageBundle.archiveURL != nil, !hasShownArchiveSummary, openFailure == nil {
            hasShownArchiveSummary = true
            let excluded = imageBundle.excludedSummary
            showToast(
                Toast(
                    systemImage: "photo.on.rectangle",
                    title: String(format: String(localized: "Opened %lld images"), imageBundle.items.count),
                    detail: excluded.isEmpty
                        ? nil
                        : String(
                            format: String(localized: "%lld non-image files excluded (%@)"),
                            imageBundle.excludedPaths.count, ListFormatter.localizedString(byJoining: excluded))))
        }
        computeContentHash()
        render()
    }

    /// A document that cannot be opened at all, such as an encrypted ZIP, shows the reason instead of pages.
    func failToOpen(_ message: String) {
        openFailure = message
        error = message
    }

    func stop() {
        renderTask?.cancel()
        toastTask?.cancel()
        hashTask?.cancel()
        if saveTask != nil { saveSettings() }
        watcher?.stop()
        watcher = nil
    }

    func reload() {
        if imageBundle?.archiveURL != nil, fileURL != nil {
            // The images of a ZIP were read when it opened; its window cannot swap in another archive.
            showToast(
                Toast(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: String(localized: "This ZIP archive changed. Close and reopen it to see the new images.")),
                dismissAfter: nil)
            return
        }
        renderTask?.cancel()
        renderer.clearCache()
        imageBundle?.clearCache()
        if let fileURL {
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                isRendering = false
                showToast(
                    Toast(
                        systemImage: "exclamationmark.triangle",
                        title: String(
                            localized: "The file could not be reloaded. The last preview is still available."),
                        detail: error.localizedDescription),
                    dismissAfter: nil)
                return
            }
        }
        computeContentHash()
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
        if let openFailure {
            error = openFailure
            isRendering = false
            return
        }
        guard let settings = renderSettings else {
            error = String(localized: "Print styles could not be loaded. Reload them in Settings.")
            isRendering = false
            return
        }
        error = nil
        isRendering = true
        let sourceURLs = sourceURLs
        let singleSource = DocumentSource(data: data, fileURL: fileURL, format: format)
        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source: DocumentSource
                if let imageBundle {
                    source = try await imageBundle.source()
                    // The digests and the key of their set change together, so nothing is saved under a mixed state.
                    if imageBundle.archiveURL == nil, let hash = imageBundle.setHash { didComputeHash(hash) }
                } else {
                    source = singleSource
                }
                let output = try await renderer.render(source, settings: settings)
                try Task.checkCancellation()
                result = output
                renderedSettings = settings
                renderedSourceURLs = sourceURLs
                unreadableImageURLs = output.unreadableImageURLs
                resolveViewOptionsIfNeeded(for: output.logicalDocument)
                if let imageBundle {
                    // The digests of the images are known now, so a remembered order can be restored.
                    if let order = pendingImageOrder {
                        pendingImageOrder = nil
                        // Restoring the remembered order is part of opening the document, not a change to save.
                        if imageBundle.applyOrder(order) { settingsBaseline = rememberedSettings }
                    }
                }
                isRendering = false
                retriedChangedImages = false
            } catch is CancellationError {
                // A superseding request owns the progress indicator.
            } catch DocumentRenderer.RenderingError.imageChanged where !retriedChangedImages && imageBundle != nil {
                guard !Task.isCancelled else { return }
                // An image was edited after it was hashed: hash the images again, which carries the settings over to
                // the new set, and draw again. A second change in a row is reported below instead of looping.
                retriedChangedImages = true
                imageBundle?.clearCache()
                render()
            } catch {
                guard !Task.isCancelled else { return }
                if case DocumentRenderer.RenderingError.noReadableImages(let urls) = error {
                    unreadableImageURLs = urls
                }
                self.error = Self.message(for: error)
                isRendering = false
            }
        }
    }

    // MARK: - View mode

    func setLayout(_ layout: ViewOptions.Layout) { updateViewOptions { $0.layout = layout } }

    /// Applies a change the user made; the defaults picked once the pages are known no longer replace it.
    func updateViewOptions(_ change: (inout ViewOptions) -> Void) {
        var options = viewOptions
        change(&options)
        hasResolvedViewOptions = true
        viewOptions = options.normalized()
    }

    func enterPrintMode() {
        guard mode != .print else { return }
        isViewOptionsPresented = false
        viewPaperSizeBeforePrinting = currentPaperSize ?? viewPaperSizeBeforePrinting
        mode = .print
        guard let window else { return }
        // The tray has its own size and always shows the traffic lights.
        ViewerWindow.unlockAspectRatio(of: window)
        ViewerWindow.setTrafficLightsVisible(true, in: window)
        PrintModeWindow.enter(window)
    }

    func exitPrintMode() {
        guard mode != .view else { return }
        guard let window else {
            mode = .view
            return
        }
        PrintModeWindow.exit(window) { [weak self] in
            guard let self else { return }
            // Back at the view-mode frame; the print layout may have changed the pages' shape meanwhile.
            ViewerWindow.markResizing(window, for: 0.3)
            mode = .view
            ViewerWindow.setTrafficLightsVisible(isMenuPinned, in: window)
            sizeWindowToPaper(keepHeight: true)
        }
    }

    func toggleMenuPinned() { isMenuPinned.toggle() }
    func toggleAlwaysOnTop() { isAlwaysOnTop.toggle() }

    /// Picks the reading layout once the pages are known, unless the user already chose one for this document.
    private func resolveViewOptionsIfNeeded(for document: PDFDocument) {
        guard defaultViewOptions == nil else { return }
        let defaults = ViewOptions.defaults(for: viewDefaultsContext(for: document))
        defaultViewOptions = defaults
        if !hasResolvedViewOptions {
            hasResolvedViewOptions = true
            viewOptions = defaults
        }
        guard !hasSavedSettings else { return }
        // Now that the defaults are complete, whatever differs from them was chosen by the user.
        settingsBaseline = defaultSettings
        rememberedSettingsDidChange()
    }

    func viewDefaultsContext(for document: PDFDocument) -> ViewDefaultsContext {
        let size = document.page(at: 0).map { page -> CGSize in
            let bounds = page.bounds(for: .cropBox)
            return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        }
        // A PDF can say how it wants to be shown (for example a right-to-left book).
        let hints = format == .pdf && imageBundle == nil ? PDFViewerHints.read(from: document) : PDFViewerHints()
        return ViewDefaultsContext(
            kind: Self.viewKind(format: format, isBundle: imageBundle != nil), pageCount: document.pageCount,
            firstPageSize: size ?? PaperSize.a4.size, pdfPageLayout: hints.pageLayout, pdfDirection: hints.direction)
    }

    static func viewKind(format: DocumentFormat, isBundle: Bool) -> ViewDefaultsContext.Kind {
        if isBundle { return .imageBundle }
        switch format {
        case .pdf: return .pdf
        case .image: return .image
        case .zipArchive: return .imageBundle
        case .markdown, .org, .plainText, .html, .csv: return .flowingText
        }
    }

    // MARK: - Remembered settings

    private static let logger = Logger(subsystem: "io.github.phyten.Surimono", category: "DocumentSettings")

    /// What is remembered for this document by its content. The window size is added when saving, because a resize is
    /// only a change once it ends.
    var rememberedSettings: DocumentSettings {
        DocumentSettings(
            view: viewOptions, zoom: (zoom * 100).rounded() / 100, layoutID: layoutID,
            themeID: format.usesPrintTheme ? themeID : nil, presetID: format.usesHTMLPreset ? presetID : nil,
            printOptions: printOptions,
            imageOrder: imageBundle.flatMap { $0.isSortedByName ? nil : $0.orderDigests })
    }

    /// What this document has when the user changes nothing. Until the pages are known, the reading layout is the
    /// initial guess, so a layout chosen while the pages are prepared still counts as a change.
    private var defaultSettings: DocumentSettings {
        DocumentSettings(
            view: defaultViewOptions ?? initialViewOptions, zoom: 1, layoutID: Self.defaultLayoutID(preferences),
            themeID: format.usesPrintTheme ? Self.defaultThemeID(preferences, library) : nil,
            presetID: format.usesHTMLPreset ? Self.defaultPresetID(preferences, library) : nil,
            printOptions: preferences.printOptions)
    }

    private static func defaultLayoutID(_ preferences: AppPreferences) -> String {
        PrintLayout.presets.contains(where: { $0.id == preferences.layoutID })
            ? preferences.layoutID : PrintLayout.a4Single.id
    }

    private static func defaultThemeID(_ preferences: AppPreferences, _ library: UserLibrary) -> String {
        library.themes.contains(where: { $0.id == preferences.themeID }) ? preferences.themeID : "standard"
    }

    private static func defaultPresetID(_ preferences: AppPreferences, _ library: UserLibrary) -> String {
        library.presets.contains(where: { $0.id == preferences.presetID }) ? preferences.presetID : "none"
    }

    /// Single files and ZIPs are keyed by their bytes; a bundle of image files once its images are read.
    private func computeContentHash() {
        guard imageBundle == nil || imageBundle?.archiveURL != nil else { return }
        hashTask?.cancel()
        let data = data
        hashTask = Task { [weak self] in
            let hash = await Task.detached(priority: .userInitiated) { ContentHash.of(data) }.value
            guard !Task.isCancelled else { return }
            self?.didComputeHash(hash)
        }
    }

    private func didComputeHash(_ hash: ContentHash) {
        let previous = contentHash
        guard previous != hash else { return }
        contentHash = hash
        if previous != nil {
            // Saved in an editor while open: the settings on screen carry over to the new content.
            if hasSavedSettings { saveSettings() }
            return
        }
        guard let saved = settingsStore?.record(for: hash.hex) else {
            // Anything that already differs from the defaults was changed by the user while the content was read.
            settingsBaseline = defaultSettings
            rememberedSettingsDidChange()
            return
        }
        apply(saved)
        hasSavedSettings = true
        settingsBaseline = rememberedSettings
        showToast(
            Toast(
                systemImage: "checkmark.circle", title: String(localized: "Restored the previous view settings"),
                detail: String(format: String(localized: "Content sha256 %@…"), hash.abbreviated),
                action: .resetDocumentSettings),
            dismissAfter: .seconds(6))
    }

    private func apply(_ saved: DocumentSettings) {
        if let view = saved.view {
            viewOptions = view.normalized()
            hasResolvedViewOptions = true
        }
        if let zoom = saved.zoom { self.zoom = min(max(zoom, 1), PaperPDFView.maximumZoom) }
        if let id = saved.layoutID, PrintLayout.presets.contains(where: { $0.id == id }) { layoutID = id }
        if let id = saved.themeID, library.themes.contains(where: { $0.id == id }) { themeID = id }
        if let id = saved.presetID, library.presets.contains(where: { $0.id == id }) { presetID = id }
        if let options = saved.printOptions { printOptions = options }
        if let order = saved.imageOrder, let imageBundle, !imageBundle.applyOrder(order) {
            // The images of a ZIP are hashed while they render; restore the order then.
            pendingImageOrder = order
        }
        if let size = saved.windowSize, size.width > 0, size.height > 0 {
            restoredPaperSize = size
            if hasSizedWindow { applyRestoredPaperSize() }
        }
    }

    /// Saves shortly after the user changes something remembered for this document.
    func rememberedSettingsDidChange() {
        guard contentHash != nil, let settingsBaseline, rememberedSettings != settingsBaseline else { return }
        scheduleSave()
    }

    private func scheduleSave() {
        guard settingsStore != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.saveSettings()
        }
    }

    private func saveSettings(force: Bool = false) {
        saveTask?.cancel()
        saveTask = nil
        guard let contentHash, let settingsStore else { return }
        // A change that was undone before the save (for example a transient zoom) is not a change.
        guard force || hasSavedSettings || rememberedSettings != settingsBaseline || didResizeWindow else { return }
        var settings = rememberedSettings
        settings.windowSize = currentPaperSize ?? viewPaperSizeBeforePrinting ?? restoredPaperSize
        do {
            try settingsStore.save(settings, for: contentHash.hex)
            hasSavedSettings = true
            didResizeWindow = false
            settingsBaseline = rememberedSettings
        } catch {
            Self.logger.error("Saving document settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resetDocumentSettings() {
        dismissToast()
        saveTask?.cancel()
        saveTask = nil
        if let contentHash { try? settingsStore?.removeRecord(for: contentHash.hex) }
        hasSavedSettings = false
        pendingImageOrder = nil
        restoredPaperSize = nil
        layoutID = Self.defaultLayoutID(preferences)
        themeID = Self.defaultThemeID(preferences, library)
        presetID = Self.defaultPresetID(preferences, library)
        printOptions = preferences.printOptions
        zoom = 1
        imageBundle?.sortByName()
        if let defaultViewOptions { viewOptions = defaultViewOptions }
        if mode == .view, let window, let unit = paperUnitSize {
            ViewerWindow.setPaperSize(
                ViewerWindow.initialPaperSize(unit: unit, on: window.screen), band: bandInset, of: window,
                animate: true)
        }
        settingsBaseline = rememberedSettings
    }

    // MARK: - Window geometry

    /// One page, or a spread, at 100 %.
    var paperUnitSize: CGSize? {
        guard let document = result?.logicalDocument, document.pageCount > 0 else { return nil }
        let page = (0..<document.pageCount).reduce(into: CGSize.zero) { size, index in
            guard let page = document.page(at: index) else { return }
            let bounds = page.bounds(for: .cropBox)
            let pageSize =
                page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
            size = CGSize(width: max(size.width, pageSize.width), height: max(size.height, pageSize.height))
        }
        guard page.width > 0, page.height > 0 else { return nil }
        return viewOptions.layout == .single ? page : CGSize(width: page.width * 2, height: page.height)
    }

    private var bandInset: CGFloat { isMenuPinned ? ViewerWindow.bandHeight : 0 }

    private var currentPaperSize: CGSize? {
        guard mode == .view, let window else { return nil }
        let content = window.contentRect(forFrameRect: window.frame).size
        return CGSize(width: content.width.rounded(), height: (content.height - bandInset).rounded())
    }

    /// Fits the window to the paper: the first time at a comfortable or remembered size, later keeping the height.
    func sizeWindowToPaper(keepHeight: Bool = false) {
        guard mode == .view, let window, let unit = paperUnitSize else { return }
        guard hasSizedWindow else {
            hasSizedWindow = true
            if restoredPaperSize != nil {
                applyRestoredPaperSize()
            } else {
                ViewerWindow.setPaperSize(
                    ViewerWindow.initialPaperSize(unit: unit, on: window.screen), band: bandInset, of: window,
                    animate: false)
            }
            return
        }
        let height = ViewerWindow.paperHeight(of: window, band: bandInset)
        ViewerWindow.setPaperSize(
            CGSize(width: (height * unit.width / unit.height).rounded(), height: height), band: bandInset,
            of: window, animate: keepHeight)
    }

    private func applyRestoredPaperSize() {
        guard let window, let unit = paperUnitSize, let size = restoredPaperSize else { return }
        // Keep the remembered height; the width follows the pages as they are now.
        ViewerWindow.setPaperSize(
            CGSize(width: (size.height * unit.width / unit.height).rounded(), height: size.height), band: bandInset,
            of: window, animate: false)
    }

    func updateBand(pinned: Bool, wasPinned: Bool) {
        guard mode == .view, let window, let unit = paperUnitSize else { return }
        ViewerWindow.setBand(
            pinned ? ViewerWindow.bandHeight : 0, previous: wasPinned ? ViewerWindow.bandHeight : 0, of: window,
            unit: unit)
    }

    func windowDidEndLiveResize() {
        guard mode == .view, let window, !ViewerWindow.isResizingProgrammatically(window), let unit = paperUnitSize
        else { return }
        if bandInset > 0 {
            // While the band is pinned the aspect ratio can only approximate "paper plus a fixed band"; settle on the
            // exact size for the width the user chose.
            let width = window.contentRect(forFrameRect: window.frame).width
            ViewerWindow.setPaperSize(
                CGSize(width: width, height: (width * unit.height / unit.width).rounded()), band: bandInset,
                of: window, animate: false)
        } else {
            ViewerWindow.lockAspectRatio(of: window, unit: unit, band: bandInset)
        }
        guard contentHash != nil, settingsBaseline != nil else { return }
        didResizeWindow = true
        scheduleSave()
    }

    // MARK: - Toasts

    func showToast(_ toast: Toast, dismissAfter delay: Duration? = .seconds(5)) {
        toastTask?.cancel()
        self.toast = toast
        guard let delay else { return }
        let id = toast.id
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            if self?.toast?.id == id { self?.toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: - Output

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
                showToast(
                    Toast(
                        systemImage: success ? "printer" : "exclamationmark.triangle",
                        title: success
                            ? String(format: String(localized: "Sent to %@"), printer)
                            : String(localized: "The print job was cancelled or could not be sent.")))
            }
        }
        printCompletion = completion
        printOperation = operation
        operation.runModal(
            for: window, delegate: completion,
            didRun: #selector(PrintCompletion.didRun(_:success:context:)), contextInfo: nil)
    }

    func exportPDF() {
        guard let window, beginPDFExport() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = exportName
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
            let sources = protectedSourceURLs
            guard Self.canExport(to: url, sourceURLs: sources) else { throw CocoaError(.fileWriteNoPermission) }
            guard let data = exportingDocument.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        } catch {
            outputError = String(localized: "The PDF could not be exported.") + "\n" + error.localizedDescription
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
        case .noReadableImages: return String(localized: "None of the images could be opened.")
        case .imageChanged: return String(localized: "The images keep changing. Try reloading the document.")
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
