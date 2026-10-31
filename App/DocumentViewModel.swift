import AppKit
import OSLog
import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering

/// The window shows the paper, the print tray, or the comparison stage of print themes.
enum ViewerMode { case view, print, compare }

typealias DocumentSettingsStore = KeyedRecordStore<DocumentSettings>

/// A short message near the bottom of the window, optionally with one action.
struct Toast: Equatable, Identifiable {
    enum Action: Equatable { case resetDocumentSettings, reviewSmartRemoval, retryWebCapture }

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
    var paperOrientation: PaperOrientation = .auto
    var layoutID: String
    /// Set directly only when restoring or falling back; a theme the user picks goes through `selectTheme(_:)`.
    var themeID: String
    private(set) var textScale: Double = 1
    var presetID: String
    var printOptions: PrintOptions
    var mode: ViewerMode = .view
    private let openingViewDefaults: ViewDefaultPreferences
    var viewOptions: ViewOptions
    /// Magnification relative to fitting the current page or spread into the window.
    var zoom: Double = 1
    /// The 0-based index of the first visible logical page.
    var currentPageIndex = 0
    var isMenuPinned = false
    var isAlwaysOnTop = false
    var isDrawerOpen = false
    /// Dragging the paper selects text instead of moving the window. It belongs to the window and is never saved, so
    /// a document always opens with the paper as the window and a drag never selects text by surprise.
    var isSelectingText = false
    var isViewOptionsPresented = false
    /// The style palette is open beside the paper.
    var isThemePalettePresented = false
    /// The first page of the document in each theme, for the palette and the comparison stage.
    let themeSamples = ThemeSamples()
    /// The theme the pointer rests on in the palette, laid out on the paper.
    let themeTrial: ThemeTrial
    /// A trial the user then chose: the paper keeps it until the document's own pages in that theme are ready.
    private(set) var chosenTrial: (themeID: String, document: PDFDocument)?
    /// The candidates on the comparison stage, kept while the window lives.
    var themeComparison: ThemeComparison?
    /// How long the last fresh layout of the logical pages took. A long document is not laid out again on hover.
    @ObservationIgnored private(set) var lastLayoutDuration: Duration?
    /// A trial longer than this to lay out would trail the pointer, so longer documents switch on click only.
    @ObservationIgnored var hoverTrialLimit: Duration = .milliseconds(1500)
    /// HTML opens as a live web page; paper shows how it prints.
    private(set) var htmlPresentation: HTMLPresentation = .web
    /// The web page's own zoom, apart from the paper's.
    var webZoom: Double = 1
    /// The live page is being copied for paper or printing.
    private(set) var isCapturingWeb = false
    /// The last copy of the live page failed, so the pages on paper may show an earlier state and do not print.
    private(set) var webCaptureFailed = false
    /// The tray's 「最初の状態で刷る」: print the page as the file opens instead of its current state. It belongs to the
    /// visit to the tray and is never saved.
    private(set) var printsOriginalPage = false
    /// The tray's 「開いて刷る」: open the details the copy of the live page has closed. Never saved.
    private(set) var opensClosedDetails = false
    /// The slide deck the live page looks like, as last measured; nil for an ordinary page.
    private(set) var detectedSlideDeck: SlideDeck?
    /// 「スライドとして扱わない」: the reader says the page is not a deck. Remembered for the document.
    private(set) var ignoresSlides = false
    /// The tray's 「今の 1 枚」: print only the slide shown on the web. It belongs to the visit to the tray.
    private(set) var printsCurrentSlideOnly = false
    /// Smart Removal (beta) for HTML: remove what is not the article, except the parts the user keeps.
    var isSmartRemovalEnabled = false
    var smartRemovalKeptIDs: [String] = []
    /// While reviewing, the paper outlines the detected parts instead of removing them.
    private(set) var isReviewingSmartRemoval = false
    /// An output asked for during the review; it runs once the pages without the outlines are drawn.
    @ObservationIgnored private(set) var outputAfterReview: Output?
    var toast: Toast?
    /// The logical pages the paper shows. They are published before the sheets are composed.
    private(set) var result: PreparedRender?
    /// The composed sheets for the tray and the outputs. It may still belong to an earlier `result` while the sheets
    /// of the current one are composed; `canOutput` checks that it matches.
    private(set) var printResult: RenderResult?
    /// The sheets of `printResult`, grouped as they come out of the printer; built once per composition.
    private(set) var printTray: PrintTray?
    private(set) var renderedSettings: RenderSettings?
    private(set) var isRendering = false
    private(set) var isPrinting = false
    /// The printers the tray offers; refreshed when the tray opens and before each print.
    private(set) var printers = PrinterList.empty
    private(set) var isExporting = false
    var error: String?
    var outputError: String?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored let paper = PaperController()
    @ObservationIgnored let web = WebPageController()
    /// The live page's state as last copied; paper and printing are made from it instead of the file.
    private var liveSnapshot: HTMLSnapshot?
    /// Whether the pages shown were made from the copy of the live page rather than the file.
    private var renderedFromSnapshot = false
    /// Set while an output that waited for the copy of the live page runs, so that it does not wait again.
    @ObservationIgnored private var isRunningCapturedOutput = false
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    /// Everyone waiting for the copy in flight: switching to paper, the print tray, and outputs.
    @ObservationIgnored private var captureCompletions: [(CaptureOutcome) -> Void] = []
    /// Stands in for the live page in tests.
    @ObservationIgnored var snapshotSource: (() async -> WebPageController.Snapshot)?
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
    @ObservationIgnored private var announcesSmartRemoval = false
    @ObservationIgnored private var hasShownArchiveSummary = false
    private var hasResolvedViewOptions = false
    @ObservationIgnored private var defaultViewOptions: ViewOptions?
    /// The guess shown before the pages are known; a different value then can only come from the user.
    @ObservationIgnored private let initialViewOptions: ViewOptions
    private let renderer: DocumentRenderer
    private var renderTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    @ObservationIgnored private var textSizeKeyMonitor: Any?
    private var printCompletion: PrintCompletion?
    private var printOperation: NSPrintOperation?
    private var exportingDocument: PDFDocument?

    init(
        data: Data, fileURL: URL?, format: DocumentFormat,
        preferences: AppPreferences, library: UserLibrary, renderer: DocumentRenderer = DocumentRenderer(),
        imageBundle: ImageBundleModel? = nil, settingsStore: DocumentSettingsStore? = nil,
        trialRenderer: DocumentRenderer = DocumentRenderer()
    ) {
        themeTrial = ThemeTrial(renderer: trialRenderer)
        self.imageBundle = imageBundle
        self.settingsStore = settingsStore
        self.data = data
        self.fileURL = fileURL
        self.format = format
        self.preferences = preferences
        openingViewDefaults = preferences.viewDefaults
        self.library = library
        self.renderer = renderer
        layoutID = Self.defaultLayoutID(preferences)
        themeID = Self.defaultThemeID(preferences, library)
        presetID = Self.defaultPresetID(preferences, library)
        printOptions = preferences.printOptions
        // A guess until the pages are known; most documents have more than two pages.
        let guess = ViewOptions.resolved(
            for: ViewDefaultsContext(
                kind: Self.viewKind(format: format, isBundle: imageBundle != nil), pageCount: 3,
                firstPageSize: PaperSize.a4.size), preferences: preferences.viewDefaults)
        viewOptions = guess
        initialViewOptions = guess
        themeSamples.inputs = { [weak self] in (self?.themedSource, self?.renderSettings) }
        #if DEBUG
            DebugSnapshot.configure(self)
        #endif
    }

    var sourceURLs: [URL] { imageBundle?.urls ?? [fileURL].compactMap { $0 } }
    /// The document as the print themes lay it out; nil for the formats that print without a theme.
    var themedSource: DocumentSource? {
        format.usesPrintTheme && imageBundle == nil ? DocumentSource(data: data, fileURL: fileURL, format: format) : nil
    }
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

    /// The user picked a print theme, so it also becomes the most recent one in every window's menu.
    func selectTheme(_ id: String) {
        // The pages of a trial of the same theme stay on the paper until the document's own are laid out.
        if id != themeID, themeTrial.themeID == id, let document = themeTrial.document {
            chosenTrial = (id, document)
        }
        themeTrial.end()
        themeComparison?.choose(id)
        themeID = id
        preferences.recordThemeChoice(id)
    }

    var isFavoriteTheme: Bool { preferences.favoriteThemeIDs.contains(themeID) }

    func toggleFavoriteTheme() {
        preferences.toggleFavoriteTheme(themeID)
    }

    var themeMenu: PrintThemeMenu {
        PrintThemeMenu(
            themes: library.themes, categories: library.themeCategories, recentIDs: preferences.recentThemeIDs,
            favoriteIDs: preferences.favoriteThemeIDs)
    }
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
            allowsJavaScriptInHTML: preferences.allowsJavaScript,
            smartRemoval: format == .html && isSmartRemovalEnabled
                ? SmartRemovalRequest(keptIDs: smartRemovalKeptIDs, highlightsCandidates: isReviewingSmartRemoval)
                : nil,
            textScale: format.usesPrintTheme ? textScale : 1, paperOrientation: paperOrientation,
            opensDetails: rendersSnapshot && opensClosedDetails,
            slides: slideDeck.map {
                SlidePrintRequest(deck: $0, printsCurrentOnly: mode == .print && printsCurrentSlideOnly)
            })
    }
    /// Paper and printing show the copy of the live page, unless there is none or the tray asks for the file.
    var rendersSnapshot: Bool { usesHTMLPresentation && liveSnapshot != nil && !printsOriginalPage }
    /// The tray tells what it prints when the page has a state of its own.
    var offersOriginalPage: Bool { usesHTMLPresentation && liveSnapshot != nil }
    /// The details the copy of the live page has closed, which print closed unless opened on the tray.
    var closedDetailsCount: Int { rendersSnapshot ? liveSnapshot?.closedDetailsCount ?? 0 : 0 }
    /// The pages shown were drawn from the current file and settings.
    var isUpToDate: Bool {
        result != nil && !isRendering && error == nil && renderedSettings == renderSettings
            && renderedSourceURLs == sourceURLs && renderedFromSnapshot == rendersSnapshot
    }
    /// The tray, "Fold It" and the sheet notes may show `printResult`: it was composed from the logical pages in
    /// `result`, so nothing on the tray mixes two renders. While the sheets of newer logical pages are composed, or
    /// after their composition failed, the tray shows the progress or the error instead. A render that has not yet
    /// published new logical pages keeps the previous, consistent preview, so a change on the tray does not blank it.
    /// The tray labels its pages with the current file names, so a reordered or changed set of images hides the
    /// previous preview too. Printing and saving do not hide the preview; `canOutput` checks those.
    var hasCurrentPrintPreview: Bool {
        error == nil && result != nil && printResult?.id == result?.id && renderedSourceURLs == sourceURLs
            && renderedSettings?.smartRemoval?.highlightsCandidates != true
    }
    /// The review's outlined pages are for the screen only and never reach the printer or a PDF.
    var canOutput: Bool {
        isUpToDate && hasCurrentPrintPreview && !isPrinting && !isExporting && !isCapturingWeb && !webCaptureFailed
    }
    var summary: String? {
        guard let result, let renderedSettings else { return nil }
        return Self.summaryText(result.summary, layout: renderedSettings.layout, locale: Locale(identifier: language))
    }
    var pageCount: Int { result?.logicalDocument.pageCount ?? 0 }
    var smartRemovalCandidates: [SmartRemovalCandidate] { result?.smartRemovalCandidates ?? [] }
    var removedPartCount: Int { smartRemovalCandidates.filter { !smartRemovalKeptIDs.contains($0.id) }.count }
    var displayUnits: [DisplayUnit] {
        SpreadLayout.units(
            pageCount: pageCount, layout: viewOptions.layout, showsCoverAlone: viewOptions.showsCoverAlone,
            direction: viewOptions.direction)
    }
    /// "3 / 12" for a page, "2–3 / 12" for a spread; "Slide 3 of 6" for a slide deck on the web.
    var pageIndicator: String? {
        if showsWeb {
            guard let slideDeck else { return nil }
            return Self.slideIndicator(slideDeck.currentIndex + 1, of: slideDeck.count)
        }
        guard pageCount > 0 else { return nil }
        let units = displayUnits
        let pages =
            SpreadLayout.unitIndex(containing: currentPageIndex + 1, in: units).map { units[$0].pages }
            ?? [currentPageIndex + 1]
        return PageIndicator.text(pages: pages, pageCount: pageCount)
    }

    /// The widest page indicator of this document, whose width the band keeps for the indicator.
    var pageIndicatorTemplate: String? {
        if showsWeb {
            guard let slideDeck else { return nil }
            return Self.slideIndicator(slideDeck.count, of: slideDeck.count)
        }
        guard pageCount > 0 else { return nil }
        return PageIndicator.widestText(pageCount: pageCount, layout: viewOptions.layout)
    }

    func start() {
        web.onZoomChange = { [weak self] zoom in self?.webZoom = zoom }
        web.onPrintRequest = { [weak self] in self?.pageDidRequestPrint() }
        web.onSlideDeckChange = { [weak self] deck in self?.slideDeckDidChange(deck) }
        web.onRestart = { [weak self] in
            guard let self else { return }
            cancelCapture()
            liveSnapshot = nil
            slideDeckDidChange(nil)
            // Pages of the old copy would no longer count as up to date, so they are made from the file again.
            if renderedFromSnapshot { render() }
        }
        if textSizeKeyMonitor == nil {
            textSizeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                        window.isKeyWindow, window.attachedSheet == nil
                    else { return false }
                    return self.handleTextSizeKey(event)
                }
                return handled ? nil : event
            }
        }
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
        if let textSizeKeyMonitor { NSEvent.removeMonitor(textSizeKeyMonitor) }
        textSizeKeyMonitor = nil
        renderTask?.cancel()
        toastTask?.cancel()
        hashTask?.cancel()
        if saveTask != nil { saveSettings() }
        watcher?.stop()
        watcher = nil
        cancelCapture()
        web.close()
        themeTrial.end()
        themeSamples.invalidate()
    }

    func reload() {
        reload(reloadsWeb: true)
    }

    private func reload(reloadsWeb: Bool) {
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
        themeTrial.clear()
        themeSamples.invalidate()
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
        if reloadsWeb {
            // The page starts over from the new file, and paper follows it; a copy of the old page is not used.
            cancelCapture()
            liveSnapshot = nil
            web.reload()
            webZoom = web.zoom
        }
        computeContentHash()
        render()
    }

    func reloadLibrary() {
        if !library.themes.contains(where: { $0.id == themeID }) { themeID = "standard" }
        if !library.presets.contains(where: { $0.id == presetID }) { presetID = "none" }
        reload(reloadsWeb: false)
    }

    func reopenAsText() {
        format = .plainText
        renderer.clearCache()
        themeTrial.clear()
        themeSamples.invalidate()
        render()
    }

    func render() {
        renderTask?.cancel()
        // A trial was laid out under the previous settings or file.
        themeTrial.end()
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
        let fromSnapshot = rendersSnapshot
        let singleSource =
            fromSnapshot
            ? DocumentSource.liveSnapshot(liveSnapshot?.html ?? "", of: fileURL)
            : DocumentSource(data: data, fileURL: fileURL, format: format)
        let started = ContinuousClock.now
        let layoutsBefore = renderer.logicalRenderCount
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
                let prepared = try await renderer.prepare(source, settings: settings)
                try Task.checkCancellation()
                if renderer.logicalRenderCount != layoutsBefore { lastLayoutDuration = ContinuousClock.now - started }
                // The paper shows the logical pages right away; the sheets for the tray and the outputs follow.
                result = prepared
                chosenTrial = nil
                renderedSettings = settings
                renderedSourceURLs = sourceURLs
                renderedFromSnapshot = fromSnapshot
                unreadableImageURLs = prepared.unreadableImageURLs
                resolveViewOptionsIfNeeded(for: prepared.viewDocument)
                if let imageBundle {
                    // The digests of the images are known now, so a remembered order can be restored.
                    if let order = pendingImageOrder {
                        pendingImageOrder = nil
                        // Restoring the remembered order is part of opening the document, not a change to save.
                        if imageBundle.applyOrder(order) { settingsBaseline = rememberedSettings }
                    }
                }
                let output = try await renderer.composeSheet(for: prepared)
                try Task.checkCancellation()
                printResult = output
                printTray = PrintTray(
                    plan: output.plan, layout: output.layout, rotatesBackSides: settings.options.rotatesBackSides,
                    sheetOrientations: output.sheetOrientations)
                isRendering = false
                retriedChangedImages = false
                if announcesSmartRemoval, renderedSettings?.smartRemoval != nil {
                    announcesSmartRemoval = false
                    // The review panel shows the count itself.
                    if !isReviewingSmartRemoval {
                        showToast(
                            Toast(
                                systemImage: "wand.and.rays",
                                title: String(format: String(localized: "%lld parts removed"), removedPartCount),
                                detail: String(localized: "Smart Removal (Beta) runs on this Mac only."),
                                action: .reviewSmartRemoval))
                    }
                }
                // A render that a later change made stale leaves the output to the render that follows it.
                if let output = outputAfterReview, settings == renderSettings {
                    outputAfterReview = nil
                    run(output)
                }
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
                outputAfterReview = nil
                chosenTrial = nil
                isRendering = false
            }
        }
    }

    func setTextScale(_ value: Double) {
        guard format.usesPrintTheme, TextScale.steps.contains(value) else { return }
        textScale = value
    }

    func increaseTextSize() { setTextScale(TextScale.larger(than: textScale)) }
    func decreaseTextSize() { setTextScale(TextScale.smaller(than: textScale)) }
    func resetTextSize() { setTextScale(1) }

    static let marginRange: ClosedRange<Double> = 0...40
    static let marginPresets: [Double] = [0, 5, 10, 15, 20, 25]

    /// Only themed text guarantees blank margins. HTML may override them with @page rules, and the
    /// prepared pages do not expose that information here, so HTML keeps all its content like PDFs and images.
    var viewLogicalMargin: CGFloat? {
        guard imageBundle == nil, format.usesPrintTheme else { return nil }
        // Keep the margin attached to the pages still on screen while a new layout is being prepared.
        guard let settings = renderedSettings else { return nil }
        return CGFloat(settings.layout.logicalMarginsInMillimeters(options: settings.options) * 72 / 25.4)
    }

    /// Whether the margin shows on the pages view mode displays. PDFs keep their own margins, and the 3-up handout
    /// insets the sheet instead of its logical pages.
    var marginsApply: Bool { format != .pdf && layout.kind != .handout3 }

    /// Whether the margin changes the printed sheets: everything but PDFs, including the 3-up handout's sheet.
    var marginsAffectPrinting: Bool { format != .pdf }

    /// The presets, plus the current margin when it is none of them, so the menu always checks the current value.
    var marginChoices: [Double] {
        let current = printOptions.marginsInMillimeters
        return Self.marginPresets.contains(current) ? Self.marginPresets : (Self.marginPresets + [current]).sorted()
    }

    /// The one way the viewer and the tray change the margin, so both re-paginate and remember it the same way.
    func setMargins(_ millimeters: Double) {
        guard millimeters.isFinite else { return }
        // Tenths of a millimeter are as fine as the labels show, so two choices never read the same.
        let rounded = (millimeters * 10).rounded() / 10
        printOptions.marginsInMillimeters = min(max(rounded, Self.marginRange.lowerBound), Self.marginRange.upperBound)
    }

    /// The unshifted US key for ⌥⌘+ must work in both the viewer and the print tray, before PDFKit handles ⌘=.
    func handleTextSizeKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]) == [.option, .command],
            event.charactersIgnoringModifiers == "="
        else { return false }
        increaseTextSize()
        return true
    }

    // MARK: - View mode

    func setLayout(_ layout: ViewOptions.Layout) { updateViewOptions { $0.layout = layout } }

    /// Applies a change the user made; the defaults picked once the pages are known no longer replace it.
    func updateViewOptions(_ change: (inout ViewOptions) -> Void) {
        var options = viewOptions
        change(&options)
        hasResolvedViewOptions = true
        viewOptions = options
    }

    func enterPrintMode() {
        guard mode != .print else { return }
        guard mode == .view, isWebPresentation || webCaptureFailed else { return showPrintTray() }
        // The tray prints the page as it is now.
        captureWeb { [weak self] outcome in
            if outcome == .failed { self?.showCaptureFailure() } else { self?.showPrintTray() }
        }
    }

    private func showPrintTray() {
        guard mode != .print else { return }
        refreshPrinters()
        isViewOptionsPresented = false
        // The tray shows what prints, so the review and its outlined pages end here.
        isReviewingSmartRemoval = false
        viewPaperSizeBeforePrinting = currentPaperSize ?? viewPaperSizeBeforePrinting
        mode = .print
        guard let window else { return }
        // The tray has its own size and always shows the traffic lights.
        ViewerWindow.unlockAspectRatio(of: window)
        ViewerWindow.setTrafficLightsVisible(true, in: window)
        PrintModeWindow.enter(window)
    }

    /// The comparison stage (見比べ台): the window grows like the print tray's and comes back to its frame afterwards.
    func enterCompareMode() {
        guard mode == .view, format.usesPrintTheme else { return }
        isThemePalettePresented = false
        themeTrial.end()
        isViewOptionsPresented = false
        viewPaperSizeBeforePrinting = currentPaperSize ?? viewPaperSizeBeforePrinting
        let featured = library.themes.filter { $0.featuredRank != nil }
            .sorted { ($0.featuredRank ?? 0) < ($1.featuredRank ?? 0) }.map(\.id)
        if themeComparison?.current != themeID {
            // The theme chosen since leads; the latest choices of an earlier visit follow, before the suggestions.
            themeComparison = ThemeComparison(
                current: themeID, suggestions: (themeComparison?.candidates.reversed() ?? []) + featured)
        }
        mode = .compare
        guard let window else { return }
        ViewerWindow.unlockAspectRatio(of: window)
        ViewerWindow.setTrafficLightsVisible(true, in: window)
        PrintModeWindow.enter(window, size: PrintModeWindow.compareSize)
    }

    /// Back to the view mode, by the same way as from the print tray.
    func exitCompareMode() {
        guard mode == .compare else { return }
        exitPrintMode()
    }

    func exitPrintMode() {
        guard mode != .view else { return }
        guard let window else {
            resetPrintChoices()
            mode = .view
            return
        }
        resetPrintChoices()
        PrintModeWindow.exit(window) { [weak self] in
            guard let self else { return }
            // Back at the view-mode frame; the print layout may have changed the pages' shape meanwhile.
            ViewerWindow.markResizing(window, for: 0.3)
            mode = .view
            ViewerWindow.setTrafficLightsVisible(isMenuPinned, in: window)
            sizeWindowToPaper(keepHeight: true)
        }
    }

    /// The tray's choices of what to print last only while it is shown; paper then shows the current state again.
    private func resetPrintChoices() {
        opensClosedDetails = false
        printsCurrentSlideOnly = false
        guard printsOriginalPage else { return }
        printsOriginalPage = false
        render()
    }

    /// The tray's switch between the page as it is now and as the file opens.
    func setPrintsOriginalPage(_ original: Bool) {
        guard offersOriginalPage, printsOriginalPage != original else { return }
        printsOriginalPage = original
        render()
    }

    /// The tray's 「全部 / 今の 1 枚」 for a slide deck; the settings change draws the pages again.
    func setPrintsCurrentSlideOnly(_ currentOnly: Bool) {
        guard slideDeck != nil else { return }
        printsCurrentSlideOnly = currentOnly
    }

    /// The tray's 「開いて刷る」 and its undo; the settings change draws the pages again.
    func setOpensClosedDetails(_ opens: Bool) {
        guard usesHTMLPresentation else { return }
        opensClosedDetails = opens
    }

    /// The page called `window.print()`: open the print tray as ⌘P does. Only the page the reader is using may ask:
    /// not one behind paper or the tray, nor one in a window in the background, and a request while the page is
    /// being copied for the tray is already on its way there.
    func pageDidRequestPrint() {
        guard showsWeb, !isCapturingWeb, isWindowActive else { return }
        enterPrintMode()
    }

    /// The window is the one the reader works in; replaced in tests, whose windows never become key.
    @ObservationIgnored var windowActiveOverride: Bool?
    private var isWindowActive: Bool {
        windowActiveOverride ?? (window.map { $0.isVisible && $0.isKeyWindow } ?? false)
    }

    func setSmartRemoval(enabled: Bool) {
        guard isSmartRemovalEnabled != enabled else { return }
        isSmartRemovalEnabled = enabled
        announcesSmartRemoval = enabled
        if !enabled { isReviewingSmartRemoval = false }
    }

    /// The menus' "Review Removed Parts…" and the toast's "Review". The panel belongs to the view mode.
    func reviewSmartRemoval() {
        guard format == .html, isSmartRemovalEnabled else { return }
        dismissToast()
        // The review outlines parts of the paper.
        setHTMLPresentation(.paper)
        outputAfterReview = nil
        if mode == .print { exitPrintMode() }
        isReviewingSmartRemoval = true
    }

    func endSmartRemovalReview() { isReviewingSmartRemoval = false }

    func toggleKeep(_ id: String) {
        if let index = smartRemovalKeptIDs.firstIndex(of: id) {
            smartRemovalKeptIDs.remove(at: index)
        } else {
            smartRemovalKeptIDs.append(id)
        }
    }

    func toggleMenuPinned() { isMenuPinned.toggle() }

    // MARK: - Web or paper

    /// HTML from a file can show as a live page; other documents, and HTML without a file, show only as paper.
    var usesHTMLPresentation: Bool { format == .html && imageBundle == nil && fileURL != nil }
    var isWebPresentation: Bool { usesHTMLPresentation && htmlPresentation == .web }
    /// The live page is on screen.
    var showsWeb: Bool { mode == .view && isWebPresentation }

    /// ⌃⌘P: between the live page and paper. Only HTML in the view mode has the two.
    func toggleHTMLPresentation() {
        guard usesHTMLPresentation, mode == .view else { return }
        setHTMLPresentation(htmlPresentation == .web ? .paper : .web)
    }

    /// - Parameter capturesWeb: Whether paper shows the page as the reader left it. Restoring a remembered choice
    ///   while the document opens shows the file as it is.
    func setHTMLPresentation(_ presentation: HTMLPresentation, capturesWeb: Bool = true) {
        guard usesHTMLPresentation, presentation != htmlPresentation else { return }
        let wasWeb = isWebPresentation
        htmlPresentation = presentation
        guard window != nil else { return }
        if presentation == .web { return applyWebShape() }
        isViewOptionsPresented = false
        guard wasWeb, capturesWeb else { return sizeWindowToPaper(keepHeight: true) }
        captureWeb { [weak self] outcome in
            // Paper then shows the last copy, or the file.
            if outcome == .failed { self?.showCaptureFailure() }
            self?.sizeWindowToPaper(keepHeight: true)
        }
    }

    // MARK: - Slides

    /// The deck the app treats the page as: the one measured, unless the reader said it is not one.
    var slideDeck: SlideDeck? { usesHTMLPresentation && !ignoresSlides ? detectedSlideDeck : nil }

    static func slideIndicator(_ slide: Int, of count: Int) -> String {
        String(format: String(localized: "Slide %lld of %lld"), slide, count)
    }

    /// The live page was measured again. Only a new shape changes the window; turning slides changes the indicator.
    func slideDeckDidChange(_ deck: SlideDeck?) {
        let reshapes = !(deck?.hasSameShape(as: detectedSlideDeck) ?? (detectedSlideDeck == nil))
        detectedSlideDeck = deck
        if reshapes, !ignoresSlides { applyWebShape() }
    }

    /// The "…" and View menus' 「スライドとして扱わない」, for a page that only looks like a deck.
    func setIgnoresSlides(_ ignores: Bool) {
        guard usesHTMLPresentation, ignoresSlides != ignores else { return }
        ignoresSlides = ignores
        if ignores { printsCurrentSlideOnly = false }
        applyWebShape()
    }

    /// On the web a deck shows one slide to the window: the window takes the slide's shape, keeping its height, and
    /// the page zooms to fit unless the deck scales itself. An ordinary page takes any shape the reader gives it.
    func applyWebShape(animate: Bool = true) {
        web.fitSize = slideDeck.flatMap { $0.scalesItself ? nil : $0.size }
        guard showsWeb, let window else { return }
        guard let deck = slideDeck else { return ViewerWindow.unlockAspectRatio(of: window) }
        let size = ViewerWindow.paperSize(
            unit: deck.size, height: ViewerWindow.paperHeight(of: window, band: bandInset), on: window.screen)
        ViewerWindow.setPaperSize(size, band: bandInset, of: window, animate: animate)
    }

    enum CaptureOutcome: Equatable {
        /// The pages show the page's current state.
        case ready
        /// Pages of the current state are on the way.
        case rendering
        case failed
    }

    /// Copies the live page and makes paper from the copy. A request while a copy is in flight waits for the same copy.
    func captureWeb(_ completion: @escaping (CaptureOutcome) -> Void) {
        captureCompletions.append(completion)
        guard captureTask == nil else { return }
        isCapturingWeb = true
        captureTask = Task { [weak self] in
            guard let snapshot = await self?.takeSnapshot(), !Task.isCancelled, let self else { return }
            captureTask = nil
            isCapturingWeb = false
            let completions = captureCompletions
            captureCompletions = []
            webCaptureFailed = snapshot == .failed
            if case .captured(let copy) = snapshot, copy != liveSnapshot {
                liveSnapshot = copy
                // The pages of the previous state must not show or print in the meantime.
                result = nil
                printResult = nil
                printTray = nil
                render()
            }
            let outcome: CaptureOutcome = snapshot == .failed ? .failed : isRendering ? .rendering : .ready
            for completion in completions { completion(outcome) }
        }
    }

    private func takeSnapshot() async -> WebPageController.Snapshot {
        if let snapshotSource { return await snapshotSource() }
        return await web.snapshot()
    }

    /// A copy of a page that has since started over, or of a window that closed, must not replace what follows.
    private func cancelCapture() {
        captureTask?.cancel()
        captureTask = nil
        captureCompletions = []
        isCapturingWeb = false
        webCaptureFailed = false
    }

    /// The failure notice's Try Again: copy the page again and show paper from the new copy.
    func retryWebCapture() {
        dismissToast()
        guard usesHTMLPresentation, webCaptureFailed else { return }
        captureWeb { [weak self] outcome in
            if outcome == .failed { self?.showCaptureFailure() }
            self?.sizeWindowToPaper(keepHeight: true)
        }
    }

    /// The JavaScript setting changed in Settings; the kept page follows it even while it is not shown.
    func javaScriptSettingDidChange() {
        web.applyJavaScriptSetting(preferences.allowsJavaScript)
    }

    private func showCaptureFailure() {
        showToast(
            Toast(
                systemImage: "exclamationmark.triangle",
                title: String(localized: "The current state of the web page could not be copied."),
                action: .retryWebCapture),
            dismissAfter: nil)
    }

    /// An output asked for on the web, or while the page is being copied, waits for the copy and the pages made from
    /// it; it is dropped with a notice if the copy fails, so that nothing prints from an earlier state.
    private func deferUntilWebIsCaptured(_ output: Output) -> Bool {
        guard showsWeb || isCapturingWeb || webCaptureFailed, !isRunningCapturedOutput else { return false }
        captureWeb { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .failed: showCaptureFailure()
            case .rendering: outputAfterReview = output
            case .ready: run(output)
            }
        }
        return true
    }

    private func run(_ output: Output) {
        isRunningCapturedOutput = true
        defer { isRunningCapturedOutput = false }
        switch output {
        case .print(let quick): printDocument(quick: quick)
        case .exportPDF: exportPDF()
        }
    }

    func zoomIn() { if showsWeb { web.zoomIn() } else { paper.zoomIn() } }
    func zoomOut() { if showsWeb { web.zoomOut() } else { paper.zoomOut() } }
    func zoomToFit() { if showsWeb { web.resetZoom() } else { paper.zoomToFit() } }

    /// Images carry no text to select.
    var canSelectText: Bool { imageBundle == nil && format != .image }

    func toggleSelectingText() {
        guard canSelectText else { return }
        isSelectingText.toggle()
    }
    func toggleAlwaysOnTop() { isAlwaysOnTop.toggle() }

    /// Picks the reading layout once the pages are known, unless the user already chose one for this document.
    private func resolveViewOptionsIfNeeded(for document: PDFDocument) {
        guard defaultViewOptions == nil else { return }
        let defaults = ViewOptions.resolved(for: viewDefaultsContext(for: document), preferences: openingViewDefaults)
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
        case .markdown, .org, .plainText, .html, .csv, .latex: return .flowingText
        }
    }

    // MARK: - Remembered settings

    private static let logger = Logger(subsystem: "io.github.phyten.Surimono", category: "DocumentSettings")

    /// What is remembered for this document by its content. The window size is added when saving, because a resize is
    /// only a change once it ends.
    var rememberedSettings: DocumentSettings {
        DocumentSettings(
            view: viewOptions, zoom: (zoom * 100).rounded() / 100, layoutID: layoutID,
            themeID: format.usesPrintTheme ? themeID : nil,
            textScale: format.usesPrintTheme ? textScale : nil, presetID: format.usesHTMLPreset ? presetID : nil,
            smartRemoval: format == .html && (isSmartRemovalEnabled || !smartRemovalKeptIDs.isEmpty)
                ? DocumentSettings.SmartRemoval(isEnabled: isSmartRemovalEnabled, keptIDs: smartRemovalKeptIDs) : nil,
            printOptions: printOptions,
            imageOrder: imageBundle.flatMap { $0.isSortedByName ? nil : $0.orderDigests },
            paperOrientation: paperOrientation, htmlPresentation: usesHTMLPresentation ? htmlPresentation : nil,
            ignoresSlides: usesHTMLPresentation && ignoresSlides ? true : nil)
    }

    /// What this document has when the user changes nothing. Until the pages are known, the reading layout is the
    /// initial guess, so a layout chosen while the pages are prepared still counts as a change.
    private var defaultSettings: DocumentSettings {
        DocumentSettings(
            view: defaultViewOptions ?? initialViewOptions, zoom: 1, layoutID: Self.defaultLayoutID(preferences),
            themeID: format.usesPrintTheme ? Self.defaultThemeID(preferences, library) : nil,
            textScale: format.usesPrintTheme ? 1 : nil,
            presetID: format.usesHTMLPreset ? Self.defaultPresetID(preferences, library) : nil,
            printOptions: preferences.printOptions, paperOrientation: .auto,
            htmlPresentation: usesHTMLPresentation ? .web : nil)
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
        setTextScale(saved.textScale ?? 1)
        if let view = saved.view {
            viewOptions = view
            hasResolvedViewOptions = true
        }
        if let zoom = saved.zoom { self.zoom = min(max(zoom, 1), PaperPDFView.maximumZoom) }
        if let orientation = saved.paperOrientation { paperOrientation = orientation }
        if let id = saved.layoutID, PrintLayout.presets.contains(where: { $0.id == id }) { layoutID = id }
        if let id = saved.themeID, library.themes.contains(where: { $0.id == id }) { themeID = id }
        if let id = saved.presetID, library.presets.contains(where: { $0.id == id }) { presetID = id }
        if let options = saved.printOptions { printOptions = options }
        if let presentation = saved.htmlPresentation { setHTMLPresentation(presentation, capturesWeb: false) }
        if saved.ignoresSlides == true { setIgnoresSlides(true) }
        if let removal = saved.smartRemoval, format == .html {
            isSmartRemovalEnabled = removal.isEnabled
            smartRemovalKeptIDs = removal.keptIDs
        }
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
        textScale = 1
        paperOrientation = .auto
        layoutID = Self.defaultLayoutID(preferences)
        themeID = Self.defaultThemeID(preferences, library)
        presetID = Self.defaultPresetID(preferences, library)
        printOptions = preferences.printOptions
        isSmartRemovalEnabled = false
        smartRemovalKeptIDs = []
        isReviewingSmartRemoval = false
        zoom = 1
        setIgnoresSlides(false)
        setHTMLPresentation(.web)
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
        guard let document = result?.viewDocument, document.pageCount > 0 else { return nil }
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
            // A web page opens at the paper's size but reflows to any shape the reader gives the window.
            if isWebPresentation { applyWebShape(animate: false) }
            return
        }
        guard !isWebPresentation else { return applyWebShape() }
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
        guard isWebPresentation else { return }
        // The band grows the window at the top, so the page area keeps the slide's shape.
        if let deck = slideDeck {
            ViewerWindow.lockAspectRatio(of: window, unit: deck.size, band: bandInset)
        } else {
            ViewerWindow.unlockAspectRatio(of: window)
        }
    }

    func windowDidEndLiveResize() {
        // The window size remembered is the paper's; the web page takes whatever size the reader likes.
        guard mode == .view, !isWebPresentation, let window, !ViewerWindow.isResizingProgrammatically(window),
            let unit = paperUnitSize
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

    enum Output: Equatable {
        case print(quick: Bool)
        case exportPDF
    }

    /// An output asked for during the review ends it and waits for the pages without the outlines.
    private func deferUntilReviewEnds(_ output: Output) -> Bool {
        guard isReviewingSmartRemoval else { return false }
        isReviewingSmartRemoval = false
        outputAfterReview = output
        return true
    }

    /// The printer Print sends to: the one chosen on the tray while it is set up, otherwise the system's default.
    var selectedPrinterName: String? { printers.resolve(preferences.printerName) }

    func refreshPrinters() {
        let current = PrinterList.current()
        if current != printers { printers = current }
    }

    func selectPrinter(_ name: String) {
        preferences.printerName = name
    }

    /// Prints the sheets: right away to the selected printer when `quick`, otherwise through the system dialog,
    /// which starts on that printer.
    func printDocument(quick: Bool = false) {
        guard !deferUntilWebIsCaptured(.print(quick: quick)), !deferUntilReviewEnds(.print(quick: quick)) else {
            return
        }
        guard canOutput, let result = printResult, let window else { return }
        outputError = nil
        let shown = selectedPrinterName
        refreshPrinters()
        let request = printers.request(quick: quick, shown: shown, remembered: preferences.printerName)
        let destination = request.printerName.flatMap(NSPrinter.init(name:))
        // Without a printer the system dialog still offers saving a PDF or adding a printer.
        let quick = !request.showsPanel && destination != nil
        guard
            let operation = PrintJobFactory().printOperation(
                for: result.sheetDocument, layout: result.layout, showsPrintPanel: !quick,
                printer: destination)
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
        guard !deferUntilWebIsCaptured(.exportPDF), !deferUntilReviewEnds(.exportPDF) else { return }
        guard let window, beginPDFExport() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = exportName
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.completePDFExport(to: response == .OK ? panel.url : nil)
        }
    }

    func beginPDFExport() -> Bool {
        guard canOutput, let result = printResult else { return false }
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
