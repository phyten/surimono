import AppKit
import ApplicationServices
import OSLog
import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering

/// The window shows the paper, the print tray, or the comparison stage of print themes.
enum ViewerMode { case view, print, compare }

typealias DocumentSettingsStore = KeyedRecordStore<DocumentSettings>

/// The settings a reset replaced. A class, so that the toast and the window's history share whether it was used.
final class ResetOrigin {
    let settings: DocumentSettings
    let wasSaved: Bool
    let selectedSettingSetID: UUID?
    /// The paper's size in the view mode, as a record would take it in, whichever mode the reset was done in.
    let paperSize: CGSize?
    let defaultTextScale: Double
    let defaultPaperOrientation: PaperOrientation
    let defaultBandVisibility: BandVisibility
    let openingViewDefaults: ViewDefaultPreferences
    let defaultViewOptions: ViewOptions?
    var isRestored = false

    init(
        settings: DocumentSettings, wasSaved: Bool, selectedSettingSetID: UUID?, paperSize: CGSize?,
        defaultTextScale: Double, defaultPaperOrientation: PaperOrientation,
        defaultBandVisibility: BandVisibility, openingViewDefaults: ViewDefaultPreferences,
        defaultViewOptions: ViewOptions?
    ) {
        self.settings = settings
        self.wasSaved = wasSaved
        self.selectedSettingSetID = selectedSettingSetID
        self.paperSize = paperSize
        self.defaultTextScale = defaultTextScale
        self.defaultPaperOrientation = defaultPaperOrientation
        self.defaultBandVisibility = defaultBandVisibility
        self.openingViewDefaults = openingViewDefaults
        self.defaultViewOptions = defaultViewOptions
    }
}

/// A short message near the bottom of the window, optionally with one action.
struct Toast: Equatable, Identifiable {
    enum Action: Equatable {
        case retryWebCapture, allowFolderAccess, nextChange, openIncludes, undoBinder, undoReset
    }

    let id = UUID()
    var systemImage: String
    var title: String
    var detail: String?
    var action: Action?
}

@Observable
final class DocumentViewModel {
    private var folderLease: FolderAccess.Lease?
    let fileURL: URL?
    private let title: String?
    let imageBundle: ImageBundleModel?
    let binder: BinderModel?
    var binderStartsOnFront = false
    var usesPrintTheme: Bool { binder?.usesPrintTheme ?? format.usesPrintTheme }
    var usesHTMLPreset: Bool { binder?.usesHTMLPreset ?? format.usesHTMLPreset }
    private(set) var unreadableImageURLs: [URL] = []
    private var renderedSourceURLs: [URL] = []
    private(set) var format: DocumentFormat
    private var data: Data
    let preferences: AppPreferences
    let library: UserLibrary
    var paperOrientation: PaperOrientation
    /// The side the reader chose to bind booklets on; nil until they choose, when the reading direction decides.
    /// Entering the tray does not fill it in: that would save the document's settings without the reader having
    /// changed anything.
    var bookletBinding: BookletBinding?
    var effectiveBookletBinding: BookletBinding {
        bookletBinding ?? (viewOptions.direction == .rightToLeft ? .right : .left)
    }

    var layoutID: String { didSet { if shownPaperSeries != layout.series { shownPaperSeries = nil } } }
    /// The series of paper the tray's cards show, once the reader switched it for this window.
    private var shownPaperSeries: PaperSeries?
    /// Set directly only when restoring or falling back; a theme the user picks goes through `selectTheme(_:)`.
    var themeID: String
    /// An axis of its own: choosing another style leaves it as it is. A palette the user picks goes through
    /// `selectCodePalette(_:)`.
    var codePaletteID: String
    var codeBlock = CodeBlockOptions()
    private(set) var textScale: Double
    var presetID: String
    var printOptions: PrintOptions
    /// Where a text breaks and how it shows its contents; only texts have any.
    var printFinish: PrintFinish
    /// Pages to write on among the document's own. They belong to the paper, so the reading view leaves them out.
    var notes = NotePages()
    /// How many copies the tray prints. It belongs to the window: it is not remembered, and a new window starts at 1.
    var copies = 1 {
        didSet {
            let range = PrintJobFactory.copiesRange
            let clamped = min(max(copies, range.lowerBound), range.upperBound)
            if copies != clamped { copies = clamped }
        }
    }
    /// The pages the tray prints, as last read from the field; what cannot be read leaves it as it was.
    private(set) var pageRange = PageRange.all
    /// What the tray's field shows, which may be half typed.
    private(set) var pageRangeText = ""
    private(set) var isPageRangeUnreadable = false
    /// The setting set last applied or saved in this window, which the tray compares the settings with.
    var selectedSettingSetID: UUID?
    var mode: ViewerMode = .view
    private var openingViewDefaults: ViewDefaultPreferences
    // Keep the baseline stable if Settings changes while the document is still opening.
    private var defaultTextScale: Double
    private var defaultPaperOrientation: PaperOrientation
    private var defaultBandVisibility: BandVisibility
    /// The paper the view mode lays text out on; the print tray has its own layout.
    var paperSeries: ViewPaperSeries = .a
    var loneCoverWidth: LoneCoverWidth { preferences.loneCoverWidth }
    var viewOptions: ViewOptions
    /// Magnification relative to fitting the current page or spread into the window.
    var zoom: Double = 1
    /// The 0-based index of the first visible logical page.
    var currentPageIndex = 0 { didSet { shownPageIndex = currentPageIndex } }
    /// The page the paper shows, which is a trial's page while a theme is tried; `currentPageIndex` keeps the reading
    /// position in the document's own pages for when the trial ends.
    var shownPageIndex = 0
    /// Whether the bands show all the time; their room beside the paper stays either way.
    var bandVisibility: BandVisibility
    var isAlwaysOnTop: Bool
    var isDrawerOpen = false
    var showsSideList: Bool { isDrawerOpen && (binder != nil || imageBundle != nil) }
    var sideInset: CGFloat { mode == .view && showsSideList ? SidePanelMetrics.width : 0 }
    /// The row of the tray to bring into view, for the sheets on it now.
    var requestedTrayRow: Int?
    /// What a row of the list asked the tray to show, until the sheets that hold it are ready.
    @ObservationIgnored private var trayRequest: URL?
    /// The zoom of the tray on screen, which the menus' zoom commands drive in the print mode.
    @ObservationIgnored weak var trayZoomer: TrayZoomer?
    /// A file drag over this window.
    let drop = DropSession()
    /// The window this binder took the place of, for as long as going back can bring it.
    @ObservationIgnored var binderOrigin: BinderOrigin?
    /// The reader took this binder back, so its window leaves nothing to open again when it closes.
    @ObservationIgnored var isBinderUndone = false
    /// Called once, when the first pages are ready or could not be made.
    @ObservationIgnored var onFirstRender: ((Bool) -> Void)?
    /// What this window shows came from another window, so a record saved for these files gives way to it.
    @ObservationIgnored private var keepsSettingsOverSaved = false
    /// A binder of this window's contents is being laid out to take its place. What this window shows is about to be
    /// out of date, so nothing goes out from it meanwhile.
    var isBecomingBinder = false
    /// Dragging the paper selects text instead of moving the window. It belongs to the window and is never saved, so
    /// a document always opens with the paper as the window and a drag never selects text by surprise.
    var isSelectingText = false
    /// The find bar over the paper. It belongs to the window and is never saved.
    let find = PaperFind()
    var isGoToPagePresented = false
    var isViewOptionsPresented = false
    var isOutlinePresented = false
    var isOutlineDrawerOpen = false
    var isFiguresPresented = false
    var isPrintFinishPresented = false
    /// The section the print settings sheet scrolls to when it is set.
    var finishSection: PrintFinishSection?
    /// The note section's fine adjustments are open.
    var showsNoteAdjustments = false
    /// The reader chose to write the header and footer themselves, which an empty one does not show by its content.
    var isWritingFurniture = false
    var isPrintIssuesPresented = false
    @ObservationIgnored private var pendingPrintIssue: (issue: PrintIssue, pageCount: Int)?
    /// Waits for the paper to show the page of a problem the reader was sent to, then frames the spot.
    @ObservationIgnored private var spotTask: Task<Void, Never>?
    /// Replaces the paper's frame in tests: the spot, and whether the paper took it.
    @ObservationIgnored var spotPresenter: ((PaperSpot) -> Bool)?
    /// The style palette is open beside the paper.
    var isThemePalettePresented = false
    /// The first page of the document in each theme, for the palette and the comparison stage.
    let themeSamples = ThemeSamples()
    let specimenSamples = ThemeSamples()
    var palettePreviewThemeID: String?
    /// The theme the pointer rests on in the palette, laid out on the paper.
    let themeTrial: ThemeTrial
    /// A trial the user then chose: the paper keeps it until the document's own pages in that theme are ready.
    private(set) var chosenTrial:
        (themeID: String, codePaletteID: String, document: PDFDocument, changeMarks: [ChangeMark])?
    /// The candidates on the comparison stage, kept while the window lives.
    var themeComparison: ThemeComparison?
    /// Where the stage's pages start, kept with the candidates; nil is the first page.
    var comparePlace: SamplePlace?
    var isComparePlacePickerPresented = false
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
    /// An output waiting for the print layout, a web capture, or the end of a review; it runs when sheets are ready.
    @ObservationIgnored private(set) var outputAfterReview: Output?
    /// Replaces the system output UI in tests, after readiness checks, with the exact sheets being output.
    @ObservationIgnored var outputOverride: ((Output, RenderResult) -> Void)?
    /// Replaces submission after resolving the destination and matching its settings to the composed sheets.
    @ObservationIgnored var printSubmit: ((RenderResult, PrintRequest, PrintPageOrder) -> Void)?
    private struct PendingPrint {
        var request: PrintRequest
        let quick: Bool
    }
    private var pendingPrint: PendingPrint?
    var duplexTestResult: DuplexTestResult?
    /// Replaces submission in tests so calibration never sends a physical print job.
    @ObservationIgnored var duplexTestSubmit:
        ((PDFDocument, PrintLayout, PrintRequest, @escaping (DuplexTestResult?) -> Void) -> Void)?
    private var duplexTestTask: Task<Void, Never>?
    var toast: Toast?
    /// What the document can be bound from; nil unless it names at least two documents that can be read.
    private(set) var includePlan: MarkdownIncludes.Plan?
    @ObservationIgnored private var includeTask: Task<Void, Never>?
    @ObservationIgnored private var hasOfferedIncludes = false
    /// The folder is being allowed on the way to the binder, which opens once the folder can be read.
    @ObservationIgnored private var opensIncludesWithAccess = false
    /// Replaces the save panel in tests.
    @ObservationIgnored var chooseSaveDestination: ((String, @escaping (URL?) -> Void) -> Void)?
    /// The logical pages the paper shows. They are published before the sheets are composed.
    private(set) var result: PreparedRender?
    /// The composed sheets for the tray and the outputs. It may still belong to an earlier `result` while the sheets
    /// of the current one are composed; `canOutput` checks that it matches.
    private(set) var printResult: RenderResult?
    private var trayFigures: TrayFigures?
    /// The sheets of `printResult`, grouped as they come out of the printer; built once per composition.
    private(set) var printTray: PrintTray?
    private(set) var renderedSettings: RenderSettings?
    /// What the render in flight is making, once its back-side correction is settled.
    @ObservationIgnored private var renderingSettings: RenderSettings?
    /// How many renders were started; a render that settles its own settings must not start another.
    @ObservationIgnored private(set) var renderStartCount = 0
    private(set) var isRendering = false
    private(set) var isPrinting = false
    /// The printers the tray offers; refreshed when the tray opens and before each print.
    private(set) var printers = PrinterList.empty
    @ObservationIgnored var printerListSource: () -> PrinterList = { PrinterList.current() }
    /// What each printer said it can do, by name; a printer that has not answered has no entry and shows no badge.
    var printerCapabilities: [String: PrinterCapabilities] = [:]
    @ObservationIgnored var printerCapabilityQueries: Set<String> = []
    /// Asks a printer what it can do, off the main thread; nil when it cannot tell.
    @ObservationIgnored var printerCapabilitiesSource: @Sendable (String) async -> PrinterCapabilities? = {
        await PrinterCapabilityCache.shared.capabilities(for: $0)
    }
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
    /// What the last reset took away, until it is brought back.
    @ObservationIgnored private(set) var resetOrigin: ResetOrigin?
    @ObservationIgnored private var restoredPaperSize: CGSize?
    /// The paper's height before the screen's width made it shorter; it comes back once the pages fit at that height.
    @ObservationIgnored private var heightBeforeScreenLimit: CGFloat?
    /// The view mode's paper size when the print mode began; the tray's size is not the document's window size.
    @ObservationIgnored private(set) var viewPaperSizeBeforePrinting: CGSize?
    /// An undo on a stage brought back a size for the view mode, which the window takes on the way back.
    @ObservationIgnored private var returnsToRestoredPaperSize = false
    @ObservationIgnored private(set) var hasSizedWindow = false
    /// The tray was asked for before the first pages were there.
    @ObservationIgnored private(set) var isPrintModeRequested = false
    @ObservationIgnored private var didResizeWindow = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The keys under which this window wrote a record where there was none. Only these are removed when the content
    /// changes; a record from before may belong to a copy of the file that still has that content.
    @ObservationIgnored private var createdRecordKeys: Set<String> = []
    /// The files `contentHash` was computed from.
    @ObservationIgnored private var hashedSourceURLs: Set<URL> = []
    @ObservationIgnored private var hashTask: Task<Void, Never>?
    @ObservationIgnored private var openFailure: String?
    @ObservationIgnored private var retriedChangedImages = false
    @ObservationIgnored private var hasShownBundleSummary = false
    private var hasResolvedViewOptions = false
    @ObservationIgnored private var defaultViewOptions: ViewOptions?
    /// The guess shown before the pages are known; a different value then can only come from the user.
    @ObservationIgnored private let initialViewOptions: ViewOptions
    private let renderer: DocumentRenderer
    private var renderTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var reloadTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    var beforeWatcherCheck: @Sendable () -> Void = {}
    private var reloadRequiresRefresh = false
    private var reloadRequiresWebRefresh = false
    private var reloadOwnsProgress = false
    var readReloadData: @Sendable (URL) async throws -> Data = { url in
        try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
    }
    private var reloadGeneration = 0
    private var displayedMarkdownData: Data?
    private(set) var markdownChanges: [MarkdownMarkRequest] = []
    /// The changes of the last reload have not been brought to the reader's attention yet.
    @ObservationIgnored private var hasUnannouncedChanges = false
    /// The table of contents, with the page of each entry as laid out for reading.
    private(set) var outlineEntries: [OutlineEntry] = []
    /// The amount of text; only documents laid out from text have one.
    private(set) var documentStatistics: DocumentStatistics?
    @ObservationIgnored private var structureTask: Task<Void, Never>?
    @ObservationIgnored private var readStructure:
        (source: DocumentSource, headings: [DocumentHeading], statistics: DocumentStatistics, contents: [String])?
    @ObservationIgnored private var structureDocument: PDFDocument?
    @ObservationIgnored private var textSizeKeyMonitor: Any?
    private var printCompletion: PrintCompletion?
    private var printOperation: NSPrintOperation?
    private var exportingDocument: PDFDocument?

    init(
        data: Data, fileURL: URL?, format: DocumentFormat,
        preferences: AppPreferences, library: UserLibrary, renderer: DocumentRenderer = DocumentRenderer(),
        imageBundle: ImageBundleModel? = nil, settingsStore: DocumentSettingsStore? = nil,
        trialRenderer: DocumentRenderer = DocumentRenderer(), title: String? = nil, binder: BinderModel? = nil
    ) {
        themeTrial = ThemeTrial(renderer: trialRenderer)
        self.imageBundle = imageBundle
        self.binder = binder
        self.settingsStore = settingsStore
        self.data = data
        self.fileURL = fileURL
        self.title = title
        self.format = format
        self.preferences = preferences
        openingViewDefaults = preferences.viewDefaults
        defaultTextScale = preferences.defaultTextScale
        defaultPaperOrientation = preferences.defaultPaperOrientation
        textScale = (binder?.usesPrintTheme ?? format.usesPrintTheme) ? preferences.defaultTextScale : 1
        paperOrientation = preferences.defaultPaperOrientation
        isAlwaysOnTop = preferences.defaultAlwaysOnTop
        defaultBandVisibility = preferences.defaultBandVisibility
        bandVisibility = preferences.defaultBandVisibility
        self.library = library
        self.renderer = renderer
        layoutID = Self.defaultLayoutID(preferences)
        bookletBinding = nil
        themeID = Self.defaultThemeID(preferences, library)
        codePaletteID = Self.defaultCodePaletteID(preferences, library)
        presetID = Self.defaultPresetID(preferences, library)
        printOptions = preferences.printOptions
        printFinish = preferences.printFinish
        // A guess until the pages are known; most documents have more than two pages.
        let guess = ViewOptions.resolved(
            for: ViewDefaultsContext(
                kind: Self.viewKind(format: format, isBundle: imageBundle != nil), pageCount: 3,
                firstPageSize: PaperSize.a4.size), preferences: preferences.viewDefaults)
        viewOptions = guess
        initialViewOptions = guess
        themeSamples.inputs = { [weak self] in (self?.themedSource, self?.renderSettings) }
        specimenSamples.inputs = { [weak self] in
            guard let self else { return (nil, nil) }
            return (ThemeSpecimen.source(language: language), ThemeSpecimen.settings)
        }
        paper.onToast = { [weak self] toast in
            self?.showToast(toast, dismissAfter: toast.action == .allowFolderAccess ? nil : .seconds(5))
        }
        web.onFolderAccessRequired = { [weak self] _ in self?.requestFolderAccess() }
        drop.onSpring = { [weak self] in self?.isDrawerOpen = true }
        #if DEBUG
            DebugSnapshot.configure(self)
        #endif
    }

    var sourceURLs: [URL] { binder?.urls ?? imageBundle?.urls ?? [fileURL].compactMap { $0 } }
    /// The document as the print themes lay it out; nil for the formats that print without a theme.
    var themedSource: DocumentSource? {
        if let binder { return binder.cachedSource }
        return format.usesPrintTheme && imageBundle == nil
            ? withFolderAccess(DocumentSource(data: data, fileURL: fileURL, format: format)) : nil
    }
    var protectedSourceURLs: [URL] {
        NSDocumentController.shared.documents.compactMap(\.fileURL)
            + ImageBundleWindows.shared.sourceURLs + BinderWindows.shared.sourceURLs + sourceURLs
    }
    var exportName: String {
        binder?.exportName(layout: renderedSettings?.layout ?? layout, language: language)
            ?? imageBundle?.exportName(layout: renderedSettings?.layout ?? layout, language: language)
            ?? Self.exportName(
                fileURL: fileURL, layout: renderedSettings?.layout ?? layout, language: language, title: title)
    }
    var displayName: String {
        binder?.title(language: language) ?? imageBundle?.title(language: language) ?? title ?? fileURL?
            .lastPathComponent ?? String(localized: "Document")
    }
    /// What the printer's queue shows for this document's job, and what the system dialog proposes when saving a PDF.
    var printJobTitle: String { displayName }
    /// The test sheet is not the document, so its job is named after what it is.
    static func duplexTestJobTitle(language: String) -> String {
        PrintModeText.string("Duplex Test Print", language: language)
    }
    /// "MD", "PDF", "ZIP"…; "IMG" for a bundle of image files.
    var formatBadge: String {
        binder != nil ? String(localized: "Binder") : imageBundle == nil || format == .zipArchive ? format.badge : "IMG"
    }

    var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The user picked a print theme, so it also becomes the most recent one in every window's menu.
    func selectTheme(_ id: String) {
        // The pages of a trial of the same theme stay on the paper until the document's own are laid out.
        if id != themeID, themeTrial.themeID == id, let document = themeTrial.document {
            chosenTrial = (id, codePaletteID, document, themeTrial.changeMarks)
        }
        themeTrial.end()
        themeComparison?.choose(id)
        themeID = id
        preferences.recordThemeChoice(id)
    }

    /// The user picked a code palette. The pages of a trial of it stay on the paper as they do for a theme.
    func selectCodePalette(_ id: String) {
        if id != codePaletteID, themeTrial.themeID == Self.codeTrialID(id), let document = themeTrial.document {
            chosenTrial = (themeID, id, document, themeTrial.changeMarks)
        }
        themeTrial.end()
        codePaletteID = id
        if library.codePalette(id)?.group == .inkHeavy {
            showToast(
                Toast(
                    systemImage: "drop.fill", title: String(localized: "Dark code blocks use a lot of ink"),
                    detail: String(localized: "About seven times the ink of code on white paper.")))
        }
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
    var layout: PrintLayout {
        (PrintLayout.presets.first { $0.id == layoutID } ?? .a4Single).bound(effectiveBookletBinding)
    }
    /// Reading and comparing keep the paper's shape independent of how pages are arranged for printing.
    var renderLayout: PrintLayout { renderLayout(in: mode) }

    private func renderLayout(in mode: ViewerMode) -> PrintLayout { mode == .print ? layout : paperSeries.layout }
    /// Text can be laid out again on other paper; PDFs and images keep their pages, and a binder its documents.
    var offersPaperSeries: Bool { !showsWeb && binder == nil && imageBundle == nil && format.isWebRendered }

    var renderSettings: RenderSettings? { renderSettings(in: mode) }

    private func renderSettings(in mode: ViewerMode) -> RenderSettings? {
        guard
            let theme = library.themes.first(where: { $0.id == (usesPrintTheme ? themeID : "standard") })
                ?? library.themes.first(where: { $0.id == "standard" }),
            let preset = library.presets.first(where: { $0.id == (usesHTMLPreset ? presetID : "none") })
                ?? library.presets.first(where: { $0.id == "none" })
        else { return nil }
        var settings = RenderSettings(
            layout: renderLayout(in: mode), theme: theme, preset: preset, options: effectivePrintOptions,
            allowsJavaScriptInHTML: preferences.allowsJavaScript,
            smartRemoval: format == .html && isSmartRemovalEnabled
                ? SmartRemovalRequest(keptIDs: smartRemovalKeptIDs, highlightsCandidates: isReviewingSmartRemoval)
                : nil,
            textScale: usesPrintTheme ? textScale : 1, paperOrientation: paperOrientation,
            opensDetails: rendersSnapshot && opensClosedDetails,
            slides: slideDeck.map {
                SlidePrintRequest(deck: $0, printsCurrentOnly: mode == .print && printsCurrentSlideOnly)
            }, markdownChanges: format == .markdown ? markdownChanges : [])
        settings.binderStartsOnFront = binder != nil && binderStartsOnFront && settings.layout.hasFacingPages
        if finishAppliesToText { settings.finish = printFinish }
        if mode == .print, offersNotes { settings.notes = notes }
        // The view mode always shows the whole document.
        if mode == .print { settings.pageRange = pageRange }
        settings.documentName = displayName
        settings.pageLanguage = language
        if usesPrintTheme {
            settings.code = CodeStyle(
                palette: library.codePalette(codePaletteID), block: codeBlock,
                cutFormat: String(localized: "+%d characters"))
        }
        return settings
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
            && !isBecomingBinder && !isPageRangeUnreadable
    }

    enum PageRangeProblem: Equatable { case unreadable, noSuchPages }

    /// Why the field is marked. A range that cannot be read holds the outputs back; one that names no page of the
    /// document prints everything, which the tray shows.
    var pageRangeProblem: PageRangeProblem? {
        if isPageRangeUnreadable { return .unreadable }
        guard mode == .print, renderedSettings?.pageRange == pageRange, result?.pageSelection.isOutOfDocument == true
        else { return nil }
        return .noSuchPages
    }

    /// The field's text, read as it is typed: Print does not take the focus from the field, so there is no moment
    /// at which the reader has finished.
    func setPageRangeText(_ text: String) {
        guard text != pageRangeText else { return }
        pageRangeText = text
        do {
            pageRange = try PageRange(
                parsing: text, allWords: ["All", "すべて", PrintModeText.string("All", language: language)])
            isPageRangeUnreadable = false
        } catch {
            isPageRangeUnreadable = true
        }
    }

    private func setPageRange(_ range: PageRange) {
        pageRange = range
        pageRangeText = range.text
        isPageRangeUnreadable = false
    }
    var summary: String? {
        guard let result else { return nil }
        return Self.summaryText(result.summary, layout: result.layout, locale: Locale(identifier: language))
    }
    /// The page breaks and the contents are read from a text; a binder keeps its documents as they are.
    var finishAppliesToText: Bool { binder == nil && format.usesPrintTheme }

    /// The series of the tray's cards. A document shown on B sizes opens the tray on them, one on the default layout
    /// shows the series last chosen on a tray, and any other the series of its own paper.
    var trayPaperSeries: PaperSeries {
        if let shownPaperSeries { return shownPaperSeries }
        if paperSeries == .b { return .b }
        if layoutID == Self.defaultLayoutID(preferences), let series = preferences.paperSeries { return series }
        return layout.series
    }

    /// Switching the series brings the layout along, so the sheets on the tray follow the switch.
    func choosePaperSeries(_ series: PaperSeries) {
        preferences.paperSeries = series
        layoutID = layout.counterpart(in: series).id
        shownPaperSeries = series
    }

    /// The compact alternatives have no shortcut, so the six existing positions stay stable.
    func chooseCard(at index: Int) {
        let cards = PrintLayout.presets(in: trayPaperSeries)
        let choice =
            trayPaperSeries == .b && index == 5
            ? PrintLayout.a4Handout3 : (cards.indices.contains(index) ? cards[index] : PrintLayout.a4Handout3)
        chooseLayout(choice.id)
    }

    var pageCount: Int { result?.logicalDocument.pageCount ?? 0 }
    /// Problems on pages that are not printed are not problems of this print.
    var printIssues: [PrintIssue] {
        guard let result else { return [] }
        return result.issues.filter { issue in issue.pageNumber.map { result.pageSelection.contains($0 - 1) } ?? true }
    }
    var printIssueCount: Int { printIssues.count }

    func reviewPrintIssues() {
        guard !printIssues.isEmpty else { return }
        isPrintFinishPresented = false
        isPrintIssuesPresented = true
        enterPrintMode()
    }

    func showPrintIssue(_ issue: PrintIssue) {
        guard let page = issue.pageNumber else { return }
        isPrintIssuesPresented = false
        setHTMLPresentation(.paper, capturesWeb: false)
        if (renderedSettings?.layout ?? renderLayout) == paperSeries.layout {
            pendingPrintIssue = nil
            currentPageIndex = max(0, page - 1)
            pointOut(issue, onPage: max(0, page - 1))
        } else {
            pendingPrintIssue = (issue, pageCount)
        }
        exitPrintMode()
    }

    /// Frames the spot of a problem on the paper for a moment, so that the reader need not look for it on the page.
    /// The window gives the print stage back and takes the paper's width again first, so the paper may not be there
    /// yet; a problem with no mark on its page gets no frame. The request is for the pages the problem was found on:
    /// once a reload or a new layout replaces them, it is dropped, not matched to whatever the paper shows next.
    private func pointOut(_ issue: PrintIssue, onPage pageIndex: Int) {
        dropSpot()
        guard let anchor = issue.rect, let document = result?.viewDocument else { return }
        let spot = PaperSpot(pageIndex: pageIndex, anchor: anchor, document: document)
        spotTask = Task { @MainActor [weak self] in
            for _ in 0..<50 {
                guard let self, !Task.isCancelled, result?.viewDocument === document else { return }
                if mode == .view, spotPresenter?(spot) ?? paper.showSpot(spot) { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Withdraws a frame that was asked for and has not been shown yet.
    private func dropSpot() {
        spotTask?.cancel()
        spotTask = nil
    }

    private func resumePrintIssueNavigation() {
        guard pendingPrintIssue != nil else { return }
        if isUpToDate {
            resolvePrintIssueNavigation()
        } else {
            render()
        }
    }

    private func resolvePrintIssueNavigation() {
        guard mode == .view, isUpToDate, let pendingPrintIssue, let result else { return }
        let index = pendingPrintIssue.issue.pageIndex(
            in: result.issues, pageCount: result.logicalDocument.pageCount,
            sourcePageCount: pendingPrintIssue.pageCount)
        // Only the same problem found again in the new pages has a mark there; a guess at its place has none.
        let found = pendingPrintIssue.issue.locationKey.flatMap { key in
            result.issues.first { $0.locationKey == key }
        }
        self.pendingPrintIssue = nil
        currentPageIndex = index
        // SwiftUI may still show the old PDF. A newly attached paper uses currentPageIndex instead.
        paper.goToPage(index: index, in: result.viewDocument)
        if let found { pointOut(found, onPage: index) }
    }

    func useLandscapeForPrintIssue() {
        paperOrientation = .landscape
    }

    func revealPrintIssueFolder() {
        guard let fileURL else { return }
        NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
    }

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
        if SandboxEnvironment.isSandboxed, folderLease == nil, let fileURL {
            folderLease = FolderAccess.shared.acquire(for: fileURL)
            web.allowedResourceFolders = folderLease.map { [$0.url] } ?? []
            if folderLease != nil { web.reload() }
        }
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
                    return self.handleTextSizeKey(event) || self.handleTrayZoomKey(event)
                }
                return handled ? nil : event
            }
        }
        if watcher == nil, let fileURL {
            watcher = FileWatcher(
                url: fileURL,
                beforeCheck: beforeWatcherCheck,
                onChange: { [weak self] event in
                    guard let self, self.watcher != nil else { return }
                    handleFileEvent(event)
                })
        }
        if let imageBundle, !hasShownBundleSummary, openFailure == nil {
            hasShownBundleSummary = true
            let excluded = imageBundle.excludedSummary
            if !excluded.isEmpty {
                showToast(
                    Toast(
                        systemImage: "photo.on.rectangle",
                        title: String(format: String(localized: "Opened %lld images"), imageBundle.items.count),
                        detail: String(
                            format: String(localized: "%lld non-image files excluded (%@)"),
                            imageBundle.excludedPaths.count, ListFormatter.localizedString(byJoining: excluded))))
            }
        }
        computeContentHash()
        refreshIncludePlan()
        // A window that replaces another has its pages from before it appeared.
        if result == nil { render() }
    }

    /// A document that cannot be opened at all, such as an encrypted ZIP, shows the reason instead of pages.
    func failToOpen(_ message: String) {
        openFailure = message
        error = message
    }

    func stop() {
        pendingPrint = nil
        duplexTestTask?.cancel()
        duplexTestTask = nil
        pendingPrintIssue = nil
        dropSpot()
        if let textSizeKeyMonitor { NSEvent.removeMonitor(textSizeKeyMonitor) }
        textSizeKeyMonitor = nil
        renderTask?.cancel()
        toastTask?.cancel()
        hashTask?.cancel()
        structureTask?.cancel()
        flushPendingSettings()
        reloadGeneration += 1
        reloadTask?.cancel()
        reloadTask = nil
        reloadRequiresRefresh = false
        reloadRequiresWebRefresh = false
        reloadOwnsProgress = false
        reconciliationTask?.cancel()
        reconciliationTask = nil
        includeTask?.cancel()
        watcher?.stop()
        watcher = nil
        cancelCapture()
        web.close()
        binder?.stop()
        themeTrial.end()
        themeSamples.invalidate()
        specimenSamples.invalidate()
        folderLease?.close()
        folderLease = nil
    }

    func handleFileEvent(_ event: FileWatcher.Event) {
        switch event {
        case .check:
            guard let fileURL else { return }
            let generation = reloadGeneration
            let reader = readReloadData
            reconciliationTask?.cancel()
            reconciliationTask = Task { [weak self] in
                // Initial registration is not evidence of a change: leave an in-flight layout alone.
                guard let bytes = try? await reader(fileURL), let self,
                    !Task.isCancelled, generation == reloadGeneration, bytes != data
                else { return }
                reload(reloadsWeb: true, onlyIfChanged: true)
            }
        case .changed: reload(reloadsWeb: true, onlyIfChanged: true)
        case .removed:
            reloadGeneration += 1
            reloadTask?.cancel()
            reloadTask = nil
            reloadRequiresRefresh = false
            reloadRequiresWebRefresh = false
            if reloadOwnsProgress { isRendering = false }
            reloadOwnsProgress = false
            showToast(
                Toast(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "The file is missing. The last preview is still available.")),
                dismissAfter: nil)
        }
    }

    func reload() {
        reload(reloadsWeb: true)
    }

    private func reload(reloadsWeb: Bool, onlyIfChanged: Bool = false) {
        if imageBundle?.archiveURL != nil, fileURL != nil {
            // The images of a ZIP were read when it opened; its window cannot swap in another archive.
            showToast(
                Toast(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: String(localized: "This ZIP archive changed. Close and reopen it to see the new images.")),
                dismissAfter: nil)
            return
        }
        reloadRequiresRefresh = reloadRequiresRefresh || !onlyIfChanged
        reloadRequiresWebRefresh = reloadRequiresWebRefresh || reloadsWeb
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        // Invalidate captures before yielding for I/O: an old snapshot must never win this race.
        renderTask?.cancel()
        if reloadsWeb { cancelCapture() }
        reloadOwnsProgress = true
        if reloadRequiresRefresh { isRendering = true }
        guard let fileURL else {
            applyReload(reloadsWeb: reloadsWeb)
            return
        }
        // Detached I/O keeps large files off the main actor; generation checks reject superseded reads.
        let reader = readReloadData
        reloadTask = Task { [weak self] in
            do {
                let bytes = try await reader(fileURL)
                guard let self, !Task.isCancelled, reloadGeneration == generation else { return }
                if !reloadRequiresRefresh && bytes == data {
                    reloadTask = nil
                    reloadOwnsProgress = false
                    reloadRequiresWebRefresh = false
                    // If a still-running layout was cancelled at the reload boundary, finish that same content.
                    if isRendering { render() }
                    return
                }
                if format == .markdown, bytes != data || displayedMarkdownData != bytes {
                    let previous = displayedMarkdownData
                    let diff = Task.detached(priority: .utility) {
                        previous.map {
                            MarkdownChanges.marks(
                                from: TextDecoding.decode($0).text, to: TextDecoding.decode(bytes).text)
                        } ?? []
                    }
                    let changes = await diff.value
                    guard !Task.isCancelled, reloadGeneration == generation else { return }
                    markdownChanges = changes
                    hasUnannouncedChanges = !changes.isEmpty
                }
                reloadTask = nil
                data = bytes
                applyReload(reloadsWeb: reloadRequiresWebRefresh)
            } catch {
                guard let self, !Task.isCancelled, reloadGeneration == generation else { return }
                reloadTask = nil
                if reloadOwnsProgress { isRendering = false }
                reloadOwnsProgress = false
                reloadRequiresRefresh = false
                reloadRequiresWebRefresh = false
                showToast(
                    Toast(
                        systemImage: "exclamationmark.triangle",
                        title: String(
                            localized: "The file could not be reloaded. The last preview is still available."),
                        detail: error.localizedDescription),
                    dismissAfter: nil)
            }
        }
    }

    private func applyReload(reloadsWeb: Bool) {
        pendingPrintIssue = nil
        dropSpot()
        reloadOwnsProgress = false
        reloadRequiresRefresh = false
        reloadRequiresWebRefresh = false
        renderTask?.cancel()
        renderer.clearCache()
        themeTrial.clear()
        themeSamples.invalidate()
        imageBundle?.clearCache()
        binder?.clearCache()
        if reloadsWeb {
            // The page starts over from the new file, and paper follows it; a copy of the old page is not used.
            cancelCapture()
            liveSnapshot = nil
            web.reload()
            webZoom = web.zoom
        }
        computeContentHash()
        refreshIncludePlan()
        render()
    }

    /// A window without a file takes what its feed sends, as a file's window takes a change of the file.
    func replaceContent(_ bytes: Data, format: DocumentFormat) {
        guard fileURL == nil, binder == nil, imageBundle == nil, bytes != data || format != self.format else { return }
        data = bytes
        self.format = format
        applyReload(reloadsWeb: false)
    }

    /// The bytes of a document that exists only in this window.
    var memoryContent: Data? { fileURL == nil && binder == nil && imageBundle == nil ? data : nil }

    private func refreshIncludePlan() {
        includeTask?.cancel()
        guard format == .markdown, imageBundle == nil, binder == nil, let fileURL else {
            includePlan = nil
            return
        }
        let data = data
        // A sandboxed app cannot look next to the file before the folder is allowed, so all it names counts until then.
        let canReadFolder = !SandboxEnvironment.isSandboxed || folderLease != nil
        includeTask = Task { [weak self] in
            let plan = await Task.detached(priority: .utility) {
                MarkdownIncludes(markdown: TextDecoding.decode(data).text).map {
                    canReadFolder ? $0.plan(parent: fileURL) : $0.plan(parent: fileURL, exists: { _ in true })
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            includePlan = plan?.offersBinder == true ? plan : nil
            offerIncludes()
        }
    }

    private func offerIncludes() {
        guard let includePlan, !hasOfferedIncludes, toast == nil else { return }
        hasOfferedIncludes = true
        // It only invites: the document is open and readable as it is, and the Document menu keeps the way there.
        showToast(
            Toast(
                systemImage: "books.vertical",
                title: String(format: String(localized: "%lld documents can be loaded"), includePlan.documents.count),
                action: .openIncludes),
            dismissAfter: .seconds(10))
    }

    /// The toast's and the Document menu's Open as Binder. The binder takes the place of this window.
    func openIncludesAsBinder() {
        guard includePlan != nil, let fileURL else { return }
        dismissToast()
        if SandboxEnvironment.isSandboxed, folderLease == nil {
            opensIncludesWithAccess = true
            allowFolderAccess()
            return
        }
        // The files may have come or gone since the plan was made.
        guard let plan = MarkdownIncludes(markdown: TextDecoding.decode(data).text)?.plan(parent: fileURL),
            !plan.documents.isEmpty
        else { return }
        OpenRouter.shared.open(includes: plan)
        window?.close()
    }

    func reloadLibrary() {
        if !library.themes.contains(where: { $0.id == themeID }) { themeID = "standard" }
        codePaletteID = Self.knownCodePaletteID(codePaletteID, library) ?? CodePalette.matchesStyleID
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

    func goToBinderDocument(_ url: URL) {
        guard let binder, binder.urls.contains(url) else { return }
        binder.selection = url
        if mode == .print {
            trayRequest = url
            resolveTrayRequest()
        } else if mode == .view, let index = binder.pageStarts[url] {
            currentPageIndex = index
            paper.goToPage(index: index)
        }
    }

    func goToBundleImage(_ url: URL) {
        guard let bundle = imageBundle else { return }
        bundle.selection = url
        if mode == .print {
            trayRequest = url
            resolveTrayRequest()
        } else if mode == .view, let index = readableImageIndex(of: url) {
            currentPageIndex = index
            paper.goToPage(index: index)
        }
    }

    /// The page of the image being read, which keeps its place when images are added in front of it.
    private var selectedImagePage: Int? { imageBundle?.selection.flatMap(readableImageIndex(of:)) }

    private func readableImageIndex(of url: URL) -> Int? {
        imageBundle?.urls.filter { !unreadableImageURLs.contains($0) }.firstIndex(of: url)
    }

    /// A row of the list stands for its document, not for a place on sheets that may be about to change. It turns into
    /// a row of the tray once the sheets on it are the ones of the list as it is.
    private func resolveTrayRequest() {
        guard mode == .print, let url = trayRequest, isUpToDate, hasCurrentPrintPreview, let printTray else { return }
        trayRequest = nil
        let page: Int? =
            binder != nil
            ? binder?.pageStarts[url].map { $0 + 1 } : readableImageIndex(of: url).flatMap(printTray.bodyPage(at:))
        requestedTrayRow = page.flatMap(printTray.rowID(containing:))
    }

    /// The settings changed, as the view tells. A render in flight settles the back-side correction once it knows
    /// which way the sheets lie, which changes the settings to what that render is already making; starting over for
    /// that would cancel it for nothing.
    func renderForChangedSettings() {
        if isRendering, let renderingSettings, renderingSettings == renderSettings { return }
        render()
    }

    func render() {
        renderStartCount += 1
        renderingSettings = nil
        reloadOwnsProgress = false
        renderTask?.cancel()
        // A trial was laid out under the previous settings or file.
        themeTrial.end()
        if let openFailure {
            pendingPrint = nil
            error = openFailure
            isRendering = false
            finishFirstRender(succeeded: false)
            return
        }
        guard let settings = renderSettings else {
            pendingPrint = nil
            error = String(localized: "Print styles could not be loaded. Reload them in Settings.")
            isRendering = false
            finishFirstRender(succeeded: false)
            return
        }
        error = nil
        isRendering = true
        renderingSettings = settings
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
            var settings = settings
            do {
                let source: DocumentSource
                if let binder {
                    source = try await binder.source()
                    if let hash = binder.setHash { didComputeHash(hash) }
                    if sourceURLs != self.sourceURLs || settings != renderSettings {
                        render()
                        return
                    }
                } else if let imageBundle {
                    source = try await imageBundle.source()
                    // The digests and the key of their set change together, so nothing is saved under a mixed state.
                    if imageBundle.archiveURL == nil, let hash = imageBundle.setHash { didComputeHash(hash) }
                } else {
                    source = withFolderAccess(singleSource)
                }
                let prepared = try await renderer.prepare(source, settings: settings)
                try Task.checkCancellation()
                if renderer.logicalRenderCount != layoutsBefore { lastLayoutDuration = ContinuousClock.now - started }
                // The paper shows the logical pages right away; the sheets for the tray and the outputs follow.
                settings.options.rotatesBackSides = mode == .print && printerRotation(for: prepared.layout)
                renderingSettings = settings
                result = prepared
                if source.format == .markdown { displayedMarkdownData = source.data }
                chosenTrial = nil
                refreshStructure(of: source, in: prepared)
                announceChanges(in: prepared)
                renderedSettings = settings
                renderedSourceURLs = sourceURLs
                renderedFromSnapshot = fromSnapshot
                unreadableImageURLs = prepared.unreadableImageURLs
                binder?.didRender(prepared, forReading: mode == .view)
                // The tray lays the documents out on its own paper, whose pages are not the ones being read.
                if mode == .view, let page = binder?.settleReadingPage() ?? selectedImagePage {
                    currentPageIndex = page
                }
                resolveViewOptionsIfNeeded(for: prepared.viewDocument)
                if let imageBundle {
                    // The digests of the images are known now, so a remembered order can be restored.
                    if let order = pendingImageOrder {
                        pendingImageOrder = nil
                        // Restoring the remembered order is part of opening the document, not a change to save.
                        if imageBundle.applyOrder(order) { settingsBaseline = rememberedSettings }
                    }
                }
                let output = try await renderer.composeSheet(
                    for: prepared, rotatesBackSides: settings.options.rotatesBackSides)
                try Task.checkCancellation()
                printResult = output
                if mode == .print, settings == renderSettings {
                    trayFigures = TrayFigures(
                        settings: settings, data: data, sourceURLs: sourceURLs, sheetCount: output.plan.sheetCount,
                        paper: output.plan.paper.shortName)
                }
                printTray = PrintTray(
                    plan: output.plan, layout: output.layout, rotatesBackSides: settings.options.rotatesBackSides,
                    sheetOrientations: output.sheetOrientations, blankPages: output.blankPages,
                    notePages: output.notePages)
                isRendering = false
                resolveTrayRequest()
                finishFirstRender(succeeded: true)
                resolvePrintIssueNavigation()
                retriedChangedImages = false
                if prepared.requiredFolderAccess != nil { requestFolderAccess() }
                // A render that a later change made stale leaves the output to the render that follows it.
                if pendingPrint != nil, settings == renderSettings { resumePendingPrint() }
                if let output = outputAfterReview, mode == .print, settings == renderSettings {
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
                if case DocumentRenderer.RenderingError.noReadableDocuments(let urls) = error { binder?.didFail(urls) }
                self.error = Self.message(for: error)
                pendingPrint = nil
                pendingPrintIssue = nil
                outputAfterReview = nil
                chosenTrial = nil
                isRendering = false
                finishFirstRender(succeeded: false)
            }
        }
    }

    private func finishFirstRender(succeeded: Bool) {
        let report = onFirstRender
        onFirstRender = nil
        report?(succeeded)
    }

    /// The list changed under a tray that showed the old documents: nothing waiting to print may go out with the new
    /// ones unseen, and the pages are made again.
    func listDidChange() {
        pendingPrint = nil
        outputAfterReview = nil
        render()
    }

    /// Whether an output is waiting for pages, to go out by itself once they are ready.
    var hasWaitingOutput: Bool { pendingPrint != nil || outputAfterReview != nil }

    /// Carries on from the window this one replaces, with the look the reader has and the place being read.
    func takeOver(from source: DocumentViewModel) {
        keepsSettingsOverSaved = true
        if source.usesPrintTheme {
            themeID = source.themeID
            setTextScale(source.textScale)
            codePaletteID = source.codePaletteID
            codeBlock = source.codeBlock
        }
        if source.usesHTMLPreset { presetID = source.presetID }
        bookletBinding = source.bookletBinding
        layoutID = source.layoutID
        shownPaperSeries = source.shownPaperSeries
        paperSeries = source.paperSeries
        paperOrientation = source.paperOrientation
        printOptions = source.printOptions
        viewOptions = source.viewOptions
        hasResolvedViewOptions = true
        zoom = source.zoom
        bandVisibility = source.bandVisibility
        isAlwaysOnTop = source.isAlwaysOnTop
        currentPageIndex = source.currentPageIndex
        restoredPaperSize = source.currentPaperSize ?? source.viewPaperSizeBeforePrinting
        viewPaperSizeBeforePrinting = source.viewPaperSizeBeforePrinting
        // The pages are made for where they will be shown.
        if source.mode == .print { mode = .print }
    }

    /// This window opens on the tray, in the place of a window that was there.
    func settleOnTray() {
        guard mode == .print, let window else { return }
        hasSizedWindow = true
        refreshPrinters()
        ViewerWindow.setTrafficLightsVisible(true, in: window)
        PrintModeWindow.enter(window, size: traySize)
    }

    /// Back where a window was before a binder took its place.
    func restoreWindow(_ origin: BinderOrigin) {
        hasSizedWindow = true
        currentPageIndex = origin.pageIndex
        paper.goToPage(index: origin.pageIndex)
        guard let window else { return }
        ViewerWindow.setFrame(origin.frame, of: window, animate: false)
    }

    func setTextScale(_ value: Double) {
        guard usesPrintTheme, TextScale.steps.contains(value) else { return }
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
        // Joined pages lose this much on every side, which uneven margins must not take out of the text.
        return CGFloat(settings.layout.logicalMargins(options: settings.options).smallest * 72 / 25.4)
    }

    /// Whether the margin shows on the pages view mode displays. PDFs keep their own margins, and the 3-up handout
    /// insets the sheet instead of its logical pages.
    var marginsApply: Bool { (binder != nil || format != .pdf) && renderLayout.kind != .handout3 }

    /// Whether the margin changes the printed sheets: everything but PDFs, including the 3-up handout's sheet.
    var marginsAffectPrinting: Bool { binder != nil || format != .pdf }

    /// The presets, plus the current margin when it is none of them, so the menu always checks the current value.
    var marginChoices: [Double] {
        guard let current = printOptions.margins.uniformValue, !Self.marginPresets.contains(current) else {
            return Self.marginPresets
        }
        return (Self.marginPresets + [current]).sorted()
    }

    private static func clampedMargin(_ millimeters: Double) -> Double {
        // Margins go in whole millimeters; a record from an earlier version can still hold a fraction.
        min(max(millimeters.rounded(), marginRange.lowerBound), marginRange.upperBound)
    }

    /// The one way to give all four margins one value, so the viewer and the tray re-paginate and remember it the same
    /// way.
    func setMargins(_ millimeters: Double) {
        guard millimeters.isFinite else { return }
        printOptions.margins = .uniform(Self.clampedMargin(millimeters))
        printOptions.linksMargins = true
    }

    /// Changes one margin, or all four while the tray keeps them together.
    func setMargin(_ side: WritableKeyPath<PageMargins, Double>, to millimeters: Double) {
        guard millimeters.isFinite else { return }
        guard !printOptions.linksMargins else { return setMargins(millimeters) }
        printOptions.margins[keyPath: side] = Self.clampedMargin(millimeters)
    }

    /// Keeping the margins together evens them out to the top margin.
    func setMarginsLinked(_ linked: Bool) {
        printOptions.linksMargins = linked
        if linked { printOptions.margins = .uniform(printOptions.margins.top) }
    }

    /// The unshifted US key for ⌥⌘+ must work in both the viewer and the print tray, before PDFKit handles ⌘=.
    func handleTextSizeKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]) == [.option, .command],
            event.charactersIgnoringModifiers == "="
        else { return false }
        increaseTextSize()
        return true
    }

    /// ⌘= is the unshifted Zoom In key on US keyboards, which the menu's ⌘+ does not take. The paper of the view mode
    /// takes it as a key of its own; the tray has no view that takes keys.
    func handleTrayZoomKey(_ event: NSEvent) -> Bool {
        guard mode == .print, let trayZoomer,
            event.modifierFlags.intersection([.command, .option, .control]) == [.command],
            event.charactersIgnoringModifiers == "="
        else { return false }
        trayZoomer.zoomIn()
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
        pendingPrintIssue = nil
        dropSpot()
        guard mode != .print else { return }
        guard mode == .view, isWebPresentation || isCapturingWeb || webCaptureFailed else { return showPrintTray() }
        // The tray prints the page as it is now.
        captureWeb { [weak self] outcome in
            guard let self else { return }
            if outcome == .failed {
                outputAfterReview = nil
                showCaptureFailure()
            } else {
                showPrintTray()
                // An unchanged copy with the same layout needs no render to resume the waiting output.
                if let output = outputAfterReview, canOutput {
                    outputAfterReview = nil
                    run(output)
                }
            }
        }
    }

    private func closeBandPopovers() {
        isViewOptionsPresented = false
        isOutlinePresented = false
        isFiguresPresented = false
    }

    /// The tray keeps the window's frame for the way back, so a new window goes there only after it has taken the
    /// paper's shape; until then the request waits for `enterRequestedPrintMode()`.
    func requestPrintMode() {
        isPrintModeRequested = true
        if !isRendering, hasSizedWindow || error != nil { enterRequestedPrintMode() }
    }

    func enterRequestedPrintMode() {
        guard isPrintModeRequested, !isRendering else { return }
        isPrintModeRequested = false
        enterPrintMode()
    }

    private func showPrintTray() {
        guard mode != .print else { return }
        refreshPrinters()
        themePaletteDidClose()
        closeBandPopovers()
        // The tray shows what prints, so the review and its outlined pages end here.
        isReviewingSmartRemoval = false
        viewPaperSizeBeforePrinting = currentPaperSize ?? viewPaperSizeBeforePrinting
        mode = .print
        guard let window else { return }
        // Stage controls need free resizing and visible traffic lights.
        ViewerWindow.setTrafficLightsVisible(true, in: window)
        PrintModeWindow.enter(window, size: traySize)
    }

    /// The tray keeps the list beside the sheets, which need their own room next to it.
    var traySize: NSSize {
        var size = PrintModeWindow.traySize
        if binder != nil || imageBundle != nil { size.width += SidePanelMetrics.width }
        return size
    }

    func enterCompareMode() {
        guard mode == .view, usesPrintTheme else { return }
        pendingPrintIssue = nil
        dropSpot()
        isThemePalettePresented = false
        themeTrial.end()
        closeBandPopovers()
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
        ViewerWindow.setTrafficLightsVisible(true, in: window)
        PrintModeWindow.enter(window, size: PrintModeWindow.compareSize)
    }

    /// Back to the view mode, by the same way as from the print tray.
    func exitCompareMode() {
        guard mode == .compare else { return }
        isComparePlacePickerPresented = false
        exitPrintMode()
    }

    func exitPrintMode() {
        pendingPrint = nil
        trayRequest = nil
        requestedTrayRow = nil
        guard mode != .view else { return }
        isPrintIssuesPresented = false
        themePaletteDidClose()
        outputAfterReview = nil
        guard let window else {
            resetPrintChoices()
            mode = .view
            resumePrintIssueNavigation()
            return
        }
        resetPrintChoices()
        PrintModeWindow.exit(window) { [weak self] in
            guard let self else { return }
            ViewerWindow.markResizing(window, for: 0.3)
            mode = .view
            ViewerWindow.setTrafficLightsVisible(isBandAlwaysVisible, in: window)
            // The view mode shows only the paper, and the print layout may have changed the pages' shape on the
            // stage, so the window keeps its height and takes the pages' width again.
            if returnsToRestoredPaperSize {
                returnsToRestoredPaperSize = false
                applyRestoredPaperSize()
            } else {
                sizeWindowToPaper(keepHeight: true)
            }
            resumePrintIssueNavigation()
        }
    }

    /// The tray's choices of what to print last only while it is shown; paper then shows the current state again.
    private func resetPrintChoices() {
        // A half-typed range is not kept: it would hold back an output asked for from the view mode.
        if isPageRangeUnreadable { setPageRange(pageRange) }
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
        if !enabled { isReviewingSmartRemoval = false }
    }

    // Review outlines belong to paper in view mode, even when requested from the print tray.
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

    var isBandAlwaysVisible: Bool {
        get { bandVisibility == .always }
        set { bandVisibility = newValue ? .always : .onHover }
    }

    func toggleBandVisibility() { isBandAlwaysVisible.toggle() }

    // MARK: - Table of contents and figures

    /// The live page has no pages to go to.
    var hasOutline: Bool { !outlineEntries.isEmpty && !showsWeb }
    var showsOutlineDrawer: Bool {
        isOutlineDrawerOpen && hasOutline && preferences.outlinePresentation == .drawer
    }
    var isOutlineShown: Bool { isOutlinePresented || showsOutlineDrawer }

    private static let outlineDrawerMinimumWindowWidth: CGFloat = 560

    func toggleOutline() {
        switch preferences.outlinePresentation {
        case .popover: isOutlinePresented.toggle()
        case .drawer:
            // The drawer takes its width from the paper, which a narrow window does not have to spare.
            if (window?.frame.width ?? .infinity) < Self.outlineDrawerMinimumWindowWidth {
                isOutlineDrawerOpen = false
                isOutlinePresented.toggle()
            } else {
                isOutlineDrawerOpen.toggle()
            }
        }
    }

    /// The last page on screen, so that a chapter starting on the right of a spread counts as being read.
    private var lastVisiblePageIndex: Int {
        let units = displayUnits
        return SpreadLayout.unitIndex(containing: currentPageIndex + 1, in: units)
            .flatMap { units[$0].pages.max() }.map { $0 - 1 } ?? currentPageIndex
    }

    var currentOutlineEntry: Int? { DocumentOutline.currentEntry(in: outlineEntries, page: lastVisiblePageIndex) }

    func goToOutlineEntry(_ entry: OutlineEntry) {
        guard let page = entry.pageIndex else { return }
        isOutlinePresented = false
        paper.goToPage(index: page)
    }

    /// 「刷り台で確かめる」 in the figures.
    /// What the print screen last came to, for the document's information.
    struct TrayFigures {
        let settings: RenderSettings
        let data: Data
        let sourceURLs: [URL]
        let sheetCount: Int
        let paper: String
    }

    /// The sheets of the print screen, as long as nothing they were counted from has changed since.
    var currentTrayFigures: TrayFigures? {
        guard let trayFigures, trayFigures.settings == renderSettings(in: .print), trayFigures.data == data,
            trayFigures.sourceURLs == sourceURLs
        else { return nil }
        return trayFigures
    }

    func checkFiguresOnTray() {
        isFiguresPresented = false
        enterPrintMode()
    }

    /// Reads the headings of the pages just laid out for reading, and how much text the document holds. Only the
    /// pages' text is read on the main actor, a page at a time; the conversion runs elsewhere and only when the source
    /// changed.
    private func refreshStructure(of source: DocumentSource, in prepared: PreparedRender) {
        guard mode != .print, structureDocument !== prepared.logicalDocument else { return }
        structureDocument = prepared.logicalDocument
        structureTask?.cancel()
        let document = prepared.logicalDocument
        guard binder == nil, imageBundle == nil, source.images == nil, source.children == nil else { return }
        if source.format == .pdf {
            outlineEntries = PDFOutlineReader.entries(of: document)
            return
        }
        guard source.format.isWebRendered else { return }
        structureTask = Task { [weak self] in
            guard let self else { return }
            let known = readStructure?.source == source ? readStructure : nil
            let read: (headings: [DocumentHeading], statistics: DocumentStatistics, contents: [String])?
            if let known {
                read = (known.headings, known.statistics, known.contents)
            } else {
                read = await Task.detached(priority: .utility) {
                    DocumentRenderer.structureHTML(of: source).map {
                        (
                            DocumentOutline.headings(inHTML: $0), DocumentStatistics(html: $0),
                            DocumentOutline.sourceContentsEntries(inHTML: $0)
                        )
                    }
                }.value
            }
            guard !Task.isCancelled, let read else { return }
            readStructure = (source, read.headings, read.statistics, read.contents)
            documentStatistics = read.statistics
            var texts: [String] = []
            for index in 0..<(read.headings.isEmpty ? 0 : document.pageCount) {
                texts.append(document.page(at: index)?.string ?? "")
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
            let headings = read.headings
            let pages = texts
            // A table the finish hides is not on the pages, and its lines would be taken from the real headings.
            let contents = !finishAppliesToText || printFinish.toc.showsSourceContents ? read.contents : []
            let entries = await Task.detached(priority: .utility) {
                DocumentOutline.entries(of: headings, inPageTexts: pages, contentsEntries: contents)
            }.value
            guard !Task.isCancelled else { return }
            outlineEntries = entries
        }
    }

    // MARK: - Changes in the file

    /// Tells the reader about the changes of a reload, once, as soon as the pages with their marks are ready.
    private func announceChanges(in prepared: PreparedRender) {
        guard hasUnannouncedChanges else { return }
        hasUnannouncedChanges = false
        guard mode == .view, !prepared.changeMarks.isEmpty else { return }
        switch preferences.changeFollowing {
        case .mark: break
        case .jump:
            // A change already in view is where the reader should be.
            let pages = prepared.changeMarks.map(\.pageIndex)
            if let page = ChangeNavigation.next(after: currentPageIndex - 1, in: pages) { currentPageIndex = page }
        case .ask:
            showToast(
                Toast(
                    systemImage: "pencil",
                    title: String(format: String(localized: "%lld places changed"), markdownChanges.count),
                    action: .nextChange),
                dismissAfter: Self.changeNoticeDuration)
        }
    }

    private static let changeNoticeDuration = Duration.seconds(8)

    /// The notice's 「次の変更へ」; it stays as long as the reader keeps following it.
    func goToNextChange() {
        let pages = paperChangeMarks.map(\.pageIndex)
        if let page = ChangeNavigation.next(after: lastVisiblePageIndex, in: pages) { paper.goToPage(index: page) }
        if let toast { showToast(toast, dismissAfter: Self.changeNoticeDuration) }
    }

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
        if presentation == .web {
            closeBandPopovers()
            return applyWebShape()
        }
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
            let settingsBeforeCompletions = renderSettings
            webCaptureFailed = snapshot == .failed
            var needsRender = false
            if case .captured(let copy) = snapshot, copy != liveSnapshot {
                liveSnapshot = copy
                // The pages of the previous state must not show or print in the meantime.
                result = nil
                printResult = nil
                printTray = nil
                needsRender = true
                isRendering = true
            }
            let outcome: CaptureOutcome = snapshot == .failed ? .failed : isRendering ? .rendering : .ready
            for completion in completions { completion(outcome) }
            // A changed layout is rendered by DocumentContent's settings observer. Otherwise the new copy still
            // needs a render here. Never paginate once for reading and again for the tray, or start both paths.
            if needsRender, settingsBeforeCompletions == renderSettings { render() }
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
        // A request waiting on this capture must not survive a reload and run on a later visit to the tray.
        outputAfterReview = nil
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

    var allowsLiveJavaScript: Bool { format == .html && renderSettings?.allowsPageJavaScript == true }

    /// A global or preset policy change must also stop scripts in a page kept off screen.
    func javaScriptSettingDidChange() {
        web.applyJavaScriptSetting(allowsLiveJavaScript)
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

    func zoomIn() {
        if mode == .print {
            trayZoomer?.zoomIn()
        } else if showsWeb {
            web.zoomIn()
        } else {
            paper.zoomIn()
        }
    }

    func zoomOut() {
        if mode == .print {
            trayZoomer?.zoomOut()
        } else if showsWeb {
            web.zoomOut()
        } else {
            paper.zoomOut()
        }
    }

    func zoomToFit() {
        if mode == .print {
            trayZoomer?.zoomToFit()
        } else if showsWeb {
            web.resetZoom()
        } else {
            paper.zoomToFit()
        }
    }

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
            themeID: usesPrintTheme ? themeID : nil,
            textScale: usesPrintTheme ? textScale : nil, presetID: usesHTMLPreset ? presetID : nil,
            smartRemoval: format == .html && (isSmartRemovalEnabled || !smartRemovalKeptIDs.isEmpty)
                ? DocumentSettings.SmartRemoval(isEnabled: isSmartRemovalEnabled, keptIDs: smartRemovalKeptIDs) : nil,
            printOptions: printOptions,
            imageOrder: imageBundle.flatMap { $0.isSortedByName ? nil : $0.orderDigests },
            paperOrientation: paperOrientation, htmlPresentation: usesHTMLPresentation ? htmlPresentation : nil,
            ignoresSlides: usesHTMLPresentation && ignoresSlides ? true : nil,
            binderOrder: binder.flatMap { $0.isInStartingOrder ? nil : $0.orderDigests },
            binderStartsOnFront: binder != nil ? binderStartsOnFront : nil,
            printFinish: finishAppliesToText ? printFinish : nil,
            codePaletteID: usesPrintTheme ? codePaletteID : nil,
            codeBlock: usesPrintTheme && codeBlock != CodeBlockOptions() ? codeBlock : nil,
            bandVisibility: bandVisibility == defaultBandVisibility ? nil : bandVisibility,
            paperSeries: paperSeries == .a ? nil : paperSeries,
            notes: offersNotes && notes != NotePages() ? notes : nil, bookletBinding: bookletBinding,
            pageRange: pageRange.isAll ? nil : pageRange)
    }

    func savePrintSettingSet(named name: String) {
        var set = PrintSettingSet(name: name, settings: rememberedSettings)
        // A set saved without notes turns them off, which a document's record has no need to say.
        if offersNotes { set.notes = notes }
        preferences.savePrintSettingSet(set)
        selectedSettingSetID = preferences.printSettingSets.first { $0.name == name }?.id
    }

    /// The set the tray names: the one last chosen, or else one that happens to match.
    var activeSettingSet: PrintSettingSet? {
        let sets = PrintSettingSet.builtIns(language: language) + preferences.printSettingSets
        return sets.first { $0.id == selectedSettingSetID } ?? sets.first(where: matchesPrintSettingSet)
    }

    var isSettingSetChanged: Bool {
        guard let set = activeSettingSet else { return false }
        return !matchesPrintSettingSet(set)
    }

    /// Saves the current settings over the active set, which only the reader's own sets allow.
    func overwriteActiveSettingSet() {
        guard let set = activeSettingSet, !set.isBuiltIn else { return }
        savePrintSettingSet(named: set.name)
    }

    private func applicablePrintSettingSet(_ set: PrintSettingSet) -> PrintSettingSet {
        var set = set.applicable(
            to: Set(binder?.items.map(\.format) ?? [format]),
            themeIDs: Set(library.themes.map(\.id)), presetIDs: Set(library.presets.map(\.id)))
        if !offersNotes { set.notes = nil }
        // A binder can hold texts and still have no page breaks or contents of its own to compare.
        if !finishAppliesToText { set.finish = nil }
        return set
    }

    func matchesPrintSettingSet(_ set: PrintSettingSet) -> Bool {
        applicablePrintSettingSet(set).matches(rememberedSettings)
    }

    func applyPrintSettingSet(_ set: PrintSettingSet) {
        let set = applicablePrintSettingSet(set)
        if let id = set.layoutID { layoutID = id }
        if let orientation = set.paperOrientation { paperOrientation = orientation }
        if let margins = set.margins { printOptions.margins = margins }
        printOptions.linksMargins = set.linksMargins ?? (printOptions.margins.uniformValue != nil)
        if let mirrors = set.mirrorsMargins { printOptions.mirrorsMargins = mirrors }
        if let furniture = set.furniture { printOptions.furniture = furniture }
        if let finish = set.finish { printFinish = finish }
        if let notes = set.notes { self.notes = notes }
        selectedSettingSetID = set.id
        if let id = set.themeID { themeID = id }
        if let scale = set.textScale { setTextScale(scale) }
        if let id = set.presetID { presetID = id }
        // Applying a set is a user change, not a new baseline or a theme-menu selection.
        rememberedSettingsDidChange()
    }

    /// What this document has when the user changes nothing. Until the pages are known, the reading layout is the
    /// initial guess, so a layout chosen while the pages are prepared still counts as a change.
    private var defaultSettings: DocumentSettings {
        DocumentSettings(
            view: defaultViewOptions ?? initialViewOptions, zoom: 1, layoutID: Self.defaultLayoutID(preferences),
            themeID: usesPrintTheme ? Self.defaultThemeID(preferences, library) : nil,
            textScale: usesPrintTheme ? defaultTextScale : nil,
            presetID: usesHTMLPreset ? Self.defaultPresetID(preferences, library) : nil,
            printOptions: preferences.printOptions, paperOrientation: defaultPaperOrientation,
            htmlPresentation: usesHTMLPresentation ? .web : nil,
            binderStartsOnFront: binder != nil ? false : nil,
            printFinish: finishAppliesToText ? preferences.printFinish : nil,
            codePaletteID: usesPrintTheme ? Self.defaultCodePaletteID(preferences, library) : nil)
    }

    private static func defaultLayoutID(_ preferences: AppPreferences) -> String {
        PrintLayout.presets.contains(where: { $0.id == preferences.layoutID })
            ? preferences.layoutID : PrintLayout.a4Single.id
    }

    private static func defaultThemeID(_ preferences: AppPreferences, _ library: UserLibrary) -> String {
        library.themes.contains(where: { $0.id == preferences.themeID }) ? preferences.themeID : "standard"
    }

    private static func defaultCodePaletteID(_ preferences: AppPreferences, _ library: UserLibrary) -> String {
        knownCodePaletteID(preferences.defaultCodePaletteID, library) ?? CodePalette.matchesStyleID
    }

    private static func knownCodePaletteID(_ id: String, _ library: UserLibrary) -> String? {
        id == CodePalette.matchesStyleID || library.codePalette(id) != nil ? id : nil
    }

    private static func defaultPresetID(_ preferences: AppPreferences, _ library: UserLibrary) -> String {
        library.presets.contains(where: { $0.id == preferences.presetID }) ? preferences.presetID : "none"
    }

    /// Single files and ZIPs are keyed by their bytes; a bundle of image files once its images are read.
    private func computeContentHash() {
        guard binder == nil, imageBundle == nil || imageBundle?.archiveURL != nil else { return }
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
        let previousSources = hashedSourceURLs
        contentHash = hash
        hashedSourceURLs = Set(sourceURLs)
        if let previous {
            // Saved in an editor while open: the settings on screen carry over to the new content.
            guard hasSavedSettings, saveSettings() else { return }
            // The same files no longer have the content the previous record described, so every save in the editor
            // would leave one more record behind and push other documents' settings out of the store. A set that
            // gained or lost a file still exists as it was, and keeps its record.
            if previousSources == hashedSourceURLs, createdRecordKeys.remove(previous.hex) != nil {
                try? settingsStore?.removeRecord(for: previous.hex)
            }
            return
        }
        let saved = settingsStore?.record(for: hash.hex)
        if keepsSettingsOverSaved, saved != nil {
            // What this window took over replaces the record, even where it equals the defaults.
            settingsBaseline = defaultSettings
            saveSettings(force: true)
            return
        }
        guard let saved else {
            // Anything that already differs from the defaults was changed by the user while the content was read.
            settingsBaseline = defaultSettings
            rememberedSettingsDidChange()
            return
        }
        apply(saved)
        hasSavedSettings = true
        settingsBaseline = rememberedSettings
    }

    private func apply(_ saved: DocumentSettings) {
        binderStartsOnFront = saved.binderStartsOnFront ?? false
        bandVisibility = saved.bandVisibility ?? defaultBandVisibility
        paperSeries = saved.paperSeries ?? .a
        if let order = saved.binderOrder { binder?.applyOrder(order) }
        if let scale = saved.textScale { setTextScale(scale) }
        if let view = saved.view {
            viewOptions = view
            hasResolvedViewOptions = true
        }
        if let zoom = saved.zoom { self.zoom = min(max(zoom, 1), PaperPDFView.maximumZoom) }
        if let orientation = saved.paperOrientation { paperOrientation = orientation }
        bookletBinding = saved.bookletBinding
        if let id = saved.layoutID, PrintLayout.presets.contains(where: { $0.id == id }) { layoutID = id }
        if let id = saved.themeID, library.themes.contains(where: { $0.id == id }) { themeID = id }
        if let id = saved.codePaletteID.flatMap({ Self.knownCodePaletteID($0, library) }) { codePaletteID = id }
        if let block = saved.codeBlock { codeBlock = block }
        if let id = saved.presetID, library.presets.contains(where: { $0.id == id }) { presetID = id }
        if let options = saved.printOptions { printOptions = options }
        if let finish = saved.printFinish, finishAppliesToText { printFinish = finish }
        if let notes = saved.notes, offersNotes { self.notes = notes }
        if let range = saved.pageRange { setPageRange(range) }
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
        if let binder, binder.setHash != contentHash { return }
        guard contentHash != nil, let settingsBaseline, rememberedSettings != settingsBaseline else { return }
        scheduleSave()
    }

    /// Saves now what a change scheduled; quitting ends the app before the delay has passed.
    func flushPendingSettings() {
        if saveTask != nil { saveSettings() }
    }

    private func scheduleSave() {
        guard settingsStore != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.saveSettings()
        }
    }

    /// Returns whether a record was written.
    @discardableResult
    private func saveSettings(force: Bool = false) -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard let contentHash, let settingsStore else { return false }
        if let binder, binder.setHash != contentHash { return false }
        // A change that was undone before the save (for example a transient zoom) is not a change.
        guard force || hasSavedSettings || rememberedSettings != settingsBaseline || didResizeWindow else {
            return false
        }
        var settings = rememberedSettings
        settings.windowSize = currentPaperSize ?? viewPaperSizeBeforePrinting ?? restoredPaperSize
        do {
            let key = contentHash.hex
            let isNew = !createdRecordKeys.contains(key) && settingsStore.record(for: key) == nil
            try settingsStore.save(settings, for: key)
            if isNew { createdRecordKeys.insert(key) }
            hasSavedSettings = true
            didResizeWindow = false
            settingsBaseline = rememberedSettings
            return true
        } catch {
            Self.logger.error("Saving document settings failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Goes back to the defaults at once; the toast and the window's undo are the way back.
    func resetDocumentSettings() {
        let origin = ResetOrigin(
            settings: rememberedSettings, wasSaved: hasSavedSettings, selectedSettingSetID: selectedSettingSetID,
            paperSize: currentPaperSize ?? viewPaperSizeBeforePrinting ?? restoredPaperSize,
            defaultTextScale: defaultTextScale,
            defaultPaperOrientation: defaultPaperOrientation, defaultBandVisibility: defaultBandVisibility,
            openingViewDefaults: openingViewDefaults, defaultViewOptions: defaultViewOptions)
        applyDefaultSettings(resizesWindow: true)
        resetOrigin = origin
        showToast(
            Toast(
                systemImage: "arrow.uturn.backward", title: String(localized: "Settings reset"), action: .undoReset),
            dismissAfter: Self.undoNoticeDuration)
        settingsHistory?.registerUndo(withTarget: self) { $0.restoreSettings(origin) }
        settingsHistory?.setActionName(Self.resetActionName)
    }

    /// The toast's Undo. It goes through the window's history while the reset is its latest step, so that Redo
    /// follows; otherwise it restores directly and the step left in the history does nothing.
    func undoResetDocumentSettings() {
        guard let origin = resetOrigin, !origin.isRestored else { return }
        if let undo = settingsHistory, undo.canUndo, undo.undoActionName == Self.resetActionName {
            undo.undo()
        } else {
            restoreSettings(origin)
        }
    }

    private func restoreSettings(_ origin: ResetOrigin) {
        guard !origin.isRestored else { return }
        origin.isRestored = true
        resetOrigin = nil
        dismissToast()
        // A record leaves out what equals the defaults, so the defaults come first, as they were for this window.
        applyDefaultSettings(resizesWindow: mode == .view && origin.paperSize == nil)
        defaultTextScale = origin.defaultTextScale
        defaultPaperOrientation = origin.defaultPaperOrientation
        defaultBandVisibility = origin.defaultBandVisibility
        openingViewDefaults = origin.openingViewDefaults
        defaultViewOptions = origin.defaultViewOptions
        apply(origin.settings)
        selectedSettingSetID = origin.selectedSettingSetID
        restoreViewPaperSize(origin.paperSize)
        settingsBaseline = defaultSettings
        if origin.wasSaved { saveSettings(force: true) } else { rememberedSettingsDidChange() }
        settingsHistory?.registerUndo(withTarget: self) { $0.resetDocumentSettings() }
        settingsHistory?.setActionName(Self.resetActionName)
    }

    /// The size is the view mode's. On a stage the window is the stage's, so the size waits for the way back and
    /// is what a save there takes in.
    private func restoreViewPaperSize(_ size: CGSize?) {
        restoredPaperSize = size
        guard let size else { return }
        if mode == .view {
            applyRestoredPaperSize()
        } else {
            viewPaperSizeBeforePrinting = size
            returnsToRestoredPaperSize = true
        }
    }

    /// The history of a window the app opened itself. A file's own window keeps its history with the document, where
    /// a step would mark the file as edited, and this app never writes one.
    private var settingsHistory: UndoManager? {
        window?.windowController?.document == nil ? window?.undoManager : nil
    }

    private static var resetActionName: String { String(localized: "Reset Document Settings") }
    /// As long as the binder's notice with Undo stays.
    static let undoNoticeDuration: Duration = .seconds(8)

    private func applyDefaultSettings(resizesWindow: Bool) {
        dismissToast()
        saveTask?.cancel()
        saveTask = nil
        if let contentHash {
            try? settingsStore?.removeRecord(for: contentHash.hex)
            createdRecordKeys.remove(contentHash.hex)
        }
        hasSavedSettings = false
        pendingImageOrder = nil
        restoredPaperSize = nil
        returnsToRestoredPaperSize = false
        defaultTextScale = preferences.defaultTextScale
        defaultPaperOrientation = preferences.defaultPaperOrientation
        defaultBandVisibility = preferences.defaultBandVisibility
        bandVisibility = defaultBandVisibility
        paperSeries = .a
        textScale = usesPrintTheme ? defaultTextScale : 1
        paperOrientation = defaultPaperOrientation
        layoutID = Self.defaultLayoutID(preferences)
        bookletBinding = nil
        themeID = Self.defaultThemeID(preferences, library)
        codePaletteID = Self.defaultCodePaletteID(preferences, library)
        codeBlock = CodeBlockOptions()
        presetID = Self.defaultPresetID(preferences, library)
        printOptions = preferences.printOptions
        printFinish = preferences.printFinish
        notes = NotePages()
        setPageRange(.all)
        isWritingFurniture = false
        selectedSettingSetID = nil
        isSmartRemovalEnabled = false
        smartRemovalKeptIDs = []
        isReviewingSmartRemoval = false
        zoom = 1
        setIgnoresSlides(false)
        setHTMLPresentation(.web)
        imageBundle?.sortByName()
        binder?.resetOrder()
        binderStartsOnFront = false
        openingViewDefaults = preferences.viewDefaults
        if let document = result?.viewDocument {
            defaultViewOptions = ViewOptions.resolved(
                for: viewDefaultsContext(for: document), preferences: openingViewDefaults)
        }
        if let defaultViewOptions { viewOptions = defaultViewOptions }
        if resizesWindow, mode == .view, let window, let unit = paperUnitSize {
            ViewerWindow.setPaperSize(
                ViewerWindow.initialPaperSize(unit: unit, on: window.screen, side: sideInset), band: bandInset,
                of: window,
                animate: true, side: sideInset)
        }
        settingsBaseline = rememberedSettings
    }

    // MARK: - Window geometry

    /// One page, or a spread, at 100 %.
    var paperUnitSize: CGSize? {
        guard let document = result?.viewDocument, document.pageCount > 0 else { return nil }
        let page = PageSizes.representative(
            (0..<document.pageCount).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                return PageSizes.displayed(page.bounds(for: .cropBox).size, rotation: page.rotation)
            })
        guard page.width > 0, page.height > 0 else { return nil }
        return viewOptions.layout == .single || showsNarrowCover
            ? page : CGSize(width: page.width * 2, height: page.height)
    }

    /// The paper shows the cover of a spread alone, one page wide.
    var showsNarrowCover: Bool {
        mode == .view && !isWebPresentation && viewOptions.narrowsCover(at: shownPageIndex, width: loneCoverWidth)
    }

    /// Opening the cover or closing back onto it changes the window's width; the edge of the binding stays where it
    /// is, as when a book opens: the cover of a left-to-right book is a right-hand page.
    func coverWidthDidChange() {
        sizeWindowToPaper(keepHeight: true, keepsRightEdge: viewOptions.direction == .leftToRight)
    }

    var menuArrangement: MenuArrangement { preferences.menuArrangement }

    /// The room the bands take beside the paper, whether or not they show.
    private var bandInset: CGFloat { Self.bandInset(of: menuArrangement) }

    private static func bandInset(of arrangement: MenuArrangement) -> CGFloat {
        ViewerWindow.bandHeight * CGFloat(arrangement.bandCount)
    }

    /// The paper the window shows in the view mode. Before the first pages fit the window to the paper, its size is
    /// only where it opened, and remembering that would open the document that small next time.
    var currentPaperSize: CGSize? {
        guard mode == .view, hasSizedWindow, let window else { return nil }
        let content = window.contentRect(forFrameRect: window.frame).size
        return CGSize(width: (content.width - sideInset).rounded(), height: (content.height - bandInset).rounded())
    }

    /// Fits the window to the paper: the first time at a comfortable or remembered size, later keeping the height.
    func sizeWindowToPaper(keepHeight: Bool = false, initialOnly: Bool = false, keepsRightEdge: Bool = false) {
        guard !initialOnly || !hasSizedWindow else { return }
        guard mode == .view, let window, let unit = paperUnitSize else { return }
        guard hasSizedWindow else {
            hasSizedWindow = true
            if restoredPaperSize != nil {
                applyRestoredPaperSize()
            } else {
                ViewerWindow.setPaperSize(
                    ViewerWindow.initialPaperSize(unit: unit, on: window.screen, side: sideInset), band: bandInset,
                    of: window,
                    animate: false, side: sideInset)
            }
            // A web page opens at the paper's size but reflows to any shape the reader gives the window.
            if isWebPresentation { applyWebShape(animate: false) }
            return
        }
        guard !isWebPresentation else { return applyWebShape() }
        let height = ViewerWindow.paperHeight(of: window, band: bandInset)
        ViewerWindow.setPaperSize(
            paperSize(unit: unit, height: height, in: window), band: bandInset, of: window, animate: keepHeight,
            keepsRightEdge: keepsRightEdge, side: sideInset)
    }

    /// The paper of the unit's shape at `height`. A window stopped at the screen's edge at full height would leave
    /// empty room above and below the paper, so the height gives way too.
    private func paperSize(unit: CGSize, height: CGFloat, in window: NSWindow) -> CGSize {
        let wanted = heightBeforeScreenLimit ?? height
        let size = ViewerWindow.paperSize(unit: unit, height: wanted, on: window.screen, widthShare: 1, side: sideInset)
        heightBeforeScreenLimit = size.height < wanted - 1 ? wanted : nil
        return size
    }

    private func applyRestoredPaperSize() {
        guard let window, let unit = paperUnitSize, let size = restoredPaperSize else { return }
        // Keep the remembered height; the width follows the pages as they are now.
        ViewerWindow.setPaperSize(
            paperSize(unit: unit, height: size.height, in: window), band: bandInset, of: window, animate: false,
            side: sideInset)
    }

    /// The paper keeps its size and place when the bands change: the window grows or shrinks at the bottom.
    func menuArrangementDidChange(from previous: MenuArrangement) {
        guard mode == .view, let window else { return }
        let paper = CGSize(
            width: window.contentRect(forFrameRect: window.frame).width - sideInset,
            height: ViewerWindow.paperHeight(of: window, band: Self.bandInset(of: previous)))
        ViewerWindow.setPaperSize(paper, band: bandInset, of: window, animate: true, side: sideInset)
        if isWebPresentation { applyWebShape(animate: false) }
    }

    func windowDidEndLiveResize() {
        // The window size remembered is the paper's; the web page takes whatever size the reader likes.
        guard mode == .view, !isWebPresentation, let window, !ViewerWindow.isResizingProgrammatically(window),
            let unit = paperUnitSize
        else { return }
        heightBeforeScreenLimit = nil
        // The aspect ratio can only approximate "paper plus fixed bands"; settle on the exact size for the width the
        // user chose.
        let width = window.contentRect(forFrameRect: window.frame).width - sideInset
        ViewerWindow.setPaperSize(
            CGSize(width: width, height: (width * unit.height / unit.width).rounded()), band: bandInset,
            of: window, animate: false, side: sideInset)
        guard contentHash != nil, settingsBaseline != nil else { return }
        didResizeWindow = true
        scheduleSave()
    }

    private func withFolderAccess(_ source: DocumentSource) -> DocumentSource {
        var source = source
        source.allowedResourceFolders = folderLease.map { [$0.url] } ?? []
        return source
    }

    func requestFolderAccess() {
        guard SandboxEnvironment.isSandboxed, fileURL != nil || binder != nil, toast?.action != .allowFolderAccess
        else { return }
        showToast(
            Toast(
                systemImage: "folder",
                title: String(localized: "Allow folder access to display images and other resources"),
                action: .allowFolderAccess),
            dismissAfter: nil)
    }

    func allowFolderAccess() {
        guard SandboxEnvironment.isSandboxed,
            let fileURL = fileURL ?? binder?.fileRequiringAccess(result?.requiredFolderAccess), let window
        else { return }
        let folder = fileURL.deletingLastPathComponent()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = String(
            localized: "Choose the document’s folder or a parent folder to display images and other resources.")
        panel.prompt = String(localized: "Allow Access")
        panel.beginSheetModal(for: window) { [weak self] response in
            let opensIncludes = self?.opensIncludesWithAccess == true
            self?.opensIncludesWithAccess = false
            guard let self, response == .OK, let selected = panel.url else { return }
            guard LocalResourceAccess.contains(folder, in: selected) else {
                showToast(
                    Toast(systemImage: "folder", title: String(localized: "Choose a folder containing this document")))
                return
            }
            do {
                try FolderAccess.shared.remember(selected)
                guard let lease = FolderAccess.shared.acquire(for: fileURL) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                if let binder {
                    lease.close()
                    binder.clearCache()
                    dismissToast()
                    renderer.clearCache()
                    render()
                    return
                }
                folderLease?.close()
                folderLease = lease
                web.allowedResourceFolders = [lease.url]
                dismissToast()
                renderer.clearCache()
                themeSamples.invalidate()
                themeTrial.end()
                cancelCapture()
                liveSnapshot = nil
                web.reload()
                render()
                if opensIncludes { openIncludesAsBinder() }
            } catch {
                showToast(
                    Toast(
                        systemImage: "exclamationmark.triangle",
                        title: String(localized: "Folder access could not be saved")))
            }
        }
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

    /// Outputs use the tray's layout even when requested from reading or comparison. The view observes the changed
    /// render settings and draws once; do not start a second render here or output the reading pages in the meantime.
    private func deferUntilPrintMode(_ output: Output) -> Bool {
        guard mode != .print else { return false }
        outputAfterReview = output
        enterPrintMode()
        guard mode == .print, canOutput else { return true }
        // A4 single-sided may already be composed, so no settings change will trigger another render.
        outputAfterReview = nil
        return false
    }

    /// An output asked for during the review ends it and waits for the pages without the outlines.
    private func deferUntilReviewEnds(_ output: Output) -> Bool {
        guard isReviewingSmartRemoval else { return false }
        isReviewingSmartRemoval = false
        outputAfterReview = output
        return true
    }

    var printerLayout: PrintLayout {
        if let result, renderedSettings?.layout == layout,
            renderedSettings?.paperOrientation == paperOrientation
        {
            return result.layout
        }
        // Until preparation resolves Auto, this value is provisional; calibration and test printing stay disabled.
        return layout.oriented(paperOrientation == .landscape)
    }

    private func printerRotation(for layout: PrintLayout) -> Bool {
        preferences.printerProfile(for: selectedPrinterName).rotation(
            for: layout.sentDuplex, default: preferences.rotateBack)
    }

    var rotatesBackSides: Bool {
        get { printerRotation(for: printerLayout) }
        set {
            guard canOutput, let name = selectedPrinterName, printerLayout.sentDuplex != .none else { return }
            preferences.setPrinterRotation(newValue, for: name, duplex: printerLayout.sentDuplex)
        }
    }

    var effectivePrintOptions: PrintOptions {
        var options = printOptions
        options.rotatesBackSides = mode == .print && rotatesBackSides
        return options
    }

    var printPageOrder: PrintPageOrder {
        get {
            preferences.printerProfile(for: selectedPrinterName).resolvedPageOrder(default: preferences.printPageOrder)
        }
        set {
            guard let name = selectedPrinterName else { return }
            preferences.setPrinterPageOrder(newValue, for: name)
        }
    }

    /// The printer Print sends to: the one chosen on the tray while it is set up, otherwise the system's default.
    var selectedPrinterName: String? { printers.resolve(preferences.printerName) }

    func refreshPrinters() {
        let current = printerListSource()
        if current != printers { printers = current }
        loadPrinterCapabilities()
    }

    func selectPrinter(_ name: String) {
        preferences.printerName = name
        loadPrinterCapabilities()
    }

    struct DuplexTestResult: Identifiable {
        let id = UUID()
        let printerName: String
        let duplex: DuplexMode
    }

    var canPrintDuplexTest: Bool {
        canOutput && printerLayout.sentDuplex != .none && pendingPrint == nil && duplexTestResult == nil
    }

    func answerDuplexTest(rotatesBackSides: Bool?) {
        guard let test = duplexTestResult else { return }
        if let rotatesBackSides {
            preferences.setPrinterRotation(rotatesBackSides, for: test.printerName, duplex: test.duplex)
        }
        duplexTestResult = nil
    }

    func printDuplexTest() {
        guard canPrintDuplexTest, window != nil || duplexTestSubmit != nil else { return }
        let shown = selectedPrinterName
        let layout = printerLayout
        refreshPrinters()
        // The test is a plain two-sided sheet of the tray's paper, which is what the printer has to be able to do.
        let request = printRequest(
            quick: true, shown: shown, layout: (try? DuplexTestRenderer().layout(for: layout)) ?? layout)
        let language = language
        isPrinting = true
        outputError = nil
        duplexTestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let renderer = DuplexTestRenderer()
                let testLayout = try renderer.layout(for: layout)
                let labels = DuplexTestRenderer.Labels(
                    front: PrintModeText.string("Front", language: language),
                    back: PrintModeText.string("Back", language: language),
                    top: PrintModeText.string("Top", language: language),
                    binding: PrintModeText.string(
                        layout.sentDuplex == .longEdge ? "Long-edge binding" : "Short-edge binding", language: language),
                    printer: request.printerName ?? PrintModeText.string("No Printers", language: language),
                    instruction: PrintModeText.string(
                        layout.sentDuplex == .longEdge
                            ? "Turn the sheet along its long edge. The back arrow should point up."
                            : "Turn the sheet along its short edge. The back arrow should point up.", language: language
                    ))
                let document = try await renderer.document(sheet: layout.sheet, labels: labels)
                try Task.checkCancellation()
                let complete: (DuplexTestResult?) -> Void = { [weak self] result in
                    self?.isPrinting = false
                    self?.duplexTestResult = result
                }
                if let duplexTestSubmit {
                    duplexTestSubmit(document, testLayout, request, complete)
                } else {
                    submitDuplexTest(document, layout: testLayout, request: request, complete: complete)
                }
            } catch {
                isPrinting = false
                if !(error is CancellationError) {
                    outputError = String(localized: "The print job could not be created.")
                }
            }
        }
    }

    /// Made apart from running it, so that what would be sent can be read without a printer.
    func makeDuplexTestOperation(for document: PDFDocument, layout: PrintLayout, request: PrintRequest)
        -> NSPrintOperation?
    {
        let destination = request.printerName.flatMap(NSPrinter.init(name:))
        return PrintJobFactory().printOperation(
            for: document, layout: layout, showsPrintPanel: request.showsPanel || destination == nil,
            printer: destination, pageOrder: .firstSheetFirst,
            jobTitle: Self.duplexTestJobTitle(language: language))
    }

    private func submitDuplexTest(
        _ document: PDFDocument, layout: PrintLayout, request: PrintRequest,
        complete: @escaping (DuplexTestResult?) -> Void
    ) {
        guard let window, let operation = makeDuplexTestOperation(for: document, layout: layout, request: request)
        else {
            outputError = String(localized: "The print job could not be created.")
            complete(nil)
            return
        }
        // A single test sheet must not inherit a previous job's copies or page range.
        let info = operation.printInfo
        info.dictionary()[NSPrintInfo.AttributeKey.copies] = 1
        info.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
        let completion = PrintCompletion { [weak self] success in
            guard let self else { return }
            printOperation = nil
            printCompletion = nil
            guard success, info.jobDisposition == .spool else {
                complete(nil)
                return
            }
            var duplex = PMDuplexMode(kPMDuplexNone)
            let expected = PrintJobFactory.duplexMode(for: layout)
            guard PMGetDuplex(OpaquePointer(info.pmPrintSettings()), &duplex) == noErr,
                duplex == expected
            else {
                outputError = String(
                    localized:
                        "The binding changed in the print dialog. Run the duplex test again without changing the binding."
                )
                complete(nil)
                return
            }
            // The system dialog can select another printer. Save only the printer that actually received the job.
            complete(DuplexTestResult(printerName: info.printer.name, duplex: layout.sentDuplex))
        }
        printCompletion = completion
        printOperation = operation
        operation.runModal(
            for: window, delegate: completion,
            didRun: #selector(PrintCompletion.didRun(_:success:context:)), contextInfo: nil)
    }

    /// Prints the sheets: right away to the selected printer when `quick`, otherwise through the system dialog,
    /// which starts on that printer.
    func printDocument(quick: Bool = false) {
        guard pendingPrint == nil else { return }
        guard !deferUntilPrintMode(.print(quick: quick)),
            !deferUntilWebIsCaptured(.print(quick: quick)), !deferUntilReviewEnds(.print(quick: quick))
        else {
            return
        }
        guard canOutput else { return }
        // Known before the sheets are: an output that waits for them is already one through the dialog.
        let quick = quick && issue(sending: printerLayout, to: selectedPrinterName) == nil
        pendingPrint = PendingPrint(
            request: PrintRequest(printerName: selectedPrinterName, showsPanel: !quick), quick: quick)
        resumePendingPrint()
    }

    private func resumePendingPrint() {
        guard var pending = pendingPrint else { return }
        guard mode == .print else {
            pendingPrint = nil
            return
        }
        refreshPrinters()
        // Once a destination change required the panel, later refreshes must not turn the job into a quick print.
        pending.request = printRequest(
            quick: !pending.request.showsPanel, shown: pending.request.printerName, layout: printerLayout)
        // The system dialog starts with the same number, where it can still be changed.
        pending.request.copies = copies
        pendingPrint = pending
        guard renderedSettings == renderSettings else {
            render()
            return
        }
        guard canOutput, let result = printResult else {
            pendingPrint = nil
            return
        }
        let request = pending.request
        let pageOrder = printPageOrder
        pendingPrint = nil
        if let printSubmit { return printSubmit(result, request, pageOrder) }
        if let outputOverride { return outputOverride(.print(quick: pending.quick), result) }
        guard let window else { return }
        outputError = nil
        let destination = request.printerName.flatMap(NSPrinter.init(name:))
        // Without a printer the system dialog still offers saving a PDF or adding a printer.
        let quick = !request.showsPanel && destination != nil
        guard let operation = makePrintOperation(for: result, request: request, pageOrder: pageOrder)
        else {
            outputError = String(localized: "The print job could not be created.")
            return
        }
        // The sheets are already the pages asked for, so a page range left over from another job must not cut them.
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
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

    /// Made apart from running it, so that what would be sent can be read without a printer.
    func makePrintOperation(for result: RenderResult, request: PrintRequest, pageOrder: PrintPageOrder)
        -> NSPrintOperation?
    {
        let destination = request.printerName.flatMap(NSPrinter.init(name:))
        return PrintJobFactory().printOperation(
            for: result.sheetDocument, layout: result.layout, showsPrintPanel: request.showsPanel || destination == nil,
            printer: destination, pageOrder: pageOrder, copies: request.copies, jobTitle: printJobTitle)
    }

    func exportPDF() {
        guard !deferUntilPrintMode(.exportPDF),
            !deferUntilWebIsCaptured(.exportPDF), !deferUntilReviewEnds(.exportPDF)
        else { return }
        guard canOutput, let result = printResult else { return }
        if let outputOverride { return outputOverride(.exportPDF, result) }
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

    static func exportName(fileURL: URL?, layout: PrintLayout, language: String, title: String? = nil) -> String {
        // A clipboard title carries a time such as "0:13"; Finder shows ":" in a file name as "/".
        let name = (title ?? fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Document"))
            .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        return "\(name)（\(layout.displayName(language: language))）.pdf"
    }

    static func summaryText(_ summary: PrintSummary, layout: PrintLayout, locale: Locale) -> String {
        let language = UILanguage.candidates(for: locale.identifier).first { UILanguage.supported.contains($0) } ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let bindingKey =
            switch layout.sentDuplex {
            case .none: "Single-sided"
            case .longEdge: "Duplex, long edge"
            case .shortEdge: "Duplex, short edge"
            }
        let binding = bundle.localizedString(forKey: bindingKey, value: nil, table: nil)
        let template = bundle.localizedString(forKey: "%ld pages → %@ %ld sheets (%@)", value: nil, table: nil)
        return String(
            format: template, locale: locale,
            summary.logicalPageCount, summary.paper.shortName, summary.sheetCount, binding)
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? DocumentRenderer.RenderingError else { return error.localizedDescription }
        switch error {
        case .noReadableDocuments: return String(localized: "None of the documents could be opened.")
        case .noReadableImages: return String(localized: "None of the images could be opened.")
        case .imageChanged: return String(localized: "The images keep changing. Try reloading the document.")
        case .invalidPDF: return String(localized: "This PDF could not be opened.")
        case .encryptedPDF: return String(localized: "Encrypted PDFs cannot be printed. Open an unlocked copy.")
        case .textDecodingFailed: return String(localized: "The text encoding could not be read without data loss.")
        case .invalidMargins:
            return String(localized: "The margins are too large for this page. Change them in Settings.")
        case .invalidNotePage:
            return String(localized: "These note page lines do not fit on the page. Reduce the margin or the spacing.")
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
