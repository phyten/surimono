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
    let chosenReadingOrder: (direction: ViewOptions.Direction?, axis: ViewOptions.ScrollAxis?)
    let wasSaved: Bool
    let selectedSettingSetID: UUID?
    /// The paper's size in the view mode, as a record would take it in, whichever mode the reset was done in.
    let paperSize: CGSize?
    let defaultTypeface: Typeface
    let defaultTextScale: Double
    let defaultPaperOrientation: PaperOrientation
    let defaultBandVisibility: BandVisibility
    let openingViewDefaults: ViewDefaultPreferences
    let defaultViewOptions: ViewOptions?
    var isRestored = false

    init(
        settings: DocumentSettings, chosenReadingOrder: (ViewOptions.Direction?, ViewOptions.ScrollAxis?),
        wasSaved: Bool, selectedSettingSetID: UUID?, paperSize: CGSize?,
        defaultTextScale: Double, defaultTypeface: Typeface, defaultPaperOrientation: PaperOrientation,
        defaultBandVisibility: BandVisibility, openingViewDefaults: ViewDefaultPreferences,
        defaultViewOptions: ViewOptions?
    ) {
        self.settings = settings
        self.chosenReadingOrder = chosenReadingOrder
        self.wasSaved = wasSaved
        self.selectedSettingSetID = selectedSettingSetID
        self.paperSize = paperSize
        self.defaultTypeface = defaultTypeface
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
    var showsDismissButton = true

    static var folderAccess: Toast {
        Toast(
            systemImage: "folder", title: String(localized: "Showing images needs permission to read the folder"),
            action: .allowFolderAccess)
    }
}

@Observable
final class DocumentViewModel {
    private var folderLease: FolderAccess.Lease?
    /// Access to files handed in from outside the app, which this window reads for as long as it is open.
    private var fileAccess: [FolderAccess.Lease] = []
    /// Whether the window of this model has registered and so had its turn to take the access that waited for its
    /// file. A model that ends before that gives the waiting access up; one that ends after it leaves alone what
    /// waits, which is then for a newer request to open the same file.
    @ObservationIgnored var hasTakenItsFileAccess = false
    let fileURL: URL?
    let isStreamingPreview: Bool
    /// The file name a document came with when it has no file of that name (a file handed over by Shortcuts),
    /// which names its language.
    let sourceFileName: String?
    let htmlBaseURL: URL?
    private let title: String?
    let imageBundle: ImageBundleModel?
    let binder: BinderModel?
    var binderStartsOnFront = false
    var usesPrintTheme: Bool { binder?.usesPrintTheme ?? format.usesPrintTheme }
    var usesHTMLPreset: Bool { binder?.usesHTMLPreset ?? format.usesHTMLPreset }
    private(set) var unreadableImageURLs: [URL] = []
    private var renderedSourceURLs: [URL] = []
    private(set) var format: DocumentFormat
    private(set) var data: Data {
        didSet {
            dataGeneration += 1
            orgFileInstructions = nil
        }
    }
    /// Counts the contents the window has held, so that what a layout read is only taken for the contents it read.
    @ObservationIgnored private(set) var dataGeneration = 0
    /// The language of a source file. Until the first layout has decoded the text it is what the name alone tells,
    /// and after a reload it stays what it was until the new text is laid out: decoding up to 30 MB to name a badge
    /// is not work for the main actor.
    private(set) var detectedSourceLanguage: SourceLanguage?
    private(set) var classStyle: String?
    private(set) var classLayout: PrintLayout?
    var themeFormat: DocumentFormat? { binder == nil && imageBundle == nil ? format : nil }
    var availableThemes: [PrintTheme] {
        library.themes.filter { $0.isAvailable(for: themeFormat, classStyle: classStyle) }
    }

    private var defaultThemeID: String {
        library.defaultThemeID(preferred: preferences.themeID, format: themeFormat, classStyle: classStyle)
    }
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
    var themeID: String {
        didSet {
            guard oldValue != themeID,
                theme(themeID)?.flow == .vertical
                    || library.themes.first(where: { $0.id == oldValue })?.flow == .vertical
            else { return }
            let defaults = viewDefaults(forTheme: themeID)
            viewOptions.direction = chosenReadingOrder.direction ?? defaults.direction
            viewOptions.scrollAxis = chosenReadingOrder.axis ?? defaults.scrollAxis
        }
    }
    private var chosenReadingOrder: (direction: ViewOptions.Direction?, axis: ViewOptions.ScrollAxis?) = (nil, nil)

    private func viewDefaults(forTheme id: String?) -> ViewOptions {
        (defaultViewOptions ?? initialViewOptions).following(
            id.flatMap { theme($0)?.flow } ?? .horizontal, preferredScrollAxis: openingViewDefaults.scrollAxis)
    }
    /// An axis of its own: choosing another style leaves it as it is. A palette the user picks goes through
    /// `selectCodePalette(_:)`.
    var codePaletteID: String
    private var chosenCodeBlock: CodeBlockOptions?
    private var defaultCodeBlock: CodeBlockOptions { sourceLanguage == nil ? CodeBlockOptions() : .sourcePage }
    var codeBlock: CodeBlockOptions {
        get { chosenCodeBlock ?? defaultCodeBlock }
        set { chosenCodeBlock = newValue == defaultCodeBlock ? nil : newValue }
    }
    private(set) var typeface: Typeface
    var isReadingPanelOpen = false
    // Disclosure choices live with this window, including while its panel is closed.
    private var orgGroupExpansion: [OrgReadingGroup: Bool] = [:]

    func orgGroupExpanded(_ group: OrgReadingGroup) -> Bool {
        orgGroupExpansion[group] ?? (group == .tasks && orgFileInstructions?.hasTaskElements == true)
    }

    func setOrgGroupExpanded(_ expanded: Bool, for group: OrgReadingGroup) {
        orgGroupExpansion[group] = expanded
    }

    var offersOrgReading: Bool { format == .org && binder == nil && imageBundle == nil }
    var showsReadingPanel: Bool { mode == .view && offersOrgReading && isReadingPanelOpen }
    private(set) var orgFileInstructions: OrgFileInstructions?
    var orgDocumentReading = OrgDocumentReadingSettings()
    var orgReading: OrgReadingSettings {
        OrgReadingSettings(
            defaults: preferences.orgReadingDefaults ?? .surimono,
            document: binder == nil && format == .org ? orgDocumentReading : .init())
    }

    private var savedComposition = LaTeXComposition.document {
        didSet { if oldValue != savedComposition { renderer.clearCache() } }
    }
    #if DEBUG
        var snapshotComposition: LaTeXComposition?
    #endif
    var latexComposition: LaTeXComposition {
        #if DEBUG
            if let snapshotComposition { return snapshotComposition }
        #endif
        return savedComposition
    }
    private(set) var textScale: Double
    var presetID: String
    var printOptions: PrintOptions
    /// Where a text breaks and how it shows its contents; only texts have any.
    var printFinish: PrintFinish
    /// Pages to write on among the document's own. They belong to the paper, so the reading view leaves them out.
    var notes = NotePages()
    /// A new document starts at one copy. Reopening a closed clipboard window restores its own count.
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
    var mode: ViewerMode = .view {
        didSet {
            if mode != .view { dismissProseMark() }
            // Leaving the tray cancels its outstanding sheets even when both modes use identical settings.
            if oldValue == .print, mode == .view, isRendering, composingSheets { render() }
        }
    }
    private var openingViewDefaults: ViewDefaultPreferences
    // Keep the baseline stable if Settings changes while the document is still opening.
    private var defaultTypeface: Typeface
    private var defaultTextScale: Double
    private var defaultPaperOrientation: PaperOrientation
    private var defaultBandVisibility: BandVisibility
    var loneCoverWidth: LoneCoverWidth { preferences.loneCoverWidth }
    var viewOptions: ViewOptions {
        didSet {
            if viewOptions.layout != oldValue.layout || viewOptions.showsCoverAlone != oldValue.showsCoverAlone {
                selectedReadingPage = nil
            }
        }
    }
    /// Magnification relative to fitting the current page or spread into the window.
    var zoom: Double = 1
    var pageHistory = PageHistory()
    var bookmarks = Bookmarks()
    let scrubber = PageScrubSession()
    var offersScrubber: Bool { menuArrangement == .split && canNavigateReading && paperPageCount > 1 }
    var thumbnailGeneration: Int? { isUpToDate && paperDocument === result?.viewDocument ? result?.id : nil }
    /// The selected half of a spread; PDFView reports only its first page.
    var selectedReadingPage: Int? {
        didSet {
            if oldValue != selectedReadingPage, window?.isRestorable == true { window?.invalidateRestorableState() }
        }
    }

    @ObservationIgnored private var pendingRestoredPage: Int?
    var pageForWindowRestoration: Int { pendingRestoredPage ?? logicalReadingPage }

    /// The frame was set by AppKit. Let normal page fitting keep its top edge and current height.
    /// Pagination can finish after state decoding, and the source may have fewer pages now.
    func restoreReadingPage(_ page: Int) {
        hasSizedWindow = true
        pendingRestoredPage = max(0, page)
        applyRestoredPageIfReady()
    }

    private func applyRestoredPageIfReady() {
        guard let page = pendingRestoredPage, contentHash != nil, isUpToDate, pageCount > 0 else { return }
        pendingRestoredPage = nil
        navigateReadingPage(min(page, pageCount - 1))
    }

    /// The 0-based index of the first visible logical page.
    var currentPageIndex = 0 {
        didSet {
            if oldValue != currentPageIndex {
                if window?.isRestorable == true { window?.invalidateRestorableState() }
                selectedReadingPage = nil
                if !proseMark.spans.isEmpty {
                    proseMark.update(presented: true, generation: proseGeneration, readingPage: currentPageIndex)
                }
            }
            shownPageIndex = currentPageIndex
        }
    }
    /// The page the paper shows, which is a trial's page while a theme is tried; `currentPageIndex` keeps the reading
    /// position in the document's own pages for when the trial ends.
    var shownPageIndex = 0
    /// Whether the bands show all the time, in their own room beside the paper, or only on pointing, over its edges.
    var bandVisibility: BandVisibility {
        didSet {
            guard bandVisibility != oldValue else { return }
            let previous = Self.bandRoom(of: menuArrangement, oldValue, revealed: revealedBandRoom, top: topBandHeight)
            // Bands that always show keep their room; the pointer no longer gives or takes it.
            revealedBandRoom = BandRoom()
            areHoverBandsShown = false
            pendsBandRoomRelease = false
            bandRoomDidChange(from: previous, animate: false)
        }
    }
    /// The room bands that show on pointing have made for themselves: the window grew by it around the paper.
    private(set) var revealedBandRoom = BandRoom()
    /// Whether bands that show on pointing are out, which they can be without any room: at the top of the screen they
    /// lie over the paper.
    @ObservationIgnored private var areHoverBandsShown = false
    /// The bands hid while the reader was resizing the window; their room goes when the resize ends.
    @ObservationIgnored private var pendsBandRoomRelease = false
    /// From the start of entering full screen until it has been left: the frame is the system's then, so the view
    /// mode's sizing leaves it alone and catches up once the window is back.
    /// Observed: the top band takes its plain height while there are no traffic lights to line up with.
    private(set) var isInFullScreen = false
    /// The room of the bands in the frame the system gives back on leaving full screen.
    @ObservationIgnored private var fullScreenReturnRoom: BandRoom?
    /// The paper the window showed before full screen, remembered for the document in place of the screen's size.
    @ObservationIgnored private var paperSizeBeforeFullScreen: CGSize?
    /// Counts the attempts to enter full screen, so that a late check finds out whether it is still about its own.
    @ObservationIgnored private var fullScreenAttempt = 0
    var isAlwaysOnTop: Bool
    var showsOnAllSpaces: Bool
    private var readerOpenedDrawer = false
    var isDrawerOpen: Bool {
        get { readerOpenedDrawer || drop.isListSprung }
        set { readerOpenedDrawer = newValue }
    }
    var showsSideList: Bool { isDrawerOpen && (binder != nil || imageBundle != nil) }
    var sideInset: CGFloat {
        if showsReadingPanel { return OrgReadingPanel.width }
        guard mode == .view, showsSideList else { return 0 }
        return imageBundle == nil ? SidePanelMetrics.width : contentsWidth
    }
    /// The row of the tray to bring into view, for the sheets on it now.
    var requestedTrayRow: Int?
    /// What a row of the list asked the tray to show, until the sheets that hold it are ready.
    @ObservationIgnored private var trayRequest: URL?
    /// The zoom of the tray on screen, which the menus' zoom commands drive in the print mode.
    @ObservationIgnored weak var trayZoomer: TrayZoomer?
    /// A file drag over this window.
    let drop = DropSession()
    /// Where the view mode's band parts stand, for the popovers that hang off them.
    let bandAnchors = BandAnchors()
    /// The window this binder took the place of, for as long as going back can bring it.
    @ObservationIgnored var binderOrigin: BinderOrigin?
    @ObservationIgnored var binderExit = BinderExit()
    @ObservationIgnored private var pendingBinderRestoration: BinderOrigin?
    @ObservationIgnored private var binderExitTrayPage: Int?
    @ObservationIgnored var binderTrayPageIndex: Int?
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
    var proseMark = ProsePaperMark()
    var goToTarget: GoToPage.Target?
    var isGoToPagePresented: Bool {
        get { goToTarget != nil }
        set { goToTarget = newValue ? (goToTarget ?? .page) : nil }
    }
    var isViewOptionsPresented = false
    var isOutlinePresented = false {
        didSet {
            if oldValue && !isOutlinePresented {
                dismissProseMark()
            }
            if !isOutlinePresented { outlineFilter.setQuery("", entries: outlineEntries) }
        }
    }
    var outlineFilter = OutlineFilterState()
    #if DEBUG
        var snapshotProseReady = false
        var snapshotOutlineDrawer = false
        var snapshotContentsTab: DocumentSettings.ContentsPanel.Tab?
        @ObservationIgnored var snapshotThumbnailRequests: [UUID: Bool] = [:]
    #endif
    var isOutlineDrawerOpen = false
    var contentsPanel = DocumentSettings.ContentsPanel()
    var contentsTab: DocumentSettings.ContentsPanel.Tab {
        #if DEBUG
            if let snapshotContentsTab, snapshotContentsTab != .prose || offersProse { return snapshotContentsTab }
        #endif
        if drop.isListSprung && imageBundle != nil && mode == .view { return .pages }
        if offersProse {
            return contentsPanel.tab ?? (hasOutline || (pageCount <= 1 && !bookmarkPages.isEmpty) ? .contents : .pages)
        }
        guard pageCount > 1 else { return .contents }
        guard hasOutline || !bookmarkPages.isEmpty else { return .pages }
        if let tab = contentsPanel.tab, tab != .prose { return tab }
        return hasOutline ? .contents : .pages
    }
    var offersProse: Bool {
        guard mode == .view, !isStreamingPreview, imageBundle == nil, binder == nil else { return false }
        if format == .markdown { return true }
        guard format == .plainText, sourceLanguage == nil else { return false }
        // A named file can turn out to be a script when its first line is decoded by the layout.
        return (fileURL == nil && sourceFileName == nil) || result?.facts != nil
    }
    var showsContentsTabs: Bool { offersProse || (pageCount > 1 && (hasOutline || !bookmarkPages.isEmpty)) }

    func openProse() {
        guard offersProse else { return }
        selectContentsTab(.prose)
        if !isOutlineShown { toggleOutline() }
    }

    var contentsWidth: CGFloat { min(400, max(176, contentsPanel.width ?? SidePanelMetrics.width)) }
    func selectContentsTab(_ tab: DocumentSettings.ContentsPanel.Tab) {
        if tab != .prose { dismissProseMark() }
        contentsPanel.tab = tab
        outlineFilter.setQuery("", entries: outlineEntries)
    }

    func setContentsOpen(_ open: Bool) {
        if !open { dismissProseMark() }
        if imageBundle != nil { isDrawerOpen = open } else { isOutlineDrawerOpen = open }
        contentsPanel.isOpen = open
    }

    func setSideListOpen(_ open: Bool) {
        if imageBundle != nil && mode == .view {
            isOutlinePresented = false
            setContentsOpen(open)
        } else {
            isDrawerOpen = open
        }
    }

    #if DEBUG
        // The window benchmark timestamps a visible tile after SwiftUI has installed its image.
        @ObservationIgnored var scrubThumbnailReady: ((Int, Int) -> Void)?
        var snapshotScrubWidth: CGFloat?
        var snapshotScrubImage: (generation: Int, page: Int)?
        @ObservationIgnored var thumbnailDidAppear: ((Int) -> Void)?
    #endif
    @ObservationIgnored private var thumbnailCache: PageThumbnails?
    func thumbnails(for generation: Int) -> PageThumbnails? {
        guard let result, generation == result.id, !isRendering else { return nil }
        if thumbnailCache == nil { thumbnailCache = PageThumbnails(result) }
        return thumbnailCache
    }

    var isLaTeXRecognitionPresented = false
    var isFiguresPresented = false
    var isPrintFinishPresented = false
    /// The section the print settings sheet scrolls to when it is set.
    var finishSection: PrintFinishSection?
    /// The note section's fine adjustments are open.
    var showsNoteAdjustments = false
    /// The reader chose to write the header and footer themselves, which an empty one does not show by its content.
    var isWritingFurniture = false
    var isPrintIssuesPresented = false
    /// The tray shows the booklet folded (「折ってみる」).
    var showsFold = false
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
    private(set) var chosenTrial: ChosenTrial?
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
    /// The reader turned off 「スライドとして表示」: the page is not a deck. Remembered for the document.
    private(set) var ignoresSlides = false
    /// The tray's 「今の 1 枚」: print only the slide shown on the web. It belongs to the visit to the tray.
    private(set) var printsCurrentSlideOnly = false
    /// Smart Removal (beta) for HTML: remove what is not the article, except the parts the user keeps.
    var isSmartRemovalEnabled = false
    var smartRemovalKeptIDs: [String] = []
    /// While reviewing, the paper outlines the detected parts instead of removing them.
    private(set) var isReviewingSmartRemoval = false
    /// A review must replace the outlined preview before releasing its output, even if the reader stays open.
    @ObservationIgnored private var waitingOutput: (action: Output, replacesReview: Bool)?
    var outputAfterReview: Output? {
        get { waitingOutput?.action }
        set {
            if newValue != waitingOutput?.action {
                waitingOutput = newValue.map { ($0, false) }
            }
        }
    }
    /// Replaces the system output UI in tests, after readiness checks, with the exact sheets being output.
    @ObservationIgnored var outputOverride: ((Output, RenderResult) -> Void)?
    /// Replaces submission after resolving the destination and matching its settings to the composed sheets.
    @ObservationIgnored var printSubmit: ((RenderResult, PrintRequest, PrintPageOrder) -> Void)?
    private struct PendingPrint {
        var request: PrintRequest
        let intent: PrintIntent
    }
    private var pendingPrint: PendingPrint?
    var manualDuplexSession: ManualDuplexSession?
    @ObservationIgnored var manualDuplexTask: Task<Void, Never>?
    @ObservationIgnored var manualDuplexSubmit:
        ((ManualDuplexSubmission, @escaping (ManualDuplexSubmissionResult) -> Void) -> Void)?
    /// Replaces saving the manual corrections for every session this window starts, so a snapshot never writes them.
    @ObservationIgnored var manualDuplexSaveCorrection: ((ManualDuplexCorrection) -> Void)?
    var duplexTestResult: DuplexTestResult?
    /// Replaces submission in tests so calibration never sends a physical print job.
    @ObservationIgnored var duplexTestSubmit:
        ((PDFDocument, PrintLayout, PrintRequest, @escaping (DuplexTestResult?) -> Void) -> Void)?
    private var duplexTestTask: Task<Void, Never>?
    private var otherToast: Toast?
    private var folderAccessNotice: Toast?
    private var closedFolderAccessNotice = false
    var toast: Toast? { otherToast ?? folderAccessNotice }
    /// What the document can be bound from; nil unless it names at least two documents that can be read.
    private(set) var includePlan: MarkdownIncludes.Plan?
    @ObservationIgnored private var includeTask: Task<Void, Never>?
    @ObservationIgnored private var hasOfferedIncludes = false
    /// The folder is being allowed on the way to the binder, which opens once the folder can be read.
    @ObservationIgnored private var opensIncludesWithAccess = false
    /// Replaces the save panel in tests.
    @ObservationIgnored var chooseSaveDestination: ((String, @escaping (URL?) -> Void) -> Void)?
    /// The logical pages the paper shows. They are published before the sheets are composed.
    private(set) var result: PreparedRender? { didSet { followViewFurniture(after: oldValue) } }
    /// The header and footer the paper draws. They follow the pages' own at once, except while the custom header is
    /// being typed, when they wait for a pause to avoid rebuilding the decorated pages at each keystroke.
    private(set) var shownFurniture: [Int: FurniturePlacement] = [:]
    @ObservationIgnored private var furnitureTask: Task<Void, Never>?
    /// How often the paper's header and footer changed, for tests.
    @ObservationIgnored private(set) var shownFurnitureChangeCount = 0
    static let furnitureTypingPause: Duration = .milliseconds(400)
    /// Waits out the pause in typing before the paper shows the new header; tests hold it open and let it go.
    @ObservationIgnored var awaitTypingPause: () async -> Void = {
        try? await Task.sleep(for: DocumentViewModel.furnitureTypingPause)
    }
    @ObservationIgnored private var dayObserver: (any NSObjectProtocol)?
    /// The composed sheets for the tray and the outputs. It may still belong to an earlier `result` while the sheets
    /// of the current one are composed; `canOutput` checks that it matches.
    private(set) var printResult: RenderResult?
    private var trayFigures: TrayFigures?
    /// The sheets of `printResult`, grouped as they come out of the printer; built once per composition.
    private(set) var printTray: PrintTray?
    /// The settings and the files `printTray` was composed with. The tray keeps showing its sheets while newer ones are
    /// composed (`showsTrayPreview`), and whatever describes them is read from the same generation (`shownSheets`).
    private(set) var printTraySettings: RenderSettings?
    @ObservationIgnored private(set) var printTraySourceURLs: [URL]?
    private(set) var renderedSettings: RenderSettings?
    /// What the render in flight is making, once its back-side correction is settled.
    @ObservationIgnored private var renderingSettings: RenderSettings?
    /// How many renders were started; a render that settles its own settings must not start another.
    @ObservationIgnored private(set) var renderStartCount = 0
    @ObservationIgnored private var pageUpdate = PageUpdateProgress()
    @ObservationIgnored private var pageUpdateTask: Task<Void, Never>?
    // A reload can invalidate paper without changing even one render setting.
    private enum ReloadedPages { case unchanged, reading, awaitingLayout, failed }
    private var reloadedPages = ReloadedPages.unchanged
    private(set) var pageUpdateDisplay = PageUpdateProgress.Display.hidden

    var pageUpdateState: PageUpdateProgress.State {
        guard mode == .view, result != nil, offersPaperSeries, !isCapturingWeb, error == nil else { return .inactive }
        switch reloadedPages {
        case .reading, .awaitingLayout: return .behind
        case .failed: return .inactive
        case .unchanged: break
        }
        if let chosenTrial, paperShowsTrial, chosenTrial.settings == renderSettings { return .current }
        return renderedSettings == renderSettings && renderedSourceURLs == sourceURLs
            && renderedFromSnapshot == rendersSnapshot
            ? .current : .behind
    }

    func refreshPageUpdate() {
        let previousDeadline = pageUpdate.nextDeadline
        let announcement = pageUpdate.update(pageUpdateState, at: .now)
        pageUpdateDisplay = pageUpdate.display
        switch announcement {
        case .started: ShortcutHints.announce(String(localized: "Updating pages"))
        case .finished: ShortcutHints.announce(String(localized: "Pages updated"))
        case nil: break
        }
        guard previousDeadline != pageUpdate.nextDeadline else { return }
        pageUpdateTask?.cancel()
        guard let deadline = pageUpdate.nextDeadline else {
            pageUpdateTask = nil
            return
        }
        pageUpdateTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            self?.refreshPageUpdate()
        }
    }

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
    private(set) var layoutTooLarge = false
    var offersPlainTextRecovery: Bool {
        format.isWebRendered && format != .plainText && format != .docx
            && (!layoutTooLarge || data.count <= PageLayoutLimits.plainTextBytes)
    }
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
    /// The copy in flight already opens the print tray when it arrives.
    @ObservationIgnored private var captureOpensTray = false
    /// The key of the remembered settings: the content hash of the file, of the ZIP, or of the set of images.
    private(set) var contentHash: ContentHash?
    private(set) var hasSavedSettings = false
    @ObservationIgnored let settingsStore: DocumentSettingsStore?
    @ObservationIgnored private let location: (key: String, store: KeyedRecordStore<ContentHash>)?
    /// The settings as last loaded, restored, reset or saved; any other value means the user changed something.
    @ObservationIgnored private var settingsBaseline: DocumentSettings?
    private var documentDirectives = DocumentDirectives()
    var keepsClipboardSettingsInMemory = false
    private var didCustomizeSinceLoad = false
    @ObservationIgnored private var validatesMigratedContent = false
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
    /// The bands' room when a stage took the window. The stage keeps its own frame, so a toolbar turned on or off there
    /// is applied to the view mode's frame on the way back.
    @ObservationIgnored private var stageBandRoom: BandRoom?
    @ObservationIgnored private(set) var hasSizedWindow = false
    /// The tray was asked for before the first pages were there.
    @ObservationIgnored private(set) var isPrintModeRequested = false
    @ObservationIgnored private var didResizeWindow = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The state this window left each record in that it wrote where there was none. Such a record is removed when
    /// the content changes, as long as its state is still this one: a record from before, or one that another window
    /// has read or written since, may belong to a copy of the file that still has that content.
    @ObservationIgnored private var ownedRecordTokens: [String: DocumentSettingsStore.Token] = [:]
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
    let renderer: DocumentRenderer
    @ObservationIgnored private var composingSheets = false
    private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var hasShownVerticalWritingNote = false
    private var toastTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var reloadTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    var beforeWatcherCheck: @Sendable () -> Void = {}
    private var reloadRequiresRefresh = false
    private var reloadRequiresWebRefresh = false
    private var reloadOwnsProgress = false
    var readReloadData: @Sendable (URL, DocumentFormat) async throws -> Data = { url, format in
        try await Task.detached(priority: .utility) { try SourceFileOpening.read(url, format: format) }.value
    }
    private var reloadGeneration = 0
    private(set) var displayedChangeSource: DocumentSource?
    /// A failed reload can leave the last readable pages on screen. Their source still belongs to those pages.
    var proseGeneration: Int? {
        guard !isRendering, displayedChangeSource != nil, paperDocument === result?.viewDocument else { return nil }
        return result?.id
    }
    private(set) var markdownChanges: [MarkdownMarkRequest] = []
    /// The changes of the last reload have not been brought to the reader's attention yet.
    @ObservationIgnored private var hasUnannouncedChanges = false
    /// The table of contents, with the page of each entry as laid out for reading.
    private(set) var outlineEntries: [OutlineEntry] = [] {
        didSet { outlineFilter.reload(entries: outlineEntries) }
    }
    /// The amount of text; only documents laid out from text have one.
    private(set) var documentStatistics: DocumentStatistics?
    @ObservationIgnored private var structureTask: Task<Void, Never>?
    @ObservationIgnored private var readStructure:
        (
            source: DocumentSource, proof: ProofMarks, orgReading: OrgReadingSettings, headings: [DocumentHeading],
            statistics: DocumentStatistics,
            contents: [String], title: String?
        )?
    @ObservationIgnored private var structureDocument: PDFDocument?
    var shortcutListFocused = false
    enum PendingPDF {
        case reading(Data)
        case sheets(PDFDocument)

        @MainActor func bytes() throws -> Data {
            switch self {
            case .reading(let bytes): return bytes
            case .sheets(let document):
                guard let data = document.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
                return data
            }
        }
    }

    var pendingPDF: PendingPDF?

    init(
        data: Data, fileURL: URL?, format: DocumentFormat,
        preferences: AppPreferences, library: UserLibrary, renderer: DocumentRenderer = DocumentRenderer(),
        imageBundle: ImageBundleModel? = nil, settingsStore: DocumentSettingsStore? = nil,
        trialRenderer: DocumentRenderer = DocumentRenderer(), title: String? = nil, sourceFileName: String? = nil,
        binder: BinderModel? = nil,
        htmlBaseURL: URL? = nil, isStreamingPreview: Bool = false
    ) {
        self.isStreamingPreview = isStreamingPreview
        themeTrial = ThemeTrial(renderer: trialRenderer)
        self.imageBundle = imageBundle
        self.binder = binder
        self.settingsStore = settingsStore
        if let settingsStore, let fileURL, fileURL.isFileURL, binder == nil,
            imageBundle == nil || imageBundle?.archiveURL != nil
        {
            let root = settingsStore.directory.deletingLastPathComponent()
            location = (
                ContentHash.of(Data(fileURL.standardizedFileURL.path.utf8)).hex,
                KeyedRecordStore(
                    directory: root.appendingPathComponent("DocumentLocations"), capacity: settingsStore.capacity)
            )
        } else {
            location = nil
        }
        self.data = data
        self.sourceFileName = sourceFileName
        detectedSourceLanguage = (sourceFileName ?? fileURL?.lastPathComponent).flatMap {
            SourceLanguage.detect(fileName: $0)
        }
        self.fileURL = fileURL
        self.htmlBaseURL = htmlBaseURL
        self.title = title
        self.format = format
        self.preferences = preferences
        openingViewDefaults = preferences.viewDefaults
        defaultTypeface = preferences.defaultTypeface
        defaultTextScale = preferences.defaultTextScale
        defaultPaperOrientation = preferences.defaultPaperOrientation
        typeface = (binder?.usesPrintTheme ?? format.usesPrintTheme) ? preferences.defaultTypeface : .style
        textScale = (binder?.usesPrintTheme ?? format.usesPrintTheme) ? preferences.defaultTextScale : 1
        paperOrientation = preferences.defaultPaperOrientation
        isAlwaysOnTop = preferences.defaultAlwaysOnTop
        showsOnAllSpaces = preferences.defaultShowsOnAllSpaces
        defaultBandVisibility = preferences.defaultBandVisibility
        bandVisibility = preferences.defaultBandVisibility
        self.library = library
        self.renderer = renderer
        bookletBinding = nil
        let themeFormat = binder == nil && imageBundle == nil ? format : nil
        let source = themeFormat.map { DocumentSource(data: data, fileURL: fileURL, format: $0).named(sourceFileName) }
        let inferredLayout = UserLibrary.classLayout(for: source, renderer: renderer)
        classLayout = inferredLayout
        layoutID = inferredLayout?.id ?? Self.defaultLayoutID(preferences)
        let inferredStyle = UserLibrary.classStyle(for: source, renderer: renderer)
        classStyle = inferredStyle
        let initialTheme = library.defaultThemeID(
            preferred: preferences.themeID, format: themeFormat, classStyle: inferredStyle)
        themeID = initialTheme
        codePaletteID = Self.defaultCodePaletteID(preferences, library)
        presetID = Self.defaultPresetID(preferences, library)
        printOptions = preferences.printOptions.defaults(for: themeFormat)
        printFinish = preferences.printFinish
        // A guess until the pages are known; most documents have more than two pages.
        let guess = ViewOptions.resolved(
            for: ViewDefaultsContext(
                kind: Self.viewKind(format: format, isBundle: imageBundle != nil), pageCount: 3,
                firstPageSize: PaperSize.a4.size), preferences: preferences.viewDefaults)
        viewOptions = guess.following(
            library.theme(initialTheme, for: themeFormat, classStyle: inferredStyle)?.flow ?? .horizontal,
            preferredScrollAxis: preferences.viewDefaults.scrollAxis)
        initialViewOptions = guess
        if format == .html, htmlBaseURL != nil { htmlPresentation = .paper }
        themeSamples.inputs = { [weak self] in (self?.themedSource, self?.renderSettings) }
        specimenSamples.diskCache = ThemeSampleCache.application
        specimenSamples.specimenLanguage = { [weak self] in self?.language ?? "en" }
        specimenSamples.inputs = { [weak self] in
            guard let self else { return (nil, nil) }
            var settings = ThemeSpecimen.settings
            settings.typeface = typeface
            settings.layout = renderLayout
            settings.paperOrientation = paperOrientation
            return (
                ThemeSpecimen.source(language: language, format: self.themeFormat, classStyle: self.classStyle),
                settings
            )
        }
        paper.onReadingJump = windowAction { $0.recordReadingJump(to: $1) }
        paper.onToast = windowAction { $0.showToast($1) }
        web.onFolderAccessRequired = windowAction { model, _ in model.requestFolderAccess() }
        #if DEBUG
            DebugSnapshot.configure(self)
        #endif
    }

    var sourceURLs: [URL] { binder?.urls ?? imageBundle?.urls ?? [fileURL].compactMap { $0 } }
    /// The document as the print themes lay it out; nil for the formats that print without a theme.
    var themedSource: DocumentSource? {
        if let binder { return binder.cachedSource }
        return format.usesPrintTheme && imageBundle == nil
            ? withFolderAccess(DocumentSource(data: data, fileURL: fileURL, format: format).named(sourceFileName)) : nil
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
    var latexBadge: LaTeXBadgeText? {
        guard themeFormat == .latex, textKind == nil, let facts = result?.facts,
            facts.beamerPageSize != nil || theme(themeID)?.formats == [.latex],
            let recognition = facts.latexRecognition
        else { return nil }
        return LaTeXBadgeText(recognition, language: language, facts: facts)
    }

    var offersLaTeXComposition: Bool { latexBadge != nil && result?.facts?.offersLaTeXComposition == true }

    func selectComposition(_ choice: LaTeXComposition) {
        guard offersLaTeXComposition else { return }
        savedComposition = choice
    }

    var formatBadge: String { formatBadge(in: .full) }

    func formatBadge(in form: BandLayout.Form) -> String {
        guard form != .compact, let latexBadge else { return shortFormatBadge }
        var text = shortFormatBadge + " · " + latexBadge.label
        if form == .full, offersLaTeXComposition, let key = latexComposition.suffixKey {
            text += " · " + PrintModeText.string(key, language: language)
        }
        return text
    }

    /// "MD", "PDF", "ZIP"…; "IMG" for a bundle of image files; the language of a source file ("Swift", "YAML").
    var shortFormatBadge: String {
        if binder != nil { return String(localized: "Binder") }
        guard imageBundle == nil || format == .zipArchive else { return "IMG" }
        return sourceLanguage?.displayName ?? format.badge
    }

    /// The language a plain text file is colored as.
    var sourceLanguage: SourceLanguage? {
        format == .plainText && binder == nil && (fileURL != nil || sourceFileName != nil)
            ? detectedSourceLanguage : nil
    }

    var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The user picked a print theme, so it also becomes the most recent one in every window's menu.
    func selectTheme(_ id: String) {
        guard !isWindowClosed, theme(id) != nil else { return }
        // The pages of a trial of the same theme stay on the paper until the document's own are laid out.
        if id != themeID, themeTrial.themeID == id, let document = themeTrial.document {
            chosenTrial = (
                id, codePaletteID, themeTrial.requestedSettings, document, themeTrial.changeMarks, themeTrial.furniture,
                themeTrial.diagrams, themeTrial.formulaIndex
            )
        }
        themeTrial.end()
        themeComparison?.choose(id)
        themeID = id
        preferences.recordThemeChoice(id)
    }

    /// The user picked a code palette. The pages of a trial of it stay on the paper as they do for a theme.
    func selectCodePalette(_ id: String) {
        guard !isWindowClosed else { return }
        if id != codePaletteID, themeTrial.themeID == Self.codeTrialID(id), let document = themeTrial.document {
            chosenTrial = (
                themeID, id, themeTrial.requestedSettings, document, themeTrial.changeMarks, themeTrial.furniture,
                themeTrial.diagrams, themeTrial.formulaIndex
            )
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
            favoriteIDs: preferences.favoriteThemeIDs, format: themeFormat, classStyle: classStyle)
    }
    var layout: PrintLayout {
        (PrintLayout.presets.first { $0.id == layoutID } ?? .a4Single).bound(effectiveBookletBinding)
    }
    /// Reading and comparing show the pages the tray composes, so what is read is what prints. Images are the
    /// exception: nothing in them reflows, and the paper and the window take the image's shape whatever the layout,
    /// so reading and comparing keep them on A4 single-sided and only the tray arranges them on the print layout.
    var renderLayout: PrintLayout { renderLayout(in: mode) }

    private func renderLayout(in mode: ViewerMode) -> PrintLayout {
        mode != .print && (imageBundle != nil || format == .image) ? .a4Single : layout
    }

    /// Text can be laid out again on other paper, also in a binder; PDFs and images keep their pages.
    var offersPaperSeries: Bool {
        guard !showsWeb, imageBundle == nil else { return false }
        return binder.map { $0.items.contains { $0.format.isWebRendered } } ?? format.isWebRendered
    }

    var renderSettings: RenderSettings? { renderSettings(in: mode) }

    /// Whether pages laid out with these settings, from the live page's copy or not, are the logical pages the view
    /// mode shows, now or once the tray is left. The tray's page range and the turning of back sides choose and turn
    /// sheets and leave the logical pages as they are. Its note pages, current-slide-only, opened details and original
    /// page change them, and the last two are also turned off on leaving the tray (`resetPrintChoices()`), so the
    /// view is judged without them.
    func showsReadingPages(_ settings: RenderSettings, fromSnapshot: Bool) -> Bool {
        guard var reading = renderSettings(in: .view) else { return false }
        reading.markdownChanges = settings.markdownChanges
        reading.changeTextHex = settings.changeTextHex
        reading.changeBackgroundHex = settings.changeBackgroundHex
        reading.opensDetails = false
        reading.pageRange = settings.pageRange
        reading.options.rotatesBackSides = settings.options.rotatesBackSides
        return reading == settings && fromSnapshot == (usesHTMLPresentation && liveSnapshot != nil)
    }

    func renderSettings(in mode: ViewerMode) -> RenderSettings? {
        guard
            let theme = self.theme(usesPrintTheme ? themeID : "standard")
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
            textScale: usesPrintTheme ? textScale : 1, typeface: usesPrintTheme ? typeface : .style,
            paperOrientation: paperOrientation,
            opensDetails: rendersSnapshot && opensClosedDetails,
            slides: (usesHTMLPresentation || (mode == .print && printsCurrentSlideOnly) ? slideDeck : nil).map {
                SlidePrintRequest(deck: $0, printsCurrentOnly: mode == .print && printsCurrentSlideOnly)
            }, markdownChanges: mode == .view ? markdownChanges : [])
        if binder?.items.contains(where: { $0.format == .org }) ?? (format == .org) { settings.orgReading = orgReading }
        if !settings.markdownChanges.isEmpty, let hex = preferences.changeTextHex {
            settings.changeTextHex = hex
        }
        if format == .latex, binder == nil, textKind == nil, theme.formats == [.latex] {
            settings.latexComposition = latexComposition
        }
        settings.binderStartsOnFront = binder != nil && binderStartsOnFront && settings.layout.hasFacingPages
        if finishAppliesToText { settings.finish = printFinish }
        if mode == .print, offersNotes { settings.notes = notes }
        // The view mode always shows the whole document.
        if mode == .print { settings.pageRange = pageRange }
        settings.documentName = displayName
        settings.pageLanguage = language
        if usesPrintTheme {
            settings.code = CodeStyle(
                palette: library.codePalette(codePaletteID), block: chosenCodeBlock,
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
    /// What the tray shows: the current sheets, or, while the sheets of newer logical pages are composed, the sheets it
    /// showed until then. They are of the same files and stay consistent among themselves; swapping them for a progress
    /// message for the few hundred milliseconds of a composition made the tray and the press bar under it jump on
    /// every change of layout or paper. Outputs still wait for `hasCurrentPrintPreview` (`canOutput`).
    var showsTrayPreview: Bool {
        if hasCurrentPrintPreview { return true }
        return isRendering && error == nil && printTray != nil && printResult != nil
            && printTraySourceURLs == sourceURLs && renderedSettings?.smartRemoval?.highlightsCandidates != true
            && printTraySettings?.smartRemoval?.highlightsCandidates != true
    }
    /// The composed sheets the tray shows, nil while it shows none. The page counts, labels and notes that describe the
    /// sheets come from here rather than from `result`, which runs ahead while newer sheets are composed; so the sheets
    /// and their descriptions change together, once.
    var shownSheets: RenderResult? { showsTrayPreview ? printResult : nil }
    /// The settings of `shownSheets`.
    var shownSheetSettings: RenderSettings? { shownSheets == nil ? nil : printTraySettings }
    /// The pages the tray's top bar counts, and the note pages among them, both of the shown sheets; before there are
    /// any, the pages laid out, without notes.
    var trayPageCount: (pages: Int, notes: Int)? {
        if let sheets = shownSheets { return (sheets.plan.logicalPageCount, sheets.addedNotePages) }
        return result.map { ($0.plan.logicalPageCount, 0) }
    }
    /// The names under the tray's images, of the images the shown sheets were made of.
    var trayImageNames: [String]? {
        guard imageBundle != nil, let sheets = shownSheets, let urls = printTraySourceURLs else { return nil }
        return urls.filter { !sheets.unreadableImageURLs.contains($0) }.map(\.lastPathComponent)
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
        // Told of the sheets on the tray, which change after the logical pages do.
        let settings = shownSheets == nil ? renderedSettings : shownSheetSettings
        let outOfDocument = shownSheets?.pageSelection.isOutOfDocument ?? result?.pageSelection.isOutOfDocument
        guard mode == .print, settings?.pageRange == pageRange, outOfDocument == true else { return nil }
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

    /// The series of the tray's cards: the series of the paper the pages are on, so the cards never show another
    /// paper than the sheets.
    var trayPaperSeries: PaperSeries { shownPaperSeries ?? layout.series }

    /// Switching the series brings the layout along, so the sheets on the tray follow the switch. The series is also
    /// the paper the next documents start on, unless it is only shown, as for a screenshot.
    func choosePaperSeries(_ series: PaperSeries, remembers: Bool = true) {
        if remembers { preferences.choosePaperSeries(series) }
        layoutID = layout.counterpart(in: series).id
        shownPaperSeries = series
    }

    /// The six default card shortcuts keep their positions; the compact alternatives start unassigned.
    func chooseCard(at index: Int) {
        if index == 0 && trayPaperSeries == .a && layout == .journalSingle {
            chooseLayout(layout.id)
            return
        }
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
        // Notes and live HTML choices can still change the pages on the way back to reading, so the pages are judged
        // against the view as it will be once the tray's own choices are reset.
        let fromSnapshot = renderedSettings == nil ? rendersSnapshot : renderedFromSnapshot
        if let settings = renderedSettings ?? renderSettings, showsReadingPages(settings, fromSnapshot: fromSnapshot) {
            pendingPrintIssue = nil
            currentPageIndex = max(0, page - 1)
            pointOut(issue.rect, onPage: max(0, page - 1))
        } else {
            pendingPrintIssue = (issue, pageCount)
        }
        exitPrintMode()
    }

    /// Frames the spot of a problem on the paper for a moment, so that the reader need not look for it on the page.
    /// The window gives the print stage back and takes the paper's width again first, so the paper may not be there
    /// yet; a problem with no mark on its page gets no frame. The request is for the pages the problem was found on:
    /// once a reload or a new layout replaces them, it is dropped, not matched to whatever the paper shows next.
    func pointOut(_ anchor: CGRect?, onPage pageIndex: Int, framesLine: Bool = false) {
        dropSpot()
        guard let anchor, let document = result?.viewDocument else { return }
        let spot = PaperSpot(pageIndex: pageIndex, anchor: anchor, document: document, framesLine: framesLine)
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

    private func followViewFurniture(after old: PreparedRender?) {
        let placements = result?.viewFurniture ?? [:]
        furnitureTask?.cancel()
        guard placements != shownFurniture else { return }
        // Typing into the custom header changes only its text, on the same pages.
        let isTyping =
            old?.logicalDocument != nil && old?.logicalDocument === result?.logicalDocument
            && old?.furniture.preset == .custom && result?.furniture.preset == .custom
        guard isTyping else { return showFurniture(placements) }
        let pause = awaitTypingPause
        furnitureTask = Task { [weak self] in
            await pause()
            guard !Task.isCancelled else { return }
            self?.showFurniture(placements)
        }
    }

    private func showFurniture(_ placements: [Int: FurniturePlacement]) {
        shownFurniture = placements
        shownFurnitureChangeCount += 1
    }

    /// Whether the pages show a date in their header or footer other than today's, as after midnight.
    var showsStaleDate: Bool {
        guard let result, let settings = renderedSettings, let today = renderer.furnitureDate(for: settings) else {
            return false
        }
        return result.furnitureDate != today
    }

    /// A new day, also after the Mac wakes: a header or footer with the date shows today's. The logical pages stay;
    /// only the header and footer and the sheets are made again.
    func calendarDayDidChange() {
        themeTrial.forgetRecent()
        guard let settings = renderSettings, renderer.furnitureDate(for: settings) != nil else { return }
        render()
    }

    /// An output never carries an earlier day's date, also when the day changed while nothing was laid out. The date
    /// is the day the output was asked for: a save panel or print dialog left open across midnight keeps it, as it
    /// keeps the pages it was asked for (`beginPDFExport()`).
    private func deferUntilDateIsCurrent(_ output: Output) -> Bool {
        guard mode == .print, showsStaleDate else { return false }
        outputAfterReview = output
        render()
        return true
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
        if let found { pointOut(found.rect, onPage: index) }
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
    var displayUnits: [DisplayUnit] { displayUnits(for: pageCount) }

    private func displayUnits(for count: Int) -> [DisplayUnit] {
        SpreadLayout.units(
            pageCount: count, layout: viewOptions.layout, showsCoverAlone: viewOptions.showsCoverAlone,
            direction: viewOptions.direction)
    }
    /// "3 / 12" for a page, "2–3 / 12" for a spread; "Slide 3 of 6" for a slide deck on the web.
    var pageIndicator: String? {
        if showsWeb || result?.facts?.beamerPageSize != nil {
            guard let slideDeck else { return nil }
            return Self.slideIndicator(slideDeck.currentIndex + 1, of: slideDeck.count)
        }
        let count = paperPageCount
        let index = paperPageIndex
        guard count > 0 else { return nil }
        let units = displayUnits(for: count)
        let pages = SpreadLayout.unitIndex(containing: index + 1, in: units).map { units[$0].pages } ?? [index + 1]
        return PageIndicator.text(pages: pages, pageCount: count)
    }

    /// The widest page indicator of this document, whose width the band keeps for the indicator.
    var pageIndicatorTemplate: String? {
        if showsWeb || result?.facts?.beamerPageSize != nil {
            guard let slideDeck else { return nil }
            return Self.slideIndicator(slideDeck.count, of: slideDeck.count)
        }
        guard paperPageCount > 0 else { return nil }
        return PageIndicator.widestText(pageCount: paperPageCount, layout: viewOptions.layout)
    }

    @ObservationIgnored private(set) var isWindowClosed = false

    func closeWindow() {
        guard !isWindowClosed else { return }
        isWindowClosed = true
        paper.disconnect()
        stop()
        onFirstRender = nil
        textReopener = nil
    }

    func start() {
        guard !isWindowClosed else { return }
        if SandboxEnvironment.isSandboxed, folderLease == nil, let fileURL,
            let lease = FolderAccess.shared.acquire(for: fileURL)
        {
            useDocumentFolder(lease)
            web.reload()
        }
        web.onZoomChange = windowAction { $0.webZoom = $1 }
        web.onPrintRequest = { [weak self] in
            guard let self, !isWindowClosed else { return }
            pageDidRequestPrint()
        }
        web.onSlideDeckChange = windowAction { $0.slideDeckDidChange($1) }
        web.onRestart = { [weak self] in
            guard let self, !isWindowClosed else { return }
            cancelCapture()
            liveSnapshot = nil
            slideDeckDidChange(nil)
            // Pages of the old copy would no longer count as up to date, so they are made from the file again.
            if renderedFromSnapshot { render() }
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
        if dayObserver == nil {
            dayObserver = NotificationCenter.default.addObserver(
                forName: .NSCalendarDayChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.calendarDayDidChange() }
            }
        }
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
        scrubber.cancel()
        thumbnailCache = nil
        pageUpdateTask?.cancel()
        pageUpdate = PageUpdateProgress()
        pageUpdateDisplay = .hidden
        cancelAdditionalExport()
        binderExit.cancel()
        pendingBinderRestoration = nil
        binderExitTrayPage = nil
        cancelManualDuplex()
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
        dayObserver = nil
        furnitureTask?.cancel()
        pendingPrint = nil
        duplexTestTask?.cancel()
        duplexTestTask = nil
        pendingPrintIssue = nil
        dropSpot()
        renderTask?.cancel()
        toastTask?.cancel()
        hashTask?.cancel()
        structureTask?.cancel()
        readingExportTask?.cancel()
        readingExportTask = nil
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
        for lease in fileAccess { lease.close() }
        fileAccess = []
        // A window that goes away before it took the access waiting for its file would leave it waiting for ever.
        if !hasTakenItsFileAccess, let fileURL { DocumentWindows.shared.router.giveUpAccess(for: fileURL) }
    }

    func keep(_ access: [FolderAccess.Lease]) {
        fileAccess += access
    }

    func handleFileEvent(_ event: FileWatcher.Event) {
        switch event {
        case .check:
            guard preferences.reloadsChangedFiles, let fileURL else { return }
            let generation = reloadGeneration
            let reader = readReloadData
            let readFormat = format
            reconciliationTask?.cancel()
            reconciliationTask = Task { [weak self] in
                // Initial registration is not evidence of a change: leave an in-flight layout alone.
                guard let bytes = try? await reader(fileURL, readFormat), let self,
                    !Task.isCancelled, generation == reloadGeneration, preferences.reloadsChangedFiles, bytes != data
                else { return }
                reload(reloadsWeb: true, onlyIfChanged: true)
            }
        case .changed:
            if preferences.reloadsChangedFiles { reload(reloadsWeb: true, onlyIfChanged: true) }
        case .removed:
            reloadGeneration += 1
            reloadTask?.cancel()
            reloadTask = nil
            reloadRequiresRefresh = false
            reloadRequiresWebRefresh = false
            if reloadOwnsProgress { isRendering = false }
            reloadedPages = .failed
            refreshPageUpdate()
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
        if reloadRequiresRefresh {
            reloadedPages = .reading
            refreshPageUpdate()
            isRendering = true
        }
        guard let fileURL else {
            applyReload(reloadsWeb: reloadsWeb)
            return
        }
        // Detached I/O keeps large files off the main actor; generation checks reject superseded reads.
        let reader = readReloadData
        let readFormat = format
        reloadTask = Task { [weak self] in
            do {
                let bytes = try await reader(fileURL, readFormat)
                guard let self, !Task.isCancelled, reloadGeneration == generation else { return }
                // A `.plist` saved again as binary, or a `.ts` replaced by a video: the last pages stay, and the
                // reader is told, as for a file that could not be read.
                if SourceFileOpening.refuses(bytes, at: fileURL, format: format) { throw SourceFileError.notText }
                if bytes != data && preferences.reloadsChangedFiles {
                    reloadedPages = .reading
                    refreshPageUpdate()
                }
                var changes: [MarkdownMarkRequest] = []
                if let previous = displayedChangeSource, previous.format == format, previous.data != bytes,
                    reloadRequiresRefresh || (preferences.reloadsChangedFiles && bytes != data)
                {
                    let current = withFolderAccess(
                        DocumentSource(data: bytes, fileURL: fileURL, format: format).named(sourceFileName))
                    changes = await renderer.changeRequests(
                        from: previous, to: current, finish: printFinish, orgReading: orgReading)
                    guard !Task.isCancelled, reloadGeneration == generation else { return }
                }
                // A reader can turn off watching while the file or its diff is being read.
                if !reloadRequiresRefresh && (!preferences.reloadsChangedFiles || bytes == data) {
                    reloadTask = nil
                    reloadOwnsProgress = false
                    reloadRequiresWebRefresh = false
                    if reloadedPages == .reading {
                        reloadedPages = .unchanged
                        refreshPageUpdate()
                    }
                    // If a still-running layout was cancelled at the reload boundary, finish that same content.
                    if isRendering { render() }
                    return
                }
                markdownChanges = changes
                hasUnannouncedChanges = !changes.isEmpty
                if toast?.action == .nextChange { dismissToast() }
                reloadTask = nil
                data = bytes
                applyReload(reloadsWeb: reloadRequiresWebRefresh)
            } catch {
                guard let self, !Task.isCancelled, reloadGeneration == generation else { return }
                reloadTask = nil
                if reloadOwnsProgress { isRendering = false }
                reloadedPages = .failed
                refreshPageUpdate()
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
        reloadedPages = .awaitingLayout
        // Companion files can change the headings even when the main LaTeX source is byte-for-byte identical.
        if format == .latex {
            structureTask?.cancel()
            readStructure = nil
        }
        cancelAdditionalExport()
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
        let updatedDirectives = currentDirectives
        let updatedClassStyle = UserLibrary.classStyle(for: themedSource, renderer: renderer)
        let updatedClassLayout = UserLibrary.classLayout(for: themedSource, renderer: renderer)
        let printSettingsChanged = !updatedDirectives.hasSamePrintSettings(as: documentDirectives)
        documentDirectives = updatedDirectives
        if printSettingsChanged || updatedClassStyle != classStyle || updatedClassLayout != classLayout {
            let canApply =
                !hasSavedSettings && !didCustomizeSinceLoad && !didResizeWindow
                && rememberedSettings == settingsBaseline
            classStyle = updatedClassStyle
            classLayout = updatedClassLayout
            if canApply {
                settingsBaseline = nil
                notes = NotePages()
                applyDirectiveDefaults()
                settingsBaseline = rememberedSettings
            } else if theme(themeID) == nil {
                // Reinterpreting a feed may invalidate only its style. Preserve its other remembered choices.
                themeID = defaultThemeID
            }
        }
        computeContentHash()
        refreshIncludePlan()
        render()
    }

    /// A window without a file takes what its feed sends, as a file's window takes a change of the file.
    func replaceContent(_ bytes: Data, format: DocumentFormat) {
        guard fileURL == nil, binder == nil, imageBundle == nil, bytes != data || format != self.format else { return }
        cancelAdditionalExport()
        data = bytes
        self.format = format
        applyReload(reloadsWeb: false)
    }

    /// The bytes of a document that exists only in this window.
    var memoryContent: Data? { fileURL == nil && binder == nil && imageBundle == nil ? data : nil }

    /// How text from the clipboard or a service came by its format; nil for every other document, whose format its
    /// file or its sender decides.
    var textFormatOrigin: TextFormatOrigin?
    /// Opens this window's text again as another kind, in a window where this one is (`ClipboardWindows`).
    @ObservationIgnored var textReopener: ((ClipboardTextKind) -> Void)?

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
        if theme(themeID) == nil { themeID = defaultThemeID }
        codePaletteID = Self.knownCodePaletteID(codePaletteID, library) ?? CodePalette.matchesStyleID
        if !library.presets.contains(where: { $0.id == presetID }) { presetID = "none" }
        reload(reloadsWeb: false)
    }

    func reopenAsText() {
        format = .plainText
        classStyle = nil
        classLayout = nil
        if theme(themeID) == nil { themeID = defaultThemeID }
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
        } else if mode == .view, let index = readingImageURLs.firstIndex(of: url) {
            recordReadingJump(to: index)
            currentPageIndex = index
            paper.goToPage(index: index)
        }
    }

    /// A list edit changes the bundle immediately, while the paper still shows the previous order.
    private(set) var readingImageURLs: [URL] = []

    private func restoreReadingImage(in images: [DocumentSource.Image], skipping unreadable: [URL]) {
        let shown = readingImageURLs.indices.contains(currentPageIndex) ? readingImageURLs[currentPageIndex] : nil
        let skipped = Set(unreadable)
        readingImageURLs = images.compactMap { skipped.contains($0.fileURL) ? nil : $0.fileURL }
        currentPageIndex =
            shown.flatMap { readingImageURLs.firstIndex(of: $0) }
            ?? min(currentPageIndex, max(0, readingImageURLs.count - 1))
    }

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
        if isUpToDate, mode != .print || hasCurrentPrintPreview { return }
        if isRendering, let renderingSettings, renderingSettings == renderSettings { return }
        render()
    }

    func render() { render(reusing: nil) }

    private func render(reusing currentPages: PreparedRender?) {
        guard !isWindowClosed else { return }
        if reloadedPages == .failed { reloadedPages = .unchanged }
        dismissProseMark()
        selectedReadingPage = nil
        thumbnailCache = nil
        layoutTooLarge = false
        composingSheets = false
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
        refreshPageUpdate()
        let sourceURLs = sourceURLs
        let fromSnapshot = rendersSnapshot
        let singleSource =
            fromSnapshot
            ? DocumentSource.liveSnapshot(liveSnapshot?.html ?? "", of: fileURL)
            : DocumentSource(data: data, fileURL: fileURL, format: format, htmlBaseURL: htmlBaseURL).named(
                sourceFileName)
        let started = ContinuousClock.now
        let layoutsBefore = renderer.logicalRenderCount
        let generation = dataGeneration
        renderTask = Task { [weak self, renderer, binder, imageBundle] in
            guard !Task.isCancelled else { return }
            var settings = settings
            do {
                let prepared: PreparedRender
                if let currentPages {
                    prepared = currentPages
                } else {
                    let source: DocumentSource
                    if let binder {
                        source = try await binder.source()
                        guard !Task.isCancelled, let self else { return }
                        if let hash = binder.setHash { didComputeHash(hash) }
                        if sourceURLs != self.sourceURLs || settings != renderSettings {
                            render()
                            return
                        }
                    } else if let imageBundle {
                        source = try await imageBundle.source()
                        guard !Task.isCancelled, let self else { return }
                        // The digests and the key of their set change together, so nothing is saved under a mixed state.
                        if imageBundle.archiveURL == nil, let hash = imageBundle.setHash { didComputeHash(hash) }
                    } else {
                        guard let self else { return }
                        source = withFolderAccess(singleSource)
                    }
                    prepared = try await renderer.prepare(source, settings: settings)
                    try Task.checkCancellation()
                    guard let self else { return }
                    if renderer.logicalRenderCount != layoutsBefore {
                        lastLayoutDuration = ContinuousClock.now - started
                    }
                    // The paper can show the logical pages before any sheets are needed.
                    settings.options.rotatesBackSides = mode == .print && printerRotation(for: prepared.layout)
                    renderingSettings = settings
                    result = prepared
                    if offersOrgReading, source.format == .org, generation == dataGeneration {
                        orgFileInstructions = prepared.facts?.orgInstructions
                    }
                    // Only the layout of the contents shown now names their language.
                    if source.format == .plainText, !fromSnapshot, generation == dataGeneration,
                        let facts = prepared.facts, detectedSourceLanguage != facts.sourceLanguage
                    {
                        detectedSourceLanguage = facts.sourceLanguage
                    }
                    if source.format.supportsChangeMarks { displayedChangeSource = source }
                    chosenTrial = nil
                    // Pages laid out on the tray are the ones read unless the tray added or changed some, so the outline
                    // and the place read follow them there too and stay right on the way back, where nothing renders.
                    let forReading = mode == .view || showsReadingPages(settings, fromSnapshot: fromSnapshot)
                    refreshStructure(of: source, in: prepared, forReading: forReading, settings: settings)
                    announceChanges(in: prepared)
                    renderedSettings = settings
                    renderedSourceURLs = sourceURLs
                    renderedFromSnapshot = fromSnapshot
                    if reloadedPages == .awaitingLayout { reloadedPages = .unchanged }
                    refreshPageUpdate()
                    unreadableImageURLs = prepared.unreadableImageURLs
                    binder?.didRender(prepared, forReading: forReading)
                    if forReading, let page = binder?.settleReadingPage() {
                        currentPageIndex = page
                    } else if forReading, let images = source.images {
                        restoreReadingImage(in: images, skipping: prepared.unreadableImageURLs)
                    }
                    resolveViewOptionsIfNeeded(for: prepared.viewDocument)
                    validateMigratedContentIfReady()
                    if let imageBundle {
                        // The digests of the images are known now, so a remembered order can be restored.
                        if let order = pendingImageOrder {
                            pendingImageOrder = nil
                            // Restoring the remembered order is part of opening the document, not a change to save.
                            if imageBundle.applyOrder(order) { settingsBaseline = rememberedSettings }
                        }
                    }
                }
                if self?.mode == .print || self?.waitingOutput?.replacesReview == true {
                    self?.composingSheets = true
                    let output = try await renderer.composeSheet(
                        for: prepared, rotatesBackSides: settings.options.rotatesBackSides)
                    try Task.checkCancellation()
                    guard let self else { return }
                    composingSheets = false
                    printResult = output
                    if mode == .print, settings == renderSettings {
                        trayFigures = TrayFigures(
                            settings: settings, data: data, sourceURLs: sourceURLs, sheetCount: output.plan.sheetCount,
                            paper: output.plan.paper.shortName)
                    }
                    printTraySourceURLs = sourceURLs
                    printTraySettings = settings
                    printTray = PrintTray(
                        plan: output.plan, layout: output.layout, rotatesBackSides: settings.options.rotatesBackSides,
                        sheetOrientations: output.sheetOrientations, blankPages: output.blankPages,
                        notePages: output.notePages)
                }
                guard let self else { return }
                isRendering = false
                resolveTrayRequest()
                if mode == .print, let page = binderExitTrayPage, let printTray {
                    requestedTrayRow = printTray.bodyPage(at: page).flatMap(printTray.rowID(containing:))
                    binderExitTrayPage = nil
                }
                finishFirstRender(succeeded: true)
                resolvePrintIssueNavigation()
                retriedChangedImages = false
                if currentPages == nil, prepared.requiredFolderAccess != nil { requestFolderAccess() }
                showVerticalWritingNoteIfNeeded()
                // A render that a later change made stale leaves the output to the render that follows it.
                if pendingPrint != nil, settings == renderSettings { resumePendingPrint() }
                if let output = outputAfterReview, mode == .print || output.readsPages,
                    settings == renderSettings
                {
                    outputAfterReview = nil
                    run(output)
                }
            } catch is CancellationError {
                // A superseding request owns the progress indicator.
            } catch DocumentRenderer.RenderingError.imageChanged
                where self?.retriedChangedImages == false && imageBundle != nil
            {
                guard !Task.isCancelled, let self else { return }
                // An image was edited after it was hashed: hash the images again, which carries the settings over to
                // the new set, and draw again. A second change in a row is reported below instead of looping.
                retriedChangedImages = true
                imageBundle?.clearCache()
                render()
            } catch {
                guard !Task.isCancelled, let self else { return }
                if case DocumentRenderer.RenderingError.noReadableImages(let urls) = error {
                    unreadableImageURLs = urls
                }
                if case DocumentRenderer.RenderingError.noReadableDocuments(let urls) = error { binder?.didFail(urls) }
                if case DocumentRenderer.RenderingError.tooLarge = error { layoutTooLarge = true }
                composingSheets = false
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
        if succeeded { applyRestoredPageIfReady() } else { refreshPageUpdate() }
        if succeeded, !finishBinderRestorationIfReady() { return }
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
            themeID = theme(source.themeID)?.id ?? defaultThemeID
            setTypeface(source.typeface)
            setTextScale(source.textScale)
            codePaletteID = source.codePaletteID
            chosenCodeBlock = source.chosenCodeBlock
        }
        if source.usesHTMLPreset { presetID = source.presetID }
        bookletBinding = source.bookletBinding
        layoutID = source.layoutID
        shownPaperSeries = source.shownPaperSeries
        paperOrientation = source.paperOrientation
        printOptions = source.printOptions
        chosenReadingOrder = source.chosenReadingOrder
        viewOptions = source.viewOptions
        hasResolvedViewOptions = true
        zoom = source.zoom
        bandVisibility = source.bandVisibility
        isAlwaysOnTop = source.isAlwaysOnTop
        showsOnAllSpaces = source.showsOnAllSpaces
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
        rememberStageBandRoom()
        ViewerWindow.setTrafficLightsVisible(true, in: window)
        PrintModeWindow.enter(window, size: traySize)
    }

    /// Waits for the single document's settings and pages before mapping the binder's reading position.
    func restoreAfterLeavingBinder(_ origin: BinderOrigin) {
        pendingBinderRestoration = origin
        finishBinderRestorationIfReady()
    }

    @discardableResult
    private func finishBinderRestorationIfReady() -> Bool {
        guard let origin = pendingBinderRestoration else { return true }
        guard contentHash != nil, result != nil, !isRendering else { return false }
        guard isUpToDate else {
            render()
            return false
        }
        pendingBinderRestoration = nil
        let mapped = BinderOrigin(
            contents: origin.contents, frame: origin.frame,
            pageIndex: min(origin.pageIndex, max(0, pageCount - 1)), wasPrinting: origin.wasPrinting,
            leavingBinder: true)
        restoreWindow(mapped)
        if origin.wasPrinting {
            // Enter without animating through a different frame: the source was already on this tray.
            mode = .print
            refreshPrinters()
            rememberStageBandRoom()
            if let window {
                ViewerWindow.unlockAspectRatio(of: window)
                ViewerWindow.setTrafficLightsVisible(true, in: window)
            }
            binderExitTrayPage = mapped.pageIndex
            renderForChangedSettings()
        } else {
            sizeWindowToPaper()
            if let window { window.setFrameOrigin(origin.frame.origin) }
        }
        return true
    }

    /// Back where a window was before a binder took its place.
    func restoreWindow(_ origin: BinderOrigin) {
        hasSizedWindow = true
        currentPageIndex = origin.pageIndex
        paper.goToPage(index: origin.pageIndex)
        guard let window else { return }
        ViewerWindow.setFrame(origin.frame, of: window, animate: false)
    }

    var offersTypeface: Bool { Typeface.isAvailable(themeID: themeID, usesPrintTheme: usesPrintTheme) }

    func setTypeface(_ value: Typeface) {
        guard usesPrintTheme, typeface != value else { return }
        themeTrial.end()
        chosenTrial = nil
        typeface = value
    }

    /// Any whole percent of the range; a value between two percents takes the nearer one.
    func setTextScale(_ value: Double) {
        guard !isWindowClosed, usesPrintTheme, value.isFinite, TextScale.range.contains(value) else { return }
        textScale = TextScale.clamped(value)
    }

    func increaseTextSize() { setTextScale(TextScale.larger(than: textScale)) }
    func decreaseTextSize() { setTextScale(TextScale.smaller(than: textScale)) }
    func resetTextSize() { setTextScale(1) }

    /// Only themed text guarantees blank margins. HTML may override them with @page rules, and the
    /// prepared pages do not expose that information here, so HTML keeps all its content like PDFs and images.
    var viewLogicalMargin: CGFloat? {
        guard imageBundle == nil, format.usesPrintTheme else { return nil }
        // Keep the margin attached to the pages still on screen while a new layout is being prepared.
        guard let settings = renderedSettings else { return nil }
        // Joined pages lose this much on every side, which uneven margins must not take out of the text.
        return CGFloat(
            settings.layout.logicalMargins(options: result?.options ?? settings.options).smallest * 72 / 25.4)
    }

    /// Whether the margin shows on the pages view mode displays. PDFs keep their own margins, and the 3-up handout
    /// insets the sheet instead of its logical pages.
    var marginsApply: Bool { (binder != nil || format != .pdf) && renderLayout.kind != .handout3 }

    /// Whether the margin changes the printed sheets: everything but PDFs, including the 3-up handout's sheet.
    var marginsAffectPrinting: Bool { binder != nil || format != .pdf }

    var usesDocumentMargins: Bool {
        themeFormat == .latex && printOptions.latexMargins?.applies(to: theme(themeID)) == true
    }

    var usesDocumentFurniture: Bool {
        themeFormat == .latex && printOptions.latexFurniture?.applies(to: theme(themeID)) == true
    }

    func marginLabel(in unit: MarginUnit) -> String {
        if usesDocumentMargins { return String(localized: "As the Document") }
        return printOptions.margins.uniformValue.map { unit.label($0) } ?? String(localized: "Mixed")
    }

    /// The presets of the unit, plus the current margin when it is none of them, so the menu always checks it.
    func marginChoices(in unit: MarginUnit) -> [Double] { unit.choices(including: printOptions.margins.uniformValue) }

    /// The one way to give all four margins one value, so the viewer and the tray re-paginate and remember it the same
    /// way.
    func setMargins(_ millimeters: Double) {
        guard millimeters.isFinite else { return }
        printOptions.latexMargins = nil
        printOptions.margins = .uniform(PageMargins.clamped(millimeters))
        printOptions.linksMargins = true
    }

    /// Changes one margin, or all four while the tray keeps them together.
    func setMargin(_ side: WritableKeyPath<PageMargins, Double>, to millimeters: Double) {
        guard millimeters.isFinite else { return }
        guard !printOptions.linksMargins else { return setMargins(millimeters) }
        printOptions.latexMargins = nil
        printOptions.margins[keyPath: side] = PageMargins.clamped(millimeters)
    }

    /// Keeping the margins together evens them out to the top margin.
    func setMarginsLinked(_ linked: Bool) {
        printOptions.linksMargins = linked
        if linked { printOptions.margins = .uniform(printOptions.margins.top) }
    }

    /// A popover can leave its parent window's paper as first responder while it is opening.
    var blocksSurfaceShortcuts: Bool {
        isViewOptionsPresented || isThemePalettePresented || isPrintFinishPresented
            || isOutlinePresented || isFiguresPresented || isLaTeXRecognitionPresented || isGoToPagePresented
            || isReviewingSmartRemoval
            || isPrintIssuesPresented || showsNoteAdjustments
    }

    // MARK: - View mode

    func setLayout(_ layout: ViewOptions.Layout) { updateViewOptions { $0.layout = layout } }

    /// Applies a change the user made; the defaults picked once the pages are known no longer replace it.
    func updateViewOptions(_ change: (inout ViewOptions) -> Void) {
        var options = viewOptions
        change(&options)
        if options.direction != viewOptions.direction { chosenReadingOrder.direction = options.direction }
        if options.scrollAxis != viewOptions.scrollAxis { chosenReadingOrder.axis = options.scrollAxis }
        hasResolvedViewOptions = true
        viewOptions = options
    }

    func enterPrintMode() {
        pendingPrintIssue = nil
        dropSpot()
        guard mode != .print else { return }
        guard mode == .view, isWebPresentation || isCapturingWeb || webCaptureFailed else { return showPrintTray() }
        // The tray prints the page as it is now. One request waits for the copy at a time, and it opens the tray
        // only if the reader has not chosen something else since.
        guard !(isCapturingWeb && captureOpensTray) else { return }
        captureOpensTray = true
        captureWeb { [weak self] outcome in
            guard let self, captureOpensTray else { return }
            captureOpensTray = false
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

    func closeBandPopovers() {
        isViewOptionsPresented = false
        isOutlinePresented = false
        isLaTeXRecognitionPresented = false
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
        // The view mode's print settings hang off the window's edge, which the tray's frame moves away.
        isPrintFinishPresented = false
        showsFold = false
        // The tray shows what prints, so the review and its outlined pages end here.
        isReviewingSmartRemoval = false
        viewPaperSizeBeforePrinting = currentPaperSize ?? viewPaperSizeBeforePrinting
        rememberStageBandRoom()
        mode = .print
        if isUpToDate {
            if !hasCurrentPrintPreview { render(reusing: result) }
        } else if error == nil {
            renderForChangedSettings()
        }
        // The pages read are often the tray's already, and then no render follows to count their sheets.
        if isUpToDate, hasCurrentPrintPreview, let settings = renderedSettings, let output = printResult {
            trayFigures = TrayFigures(
                settings: settings, data: data, sourceURLs: sourceURLs, sheetCount: output.plan.sheetCount,
                paper: output.plan.paper.shortName)
        }
        guard let window else { return }
        // Stage controls need free resizing and visible traffic lights.
        ViewerWindow.setTrafficLightsVisible(true, in: window)
        PrintModeWindow.enter(window, size: traySize)
    }

    /// Switching from one stage to the other keeps the room of the view mode the window left.
    private func rememberStageBandRoom() {
        if stageBandRoom == nil { stageBandRoom = currentBandRoom }
        // The view mode's bands start hidden again on the way back, where the remembered room is given back.
        revealedBandRoom = BandRoom()
        areHoverBandsShown = false
        pendsBandRoomRelease = false
    }

    /// The tray keeps the list beside the sheets, which need their own room next to it.
    var traySize: NSSize {
        var size = PrintModeWindow.traySize
        if binder != nil || imageBundle != nil { size.width += SidePanelMetrics.width }
        return size
    }

    var compareFilterID = "featured"

    func enterCompareMode() {
        guard !isWindowClosed else { return }
        guard mode == .view, usesPrintTheme else { return }
        pendingPrintIssue = nil
        dropSpot()
        isThemePalettePresented = false
        themeTrial.end()
        closeBandPopovers()
        isPrintFinishPresented = false
        viewPaperSizeBeforePrinting = currentPaperSize ?? viewPaperSizeBeforePrinting
        let featured = availableThemes.filter { $0.featuredRank != nil }
            .sorted { ($0.featuredRank ?? 0) < ($1.featuredRank ?? 0) }.map(\.id)
        if themeComparison?.current != themeID
            || themeComparison?.candidates.contains(where: { theme($0) == nil }) == true
        {
            // The theme chosen since leads; the latest choices of an earlier visit follow, before the suggestions.
            themeComparison = ThemeComparison(
                current: themeID,
                suggestions: (themeComparison?.candidates.reversed().filter { theme($0) != nil } ?? []) + featured)
        }
        compareFilterID = themeMenu.sections.first(where: \.isFormatSpecific)?.id ?? "featured"
        rememberStageBandRoom()
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
        isPrintFinishPresented = false
        themePaletteDidClose()
        outputAfterReview = nil
        guard let window else {
            resetPrintChoices()
            stageBandRoom = nil
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
            // In full screen the frame is the system's; the window catches up when it leaves full screen.
            guard !isInFullScreen else {
                resumePrintIssueNavigation()
                return
            }
            // The frame is the one from before the stage, or the stage's own; either holds the room the bands had then.
            if let room = stageBandRoom {
                stageBandRoom = nil
                if room != currentBandRoom { bandRoomDidChange(from: room, animate: false) }
            }
            // The view mode shows only the paper, and the print layout may have changed the pages' shape on the
            // stage, so the window keeps its height and takes the pages' width again.
            if returnsToRestoredPaperSize {
                returnsToRestoredPaperSize = false
                applyRestoredPaperSize()
            } else {
                // In the same step as the frame from before the stage: a fit animated after it showed the window
                // jump back and then slide to the pages' new shape.
                sizeWindowToPaper(keepHeight: true, animate: false)
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
    /// being copied for the tray is already on its way there. A copy made for another reason (the failure notice's
    /// Try Again) does not open the tray, so the first request during it joins that copy.
    func pageDidRequestPrint() {
        guard showsWeb, !(isCapturingWeb && captureOpensTray), isWindowActive else { return }
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
        // A tray waiting for the copy would close the review as soon as the copy arrived.
        captureOpensTray = false
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
        imageBundle == nil && isOutlineDrawerOpen && hasContents && usesOutlineDrawer
    }
    var usesOutlineDrawer: Bool {
        #if DEBUG
            if snapshotOutlineDrawer { return true }
        #endif
        return preferences.outlinePresentation == .drawer
    }

    var chapterEntries: [OutlineEntry] {
        let level = DocumentOutline.chapterLevel(of: outlineEntries.map(\.level))
        return outlineEntries.filter { $0.level == level }
    }

    var currentChapterTitle: String {
        DocumentOutline.currentChapter(in: outlineEntries, page: lastVisiblePageIndex)
            .map { outlineEntries[$0].title } ?? ""
    }

    var isOutlineShown: Bool { isOutlinePresented || showsOutlineDrawer || (imageBundle != nil && showsSideList) }

    private static let outlineDrawerMinimumWindowWidth: CGFloat = 560

    func toggleOutline() {
        guard mode == .view, hasContents else { return }
        if showsOutlineDrawer || (imageBundle != nil && showsSideList) {
            setContentsOpen(false)
        } else if !usesOutlineDrawer {
            isOutlinePresented.toggle()
        } else {
            // The drawer takes its width from the paper, which a narrow window does not have to spare.
            if (window?.frame.width ?? .infinity) < Self.outlineDrawerMinimumWindowWidth {
                isOutlineDrawerOpen = false
                isOutlinePresented.toggle()
            } else {
                setContentsOpen(true)
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
        guard canNavigateReading, let page = entry.pageIndex else { return }
        isOutlinePresented = false
        jumpToReadingPage(page)
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
    private func refreshStructure(
        of source: DocumentSource, in prepared: PreparedRender, forReading: Bool, settings: RenderSettings
    ) {
        guard forReading, structureDocument !== prepared.logicalDocument else { return }
        structureDocument = prepared.logicalDocument
        structureTask?.cancel()
        let document = prepared.logicalDocument
        guard binder == nil, imageBundle == nil, source.images == nil, source.children == nil else { return }
        if source.format == .pdf {
            outlineEntries = PDFOutlineReader.entries(of: document)
            return
        }
        if let facts = prepared.facts, let entries = facts.beamerOutline {
            outlineEntries = entries
            documentStatistics = facts.statistics
            return
        }
        guard source.format.isWebRendered else { return }
        let proof = settings.finish.proof
        let org = settings.orgReading
        let known =
            readStructure?.source == source && readStructure?.proof == proof && readStructure?.orgReading == org
            ? readStructure : nil
        let includesSourceContents = !finishAppliesToText || printFinish.toc.showsSourceContents
        structureTask = Task { [weak self] in
            let read:
                (
                    headings: [DocumentHeading], statistics: DocumentStatistics,
                    contents: [String], title: String?
                )?
            if let known {
                read = (known.headings, known.statistics, known.contents, known.title)
            } else {
                read = await Task.detached(priority: .utility) {
                    DocumentRenderer.structureHTML(of: source, proof: proof, orgReading: org).map {
                        (
                            DocumentOutline.headings(inHTML: $0), DocumentStatistics(html: $0),
                            DocumentOutline.sourceContentsEntries(inHTML: $0), DocumentOutline.title(ofHTML: $0)
                        )
                    }
                }.value
            }
            guard !Task.isCancelled, let read else { return }
            self?.readStructure = (source, proof, org, read.headings, read.statistics, read.contents, read.title)
            self?.documentStatistics = read.statistics
            var texts: [String] = []
            for index in 0..<(read.headings.isEmpty ? 0 : document.pageCount) {
                texts.append(document.page(at: index)?.string ?? "")
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
            let headings = read.headings
            let pages = texts
            // A table the finish hides is not on the pages, and its lines would be taken from the real headings.
            let contents = includesSourceContents ? read.contents : []
            let entries = await Task.detached(priority: .utility) {
                DocumentOutline.entries(of: headings, inPageTexts: pages, contentsEntries: contents)
            }.value
            guard !Task.isCancelled else { return }
            self?.outlineEntries = entries
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
            if let page = ChangeNavigation.next(after: currentPageIndex - 1, in: pages) {
                currentPageIndex = page
                paper.followChange(
                    on: page, in: prepared.viewDocument, pinnedBandHeight: isBandAlwaysVisible ? topBandHeight : 0)
            }
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
        if let page = ChangeNavigation.next(after: lastVisiblePageIndex, in: pages), let paperDocument {
            paper.followChange(on: page, in: paperDocument, pinnedBandHeight: isBandAlwaysVisible ? topBandHeight : 0)
        }
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
        showVerticalWritingNoteIfNeeded()
        guard wasWeb, capturesWeb else { return sizeWindowToPaper(keepHeight: true) }
        captureWeb { [weak self] outcome in
            // Paper then shows the last copy, or the file.
            if outcome == .failed { self?.showCaptureFailure() }
            self?.sizeWindowToPaper(keepHeight: true)
        }
    }

    // MARK: - Slides

    /// The deck the app treats the page as: the one measured, unless the reader said it is not one.
    var slideDeck: SlideDeck? {
        if format == .latex, binder == nil, textKind == nil, let facts = result?.facts, let size = facts.beamerPageSize
        {
            let count = facts.beamerPageFrames.count
            guard count > 0 else { return nil }
            return SlideDeck(
                size: CGSize(width: size.width * 96 / 72, height: size.height * 96 / 72), count: count,
                currentIndex: min(max(0, currentPageIndex), count - 1))
        }
        return usesHTMLPresentation && !ignoresSlides ? detectedSlideDeck : nil
    }

    static func slideIndicator(_ slide: Int, of count: Int) -> String {
        String(format: String(localized: "Slide %lld of %lld"), slide, count)
    }

    /// The live page was measured again. Only a new shape changes the window; turning slides changes the indicator.
    func slideDeckDidChange(_ deck: SlideDeck?) {
        let reshapes = !(deck?.hasSameShape(as: detectedSlideDeck) ?? (detectedSlideDeck == nil))
        detectedSlideDeck = deck
        if reshapes, !ignoresSlides { applyWebShape() }
    }

    /// The "…" and View menus' 「スライドとして表示」, turned off for a page that only looks like a deck.
    func setIgnoresSlides(_ ignores: Bool) {
        guard usesHTMLPresentation, ignoresSlides != ignores else { return }
        ignoresSlides = ignores
        if ignores { printsCurrentSlideOnly = false }
        applyWebShape()
    }

    /// The reader's command 「スライドとして表示」. A page with no slides found has nothing to switch, so the command
    /// leaves its setting alone instead of quietly saving "not a deck" for a page whose slides are measured later.
    func toggleShowsSlides() {
        guard detectedSlideDeck != nil else { return }
        setIgnoresSlides(!ignoresSlides)
    }

    /// On the web a deck shows one slide to the window: the window takes the slide's shape, keeping its height, and
    /// the page zooms to fit unless the deck scales itself. An ordinary page takes any shape the reader gives it.
    func applyWebShape(animate: Bool = true) {
        web.fitSize = slideDeck.flatMap { $0.scalesItself ? nil : $0.size }
        guard showsWeb, !isInFullScreen, let window else { return }
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
            let taskBeforeCompletions = renderTask
            webCaptureFailed = snapshot == .failed
            var needsRender = false
            if case .captured(let copy) = snapshot, copy != liveSnapshot {
                liveSnapshot = copy
                // The pages of the previous state must not show or print in the meantime.
                result = nil
                printResult = nil
                printTray = nil
                printTraySettings = nil
                printTraySourceURLs = nil
                needsRender = true
                isRendering = true
            }
            let outcome: CaptureOutcome = snapshot == .failed ? .failed : isRendering ? .rendering : .ready
            for completion in completions { completion(outcome) }
            // Entering the tray may already have started rendering this copy with its final settings.
            if needsRender, renderTask == taskBeforeCompletions { render() }
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
        captureOpensTray = false
        webCaptureFailed = false
    }

    /// The failure notice's Try Again: copy the page again and show paper from the new copy.
    func retryWebCapture() {
        dismissToast()
        guard usesHTMLPresentation, webCaptureFailed else { return }
        // A page whose process ended has nothing to copy until it is loaded again; the copy waits for that load.
        web.reloadEndedPage()
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
    func deferUntilWebIsCaptured(_ output: Output) -> Bool {
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
        case .manualDuplex: printDocument(intent: .manualDuplex)
        case .exportPDF: exportPDF()
        case .exportReadingPDF: exportReadingPDF()
        case .additional(let kind): exportReading(kind)
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

    func applyWindowSpacesAfterUpdate() {
        Task { @MainActor [weak self] in
            guard let self, !isInFullScreen, let window else { return }
            ViewerWindow.setShowsOnAllSpaces(showsOnAllSpaces, in: window)
        }
    }

    /// Picks the reading layout once the pages are known, unless the user already chose one for this document.
    private func resolveViewOptionsIfNeeded(for document: PDFDocument) {
        guard defaultViewOptions == nil else { return }
        let defaults = ViewOptions.resolved(for: viewDefaultsContext(for: document), preferences: openingViewDefaults)
        defaultViewOptions = defaults
        if !hasResolvedViewOptions {
            hasResolvedViewOptions = true
            viewOptions = viewDefaults(forTheme: themeID)
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
        case .markdown, .org, .plainText, .html, .csv, .latex, .asciidoc, .quarto, .rMarkdown, .djot, .textile,
            .mediawiki, .rst,
            .docx, .notebook, .graphviz,
            .plantuml:
            return .flowingText
        }
    }

    // MARK: - Remembered settings

    private static let logger = Logger(subsystem: "app.surimono.Surimono", category: "DocumentSettings")

    /// What is remembered for this document by its content. The window size is added when saving, because a resize is
    /// only a change once it ends.
    var rememberedSettings: DocumentSettings {
        DocumentSettings(
            view: viewOptions, zoom: (zoom * 100).rounded() / 100, layoutID: layoutID,
            themeID: usesPrintTheme ? themeID : nil,
            textScale: usesPrintTheme ? textScale : nil,
            typeface: usesPrintTheme && typeface != .style ? typeface : nil, presetID: usesHTMLPreset ? presetID : nil,
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
            codeBlock: usesPrintTheme && codeBlock != defaultCodeBlock ? codeBlock : nil,
            bandVisibility: bandVisibility == defaultBandVisibility ? nil : bandVisibility,
            notes: offersNotes && notes != NotePages() ? notes : nil, bookletBinding: bookletBinding,
            pageRange: pageRange.isAll ? nil : pageRange, bookmarks: bookmarks.isEmpty ? nil : bookmarks,
            latexComposition: format == .latex && savedComposition != .document ? savedComposition : nil,
            contentsPanel: contentsPanel == .init() ? nil : contentsPanel,
            orgReading: format == .org && binder == nil && orgDocumentReading != .init() ? orgDocumentReading : nil)
    }

    var currentPrintSettingSet: PrintSettingSet {
        var set = PrintSettingSet(name: "", settings: rememberedSettings)
        // A set saved without notes turns them off, which a document's record has no need to say.
        if offersNotes { set.notes = notes }
        return applicablePrintSettingSet(set)
    }

    func savePrintSettingSet(named name: String, parts: Set<PrintSettingSet.Part> = Set(PrintSettingSet.Part.allCases))
    {
        var set = currentPrintSettingSet.keeping(parts)
        guard !set.parts.isEmpty else { return }
        set.name = name
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
        savePrintSettingSet(named: set.name, parts: set.parts)
    }

    private func applicablePrintSettingSet(_ set: PrintSettingSet) -> PrintSettingSet {
        var set = set.applicable(
            to: Set(binder?.items.map(\.format) ?? [format]),
            themeIDs: Set(availableThemes.map(\.id)), presetIDs: Set(library.presets.map(\.id)))
        if themeFormat != .latex {
            set.latexMargins = nil
            set.latexFurniture = nil
        }
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
        if let margins = set.margins {
            printOptions.latexMargins = themeFormat == .latex ? set.latexMargins : nil
            printOptions.margins = margins
        }
        if let links = set.linksMargins {
            printOptions.linksMargins = links
        } else if set.margins != nil {
            printOptions.linksMargins = printOptions.margins.uniformValue != nil
        }
        if let mirrors = set.mirrorsMargins { printOptions.mirrorsMargins = mirrors }
        if let furniture = set.furniture {
            isWritingFurniture = false
            printOptions.latexFurniture = themeFormat == .latex ? set.latexFurniture : nil
            printOptions.furniture = furniture
        }
        if let finish = set.finish { printFinish = finish }
        if let notes = set.notes { self.notes = notes }
        selectedSettingSetID = set.id
        if let id = set.themeID { themeID = id }
        if let face = set.typeface { setTypeface(face) }
        if let scale = set.textScale { setTextScale(scale) }
        if let id = set.presetID { presetID = id }
        // Applying a set is a user change, not a new baseline or a theme-menu selection.
        rememberedSettingsDidChange()
    }

    /// What this document has when the user changes nothing. Until the pages are known, the reading layout is the
    /// initial guess, so a layout chosen while the pages are prepared still counts as a change.
    private var defaultSettings: DocumentSettings {
        defaultsWithDirectives(appDefaultSettings)
    }

    private var appDefaultSettings: DocumentSettings {
        DocumentSettings(
            view: viewDefaults(forTheme: defaultThemeID), zoom: 1,
            layoutID: classLayout?.id ?? Self.defaultLayoutID(preferences),
            themeID: usesPrintTheme ? defaultThemeID : nil,
            textScale: usesPrintTheme ? defaultTextScale : nil,
            typeface: usesPrintTheme && defaultTypeface != .style ? defaultTypeface : nil,
            presetID: usesHTMLPreset ? Self.defaultPresetID(preferences, library) : nil,
            printOptions: preferences.printOptions.defaults(for: themeFormat),
            paperOrientation: defaultPaperOrientation,
            htmlPresentation: usesHTMLPresentation ? .web : nil,
            binderStartsOnFront: binder != nil ? false : nil,
            printFinish: finishAppliesToText ? preferences.printFinish : nil,
            codePaletteID: usesPrintTheme ? Self.defaultCodePaletteID(preferences, library) : nil)
    }

    private func defaultsWithDirectives(_ defaults: DocumentSettings) -> DocumentSettings {
        guard format == .markdown, binder == nil, imageBundle == nil else { return defaults }
        var resolved = defaults
        if let name = documentDirectives.setName,
            let named = preferences.printSettingSets.first(where: { $0.name == name })
        {
            let set = applicablePrintSettingSet(named)
            if let id = set.layoutID { resolved.layoutID = id }
            if let orientation = set.paperOrientation { resolved.paperOrientation = orientation }
            var options = resolved.printOptions ?? PrintOptions()
            if let margins = set.margins { options.margins = margins }
            if let links = set.linksMargins {
                options.linksMargins = links
            } else if set.margins != nil {
                options.linksMargins = options.margins.uniformValue != nil
            }
            if let mirrors = set.mirrorsMargins { options.mirrorsMargins = mirrors }
            if let furniture = set.furniture { options.furniture = furniture }
            resolved.printOptions = options
            if let finish = set.finish { resolved.printFinish = finish }
            if let notes = set.notes { resolved.notes = notes == NotePages() ? nil : notes }
            if let id = set.themeID { resolved.themeID = id }
            if let face = set.typeface { resolved.typeface = face == .style ? nil : face }
            if let scale = set.textScale { resolved.textScale = scale }
        }
        if let id = documentDirectives.layoutID,
            let layout = PrintLayout.presets.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame })
        {
            resolved.layoutID = layout.id
        }
        if let orientation = documentDirectives.orientation { resolved.paperOrientation = orientation }
        if let margin = documentDirectives.marginMillimeters {
            resolved.printOptions?.margins = PageMargins.uniform(margin)
            resolved.printOptions?.linksMargins = true
        }
        if let style = documentDirectives.style,
            let theme = availableThemes.first(where: {
                [$0.id, $0.name, $0.localizedNames["ja"] ?? ""].contains {
                    $0.caseInsensitiveCompare(style) == .orderedSame
                }
            })
        {
            resolved.themeID = theme.id
        }
        resolved.view = viewDefaults(forTheme: resolved.themeID)
        if let scale = documentDirectives.textScale { resolved.textScale = scale }
        return resolved
    }

    private func applyDirectiveDefaults() {
        let resolved = defaultSettings
        if let id = resolved.layoutID { layoutID = id }
        if let orientation = resolved.paperOrientation { paperOrientation = orientation }
        if let options = resolved.printOptions { printOptions = options }
        if let finish = resolved.printFinish { printFinish = finish }
        notes = resolved.notes ?? NotePages()
        if let id = resolved.themeID { themeID = id }
        setTypeface(resolved.typeface ?? .style)
        if let scale = resolved.textScale { setTextScale(scale) }
    }

    private var currentDirectives: DocumentDirectives {
        guard format == .markdown, binder == nil, imageBundle == nil else { return DocumentDirectives() }
        return DocumentDirectives.read(fromMarkdown: TextDecoding.decode(data).text)
    }

    private static func defaultLayoutID(_ preferences: AppPreferences) -> String {
        PrintLayout.presets.contains(where: { $0.id == preferences.layoutID })
            ? preferences.layoutID : PrintLayout.a4Single.id
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
        defer {
            applyRestoredPageIfReady()
            if pendingBinderRestoration != nil, finishBinderRestorationIfReady() {
                finishFirstRender(succeeded: true)
            }
        }
        let previous = contentHash
        guard previous != hash else { return }
        let previousSources = hashedSourceURLs
        contentHash = hash
        hashedSourceURLs = Set(sourceURLs)
        if let previous {
            validatesMigratedContent = false
            // Saved in an editor while open: the settings on screen carry over to the new content.
            guard hasSavedSettings, saveSettings() else { return }
            // The same files no longer have the content the previous record described, so every save in the editor
            // would leave one more record behind and push other documents' settings out of the store. A set that
            // gained or lost a file still exists as it was, and keeps its record.
            if let token = ownedRecordTokens.removeValue(forKey: previous.hex), previousSources == hashedSourceURLs,
                settingsStore?.token(for: previous.hex) == token,
                location?.store.contains(previous) != true
            {
                try? settingsStore?.removeRecord(for: previous.hex)
            }
            return
        }
        let saved = savedSettings(for: hash)
        if keepsSettingsOverSaved, saved != nil {
            // What this window took over replaces the record, even where it equals the defaults.
            settingsBaseline = defaultSettings
            saveSettings(force: true)
            return
        }
        guard let saved else {
            let untouched = rememberedSettings == appDefaultSettings && !didCustomizeSinceLoad && !didResizeWindow
            documentDirectives = currentDirectives
            if untouched {
                settingsBaseline = nil
                applyDirectiveDefaults()
            }
            // Anything that already differs from the defaults was changed by the user while the content was read.
            settingsBaseline = defaultSettings
            rememberedSettingsDidChange()
            return
        }
        documentDirectives = currentDirectives
        bookmarks = saved.bookmarks ?? Bookmarks()
        apply(saved)
        hasSavedSettings = true
        settingsBaseline = rememberedSettings
        validateMigratedContentIfReady()
    }

    private func savedSettings(for hash: ContentHash) -> DocumentSettings? {
        guard let settingsStore else { return nil }
        if let saved = settingsStore.record(for: hash.hex) {
            rememberLocation(for: hash)
            return saved
        }
        guard openFailure == nil, let location, let previous = location.store.record(for: location.key),
            previous != hash, let saved = settingsStore.record(for: previous.hex)
        else { return nil }
        validatesMigratedContent = saved.imageOrder != nil || saved.smartRemoval?.keptIDs.isEmpty == false
        // A newly opened window has no ownership token for the previous record. A copy may still use it.
        do {
            try writeRecord(saved, for: hash, in: settingsStore)
            rememberLocation(for: hash)
        } catch {
            Self.logger.error("Saving document settings for the changed file failed.")
        }
        return saved
    }

    private func validateMigratedContentIfReady() {
        guard validatesMigratedContent else { return }
        // The hash can arrive before or after image digests and HTML candidates are available.
        if let imageBundle {
            guard imageBundle.orderDigests != nil else { return }
            validatesMigratedContent = false
            guard let order = pendingImageOrder else { return }
            pendingImageOrder = nil
            if imageBundle.applyOrder(order) {
                settingsBaseline = rememberedSettings
                return
            }
        } else {
            guard renderedSettings?.smartRemoval != nil, renderedSettings == renderSettings,
                !renderedFromSnapshot, result?.requiredFolderAccess == nil
            else { return }
            validatesMigratedContent = false
            let candidates = Set(smartRemovalCandidates.map(\.id))
            let kept = smartRemovalKeptIDs.filter(candidates.contains)
            guard kept != smartRemovalKeptIDs else { return }
            smartRemovalKeptIDs = kept
            settingsBaseline?.smartRemoval?.keptIDs = kept
        }
        // Another window may have saved new choices while this one waited for the render.
        if let key = contentHash?.hex, let token = ownedRecordTokens[key], settingsStore?.token(for: key) == token {
            saveSettings(force: true)
        }
    }

    func restoreClosedDocument(_ settings: DocumentSettings) {
        didCustomizeSinceLoad = true
        hasSavedSettings = true
        bookmarks = settings.bookmarks ?? Bookmarks()
        apply(settings)
    }

    private func restoreContentsPanel(_ panel: DocumentSettings.ContentsPanel?) {
        contentsPanel = panel ?? .init()
        if imageBundle != nil {
            isDrawerOpen = contentsPanel.isOpen ?? false
        } else {
            isOutlineDrawerOpen = contentsPanel.isOpen ?? false
        }
    }

    private func apply(_ saved: DocumentSettings) {
        restoreContentsPanel(saved.contentsPanel)
        binderStartsOnFront = saved.binderStartsOnFront ?? false
        bandVisibility = saved.bandVisibility ?? defaultBandVisibility
        if let order = saved.binderOrder { binder?.applyOrder(order) }
        orgDocumentReading = saved.orgReading ?? .init()
        savedComposition = saved.latexComposition ?? .document
        setTypeface(saved.typeface ?? .style)
        if let scale = saved.textScale { setTextScale(scale) }
        if let view = saved.view {
            chosenReadingOrder = (view.direction, view.scrollAxis)
            viewOptions = view
            hasResolvedViewOptions = true
        }
        if let zoom = saved.zoom { self.zoom = min(max(zoom, 1), PaperPDFView.maximumZoom) }
        if let orientation = saved.paperOrientation { paperOrientation = orientation }
        bookletBinding = saved.bookletBinding
        if let id = saved.layoutID, PrintLayout.presets.contains(where: { $0.id == id }) { layoutID = id }
        if let id = saved.themeID, theme(id) != nil { themeID = id }
        if let id = saved.codePaletteID.flatMap({ Self.knownCodePaletteID($0, library) }) { codePaletteID = id }
        chosenCodeBlock = saved.codeBlock
        if let id = saved.presetID, library.presets.contains(where: { $0.id == id }) { presetID = id }
        if var options = saved.printOptions {
            if themeFormat != .latex {
                options.latexMargins = nil
                options.latexFurniture = nil
            }
            printOptions = options
        }
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
        guard !isWindowClosed else { return }
        if let binder, binder.setHash != contentHash { return }
        guard contentHash != nil, let settingsBaseline, rememberedSettings != settingsBaseline else { return }
        didCustomizeSinceLoad = true
        scheduleSave()
    }

    /// Saves now what a change scheduled; quitting ends the app before the delay has passed.
    func flushPendingSettings() {
        if saveTask != nil { saveSettings() }
    }

    private func scheduleSave() {
        if keepsClipboardSettingsInMemory {
            hasSavedSettings = true
            return
        }
        guard settingsStore != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.saveSettings()
        }
    }

    /// The previous record can be retired only once both the settings and their location were saved.
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
        // A resize or another choice can be saved before the ZIP has finished hashing its images.
        if validatesMigratedContent, let pendingImageOrder { settings.imageOrder = pendingImageOrder }
        settings.windowSize = currentPaperSize ?? viewPaperSizeBeforePrinting ?? restoredPaperSize
        do {
            try writeRecord(settings, for: contentHash, in: settingsStore)
            hasSavedSettings = true
            didResizeWindow = false
            settingsBaseline = rememberedSettings
            return rememberLocation(for: contentHash)
        } catch {
            Self.logger.error("Saving document settings failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func writeRecord(_ settings: DocumentSettings, for hash: ContentHash, in store: DocumentSettingsStore)
        throws
    {
        // Without reading the record, which would itself change its state.
        let before = store.token(for: hash.hex)
        let owns = before == nil || before == ownedRecordTokens[hash.hex]
        try store.save(settings, for: hash.hex)
        ownedRecordTokens[hash.hex] = owns ? store.token(for: hash.hex) : nil
    }

    @discardableResult
    private func rememberLocation(for hash: ContentHash) -> Bool {
        guard let location else { return true }
        do {
            if location.store.record(for: location.key) != hash {
                try location.store.save(hash, for: location.key)
            }
            return true
        } catch {
            Self.logger.error("Updating the location for document settings failed.")
            return false
        }
    }

    /// Goes back to the defaults at once; the toast and the window's undo are the way back.
    func resetDocumentSettings() {
        let origin = ResetOrigin(
            settings: rememberedSettings, chosenReadingOrder: chosenReadingOrder, wasSaved: hasSavedSettings,
            selectedSettingSetID: selectedSettingSetID,
            paperSize: currentPaperSize ?? viewPaperSizeBeforePrinting ?? restoredPaperSize,
            defaultTextScale: defaultTextScale, defaultTypeface: defaultTypeface,
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
        defaultTypeface = origin.defaultTypeface
        defaultTextScale = origin.defaultTextScale
        defaultPaperOrientation = origin.defaultPaperOrientation
        defaultBandVisibility = origin.defaultBandVisibility
        openingViewDefaults = origin.openingViewDefaults
        defaultViewOptions = origin.defaultViewOptions
        apply(origin.settings)
        chosenReadingOrder = origin.chosenReadingOrder
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
        settingsBaseline = nil
        dismissToast()
        saveTask?.cancel()
        saveTask = nil
        if let location { try? location.store.removeRecord(for: location.key) }
        if bookmarks.isEmpty, let contentHash {
            try? settingsStore?.removeRecord(for: contentHash.hex)
            ownedRecordTokens[contentHash.hex] = nil
        }
        hasSavedSettings = false
        chosenReadingOrder = (nil, nil)
        validatesMigratedContent = false
        pendingImageOrder = nil
        restoredPaperSize = nil
        returnsToRestoredPaperSize = false
        defaultTypeface = preferences.defaultTypeface
        defaultTextScale = preferences.defaultTextScale
        defaultPaperOrientation = preferences.defaultPaperOrientation
        defaultBandVisibility = preferences.defaultBandVisibility
        bandVisibility = defaultBandVisibility
        orgDocumentReading = .init()
        savedComposition = .document
        typeface = usesPrintTheme ? defaultTypeface : .style
        textScale = usesPrintTheme ? defaultTextScale : 1
        paperOrientation = defaultPaperOrientation
        layoutID = classLayout?.id ?? Self.defaultLayoutID(preferences)
        bookletBinding = nil
        themeID = defaultThemeID
        codePaletteID = Self.defaultCodePaletteID(preferences, library)
        chosenCodeBlock = nil
        presetID = Self.defaultPresetID(preferences, library)
        printOptions = preferences.printOptions.defaults(for: themeFormat)
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
        restoreContentsPanel(nil)
        imageBundle?.sortByName()
        binder?.resetOrder()
        binderStartsOnFront = false
        openingViewDefaults = preferences.viewDefaults
        if let document = result?.viewDocument {
            defaultViewOptions = ViewOptions.resolved(
                for: viewDefaultsContext(for: document), preferences: openingViewDefaults)
        }
        viewOptions = viewDefaults(forTheme: themeID)
        if resizesWindow, mode == .view, let window, let unit = paperUnitSize {
            ViewerWindow.setPaperSize(
                ViewerWindow.initialPaperSize(unit: unit, on: window.screen, side: sideInset), band: bandInset,
                of: window,
                animate: true, side: sideInset)
        }
        documentDirectives = currentDirectives
        applyDirectiveDefaults()
        didCustomizeSinceLoad = false
        // The pending save of a resize was cancelled above; left set, the flag would hold later directives back.
        didResizeWindow = false
        settingsBaseline = rememberedSettings
        if !bookmarks.isEmpty, let contentHash {
            do {
                try settingsStore?.save(DocumentSettings(bookmarks: bookmarks), for: contentHash.hex)
                ownedRecordTokens[contentHash.hex] = settingsStore?.token(for: contentHash.hex)
                hasSavedSettings = settingsStore != nil
            } catch {
                Self.logger.error(
                    "Saving bookmarks after reset failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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

    /// The room the bands take beside the paper.
    var bandInset: CGFloat { currentBandRoom.total }

    var currentBandRoom: BandRoom {
        Self.bandRoom(of: menuArrangement, bandVisibility, revealed: revealedBandRoom, top: topBandHeight)
    }

    /// The top band's height: the title band's in a window, the plain band's in full screen, where the system shows the
    /// traffic lights elsewhere.
    var topBandHeight: CGFloat { isInFullScreen ? ViewerWindow.bandHeight : ViewerWindow.titleBandHeight }

    /// Bands that always show have room of their own. Bands that show on pointing take theirs only while they show, so
    /// that the window is the paper alone while they are hidden.
    private static func bandRoom(
        of arrangement: MenuArrangement, _ visibility: BandVisibility, revealed: BandRoom, top: CGFloat
    ) -> BandRoom {
        visibility == .always ? BandRoom.full(for: arrangement, top: top) : revealed
    }

    /// Bands that show on pointing came out or went away. Coming out, they take their room where the window can grow
    /// around the paper without moving it; where it cannot (at the top of the screen, in full screen, while the reader
    /// resizes), they lie over the paper's edges instead.
    func bandRevealDidChange(_ shown: Bool) {
        guard bandVisibility == .onHover, let window else { return }
        areHoverBandsShown = shown
        if shown {
            pendsBandRoomRelease = false
            // A band shown for a drag lies over the paper: growing the window under the pointer would move the place
            // the files are dropped on, and the window would shrink again once the drag is over.
            guard revealedBandRoom == BandRoom(), mode == .view, hasSizedWindow, !drop.isActive else { return }
            let room = roomToGrow(window, wanted: BandRoom.full(for: menuArrangement), around: BandRoom())
            guard room != BandRoom() else { return }
            revealedBandRoom = room
            bandRoomDidChange(from: BandRoom(), animate: false)
        } else {
            guard revealedBandRoom != BandRoom() else { return }
            guard !window.inLiveResize else {
                pendsBandRoomRelease = true
                return
            }
            let previous = currentBandRoom
            revealedBandRoom = BandRoom()
            bandRoomDidChange(from: previous, animate: false)
        }
    }

    /// Each band grows the window on its own edge where the screen has room beside the paper; the other lies over the
    /// paper. `existing` is the room the window already has, which is measured from the paper rather than the frame.
    private func roomToGrow(_ window: NSWindow, wanted: BandRoom, around existing: BandRoom) -> BandRoom {
        guard !isInFullScreen, !window.styleMask.contains(.fullScreen), !window.inLiveResize,
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return BandRoom() }
        let paperTop = window.frame.maxY - existing.top
        let paperBottom = window.frame.minY + existing.bottom
        return BandRoom(
            top: paperTop + wanted.top <= visible.maxY + 0.5 ? wanted.top : 0,
            bottom: paperBottom - wanted.bottom >= visible.minY - 0.5 ? wanted.bottom : 0)
    }

    func windowWillEnterFullScreen() {
        guard !isInFullScreen, let window else { return }
        paperSizeBeforeFullScreen = currentPaperSize
        // A stage keeps its own frame, which the way back to reading reads as holding the stage's remembered room.
        fullScreenReturnRoom = mode == .view ? currentBandRoom : stageBandRoom ?? currentBandRoom
        isInFullScreen = true
        // In full screen the bands lie over the paper; the room they had stays in the frame the system gives back.
        revealedBandRoom = BandRoom()
        pendsBandRoomRelease = false
        // There is no notification for a failed attempt; a window still not in full screen a while later stayed out.
        // The check belongs to this attempt only: leaving and entering again starts another.
        fullScreenAttempt += 1
        let attempt = fullScreenAttempt
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let window, attempt == fullScreenAttempt, isInFullScreen,
                !window.styleMask.contains(.fullScreen)
            else { return }
            windowDidExitFullScreen()
        }
    }

    /// The frame is the one from before full screen again: it takes the bands' room as they are now and the pages'
    /// shape, which may have changed meanwhile.
    func windowDidExitFullScreen() {
        applyWindowSpacesAfterUpdate()
        guard isInFullScreen else { return }
        fullScreenAttempt += 1
        isInFullScreen = false
        let room = fullScreenReturnRoom ?? currentBandRoom
        fullScreenReturnRoom = nil
        paperSizeBeforeFullScreen = nil
        guard mode == .view else {
            // Back on a stage, the frame read on the way back to reading is this one.
            stageBandRoom = room
            return
        }
        stageBandRoom = nil
        if room != currentBandRoom { bandRoomDidChange(from: room, animate: false) }
        if returnsToRestoredPaperSize {
            returnsToRestoredPaperSize = false
            applyRestoredPaperSize()
        } else {
            sizeWindowToPaper(keepHeight: true)
        }
    }

    /// The paper the window shows in the view mode. Before the first pages fit the window to the paper, its size is
    /// only where it opened, and remembering that would open the document that small next time.
    var currentPaperSize: CGSize? {
        if isInFullScreen { return paperSizeBeforeFullScreen }
        guard mode == .view, hasSizedWindow, let window else { return nil }
        let content = window.contentRect(forFrameRect: window.frame).size
        return CGSize(width: (content.width - sideInset).rounded(), height: (content.height - bandInset).rounded())
    }

    /// Fits the window to the paper: the first time at a comfortable or remembered size, later keeping the height.
    /// `animate` defaults to animating the changes that keep the height.
    func sizeWindowToPaper(
        keepHeight: Bool = false, initialOnly: Bool = false, keepsRightEdge: Bool = false, animate: Bool? = nil
    ) {
        guard !initialOnly || !hasSizedWindow, !isInFullScreen else { return }
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
            paperSize(unit: unit, height: height, in: window), band: bandInset, of: window,
            animate: animate ?? keepHeight, keepsRightEdge: keepsRightEdge, side: sideInset)
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
        guard !isInFullScreen else {
            returnsToRestoredPaperSize = true
            return
        }
        guard let window, let unit = paperUnitSize, let size = restoredPaperSize else { return }
        // Keep the remembered height; the width follows the pages as they are now.
        ViewerWindow.setPaperSize(
            paperSize(unit: unit, height: size.height, in: window), band: bandInset, of: window, animate: false,
            side: sideInset)
    }

    func menuArrangementDidChange(from previous: MenuArrangement) {
        let before = Self.bandRoom(of: previous, bandVisibility, revealed: revealedBandRoom, top: topBandHeight)
        // Shown bands of the new arrangement take room where the screen has it beside the paper, as they do on showing,
        // also when the old ones had none.
        if bandVisibility == .onHover, areHoverBandsShown, mode == .view, let window {
            revealedBandRoom = roomToGrow(window, wanted: BandRoom.full(for: menuArrangement), around: before)
        }
        bandRoomDidChange(from: before, animate: true)
    }

    /// The paper keeps its size and place when the bands' room changes: the window grows or shrinks around it.
    private func bandRoomDidChange(from previous: BandRoom, animate: Bool) {
        guard mode == .view, hasSizedWindow, !isInFullScreen, let window else { return }
        let room = currentBandRoom
        let content = window.contentRect(forFrameRect: window.frame).size
        let paper = CGSize(width: content.width - sideInset, height: content.height - previous.total)
        ViewerWindow.setPaperSize(
            paper, band: room.total, of: window, animate: animate, side: sideInset,
            topGrowth: room.top - previous.top)
        // Only the resizing rule follows the new room: the live page keeps the size the reader gave it, even past the
        // share of the screen that a newly shaped window takes.
        guard isWebPresentation else { return }
        if let deck = slideDeck {
            ViewerWindow.lockAspectRatio(of: window, unit: deck.size, band: bandInset)
        } else {
            ViewerWindow.unlockAspectRatio(of: window)
        }
    }

    /// The bands' narrowest width (`BandPlans.minimumWidth`). A window narrower than it grows to it after SwiftUI's
    /// update, as one of the app's own resizes, so nothing is saved for it; on a stage and in full screen it waits
    /// until reading resumes, when the view mode reports the width again.
    func bandMinimumWidthDidChange(_ width: CGFloat, in window: NSWindow? = nil) {
        guard let window = window ?? self.window else { return }
        ViewerWindow.setBandMinimumWidth(width, of: window)
        Task { @MainActor [weak self] in self?.fitWindowToBands() }
    }

    private func fitWindowToBands(attempt: Int = 0) {
        guard mode == .view, hasSizedWindow, !isInFullScreen, let window, !window.styleMask.contains(.fullScreen),
            !window.inLiveResize
        else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        guard content.width + 0.5 < ViewerWindow.bandMinimumWidth(of: window) else { return }
        // A stage's frame on its way back to reading would overwrite this one.
        guard !ViewerWindow.isResizingProgrammatically(window) else {
            guard attempt < 5 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.fitWindowToBands(attempt: attempt + 1)
            }
            return
        }
        ViewerWindow.setPaperSize(
            CGSize(width: content.width - sideInset, height: content.height - bandInset), band: bandInset,
            of: window, animate: false, side: sideInset)
        // A live page keeps its free shape; only a slide deck keeps the slide's.
        guard isWebPresentation else { return }
        if let deck = slideDeck {
            ViewerWindow.lockAspectRatio(of: window, unit: deck.size, band: bandInset)
        } else {
            ViewerWindow.unlockAspectRatio(of: window)
        }
    }

    func windowDidEndLiveResize() {
        defer {
            if pendsBandRoomRelease {
                pendsBandRoomRelease = false
                bandRevealDidChange(false)
            }
        }
        // The window size remembered is the paper's; the web page takes whatever size the reader likes.
        guard mode == .view, !isWebPresentation, !isInFullScreen, let window,
            !ViewerWindow.isResizingProgrammatically(window),
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

    func withFolderAccess(_ source: DocumentSource) -> DocumentSource {
        var source = source
        source.allowedResourceFolders = folderLease.map { [$0.url] } ?? []
        return source
    }

    func useDocumentFolder(_ lease: FolderAccess.Lease) {
        folderLease?.close()
        folderLease = lease
        web.allowedResourceFolders = [lease.url]
        guard themeFormat == .latex else { return }
        // A newly readable preamble can set the document class. Change only an untouched default and
        // its baseline, so granting permission alone creates no settings record.
        let followsClass = !hasSavedSettings && !didCustomizeSinceLoad && themeID == classStyle
        let followedTrim = layoutID == (classLayout?.id ?? Self.defaultLayoutID(preferences))
        classStyle = UserLibrary.classStyle(for: themedSource, renderer: renderer)
        classLayout = UserLibrary.classLayout(for: themedSource, renderer: renderer)
        if followedTrim && !hasSavedSettings && !didCustomizeSinceLoad {
            layoutID = classLayout?.id ?? Self.defaultLayoutID(preferences)
            settingsBaseline?.layoutID = layoutID
        }
        if followsClass {
            themeID = defaultThemeID
            settingsBaseline?.themeID = themeID
        } else if theme(themeID) == nil {
            themeID = defaultThemeID
        }
    }

    func requestFolderAccess() {
        guard SandboxEnvironment.isSandboxed, fileURL != nil || binder != nil, !closedFolderAccessNotice,
            folderAccessNotice == nil
        else { return }
        showToast(.folderAccess)
    }

    var fileNeedingFolderAccess: URL? { fileURL ?? binder?.fileRequiringAccess(result?.requiredFolderAccess) }

    func allowFolderAccess() {
        guard SandboxEnvironment.isSandboxed, let fileURL = fileNeedingFolderAccess, let window else { return }
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
                folderAccessNotice = nil
                closedFolderAccessNotice = false
                dismissToast()
                if let binder {
                    lease.close()
                    binder.clearCache()
                    renderer.clearCache()
                    render()
                    return
                }
                useDocumentFolder(lease)
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

    private func showVerticalWritingNoteIfNeeded() {
        // The live page still shows the document's own vertical text; the note is about paper.
        guard !hasShownVerticalWritingNote, toast == nil, !showsWeb,
            let issue = result?.issues.first(where: { $0.kind == .verticalWriting })
        else { return }
        hasShownVerticalWritingNote = true
        showToast(
            Toast(
                systemImage: "text.alignleft", title: PrintIssueText.title(issue, language: language),
                showsDismissButton: false))
    }

    func showToast(_ toast: Toast, dismissAfter delay: Duration? = .seconds(5)) {
        toastTask?.cancel()
        if toast.action == .allowFolderAccess {
            otherToast = nil
            folderAccessNotice = toast
            return
        }
        // A short-lived message may cover the folder action, but must leave it available afterwards.
        otherToast = toast
        guard let delay else { return }
        let id = toast.id
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            if self?.toast?.id == id { self?.dismissToast() }
        }
    }

    func dismissToast(closingFolderNotice: Bool = false) {
        toastTask?.cancel()
        if closingFolderNotice, otherToast == nil, folderAccessNotice != nil {
            folderAccessNotice = nil
            closedFolderAccessNotice = true
        }
        otherToast = nil
        showVerticalWritingNoteIfNeeded()
    }

    // MARK: - Output

    enum Output: Equatable {
        case print(quick: Bool)
        case manualDuplex
        case exportPDF
        case exportReadingPDF
        case additional(ReadingExportKind)

        var readsPages: Bool {
            switch self {
            case .exportReadingPDF, .additional: true
            default: false
            }
        }
    }

    /// Sheet outputs use the tray's settings even when requested from the reader.
    private func deferUntilPrintMode(_ output: Output) -> Bool {
        guard mode != .print else { return false }
        outputAfterReview = output
        enterPrintMode()
        guard mode == .print, canOutput else { return true }
        // The chosen layout may already be composed, so no settings change will trigger another render.
        outputAfterReview = nil
        return false
    }

    /// An output asked for during the review ends it and waits for the pages without the outlines.
    func deferUntilReviewEnds(_ output: Output) -> Bool {
        guard isReviewingSmartRemoval else { return false }
        isReviewingSmartRemoval = false
        waitingOutput = (output, true)
        renderForChangedSettings()
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
        canStartPrint && printerLayout.sentDuplex != .none
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
                    back: PrintModeText.string("Back Side", language: language),
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
                    guard let self else { return }
                    isPrinting = false
                    if !isWindowClosed { duplexTestResult = result }
                }
                if let duplexTestSubmit {
                    duplexTestSubmit(document, testLayout, request, complete)
                } else {
                    submitDuplexTest(document, layout: testLayout, request: request, complete: complete)
                }
            } catch {
                isPrinting = false
                if !isWindowClosed, !(error is CancellationError) {
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
        PrintCompletion.run(operation, document: document, in: window) { [weak self] success in
            guard let self else { return }
            guard !isWindowClosed, success, info.jobDisposition == .spool else {
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
    }

    /// Prints the sheets: right away to the selected printer when `quick`, otherwise through the system dialog,
    /// which starts on that printer.
    func printDocument(quick: Bool = false) {
        printDocument(intent: quick ? .quick : .systemDialog)
    }

    var canStartPrint: Bool {
        canOutput && pendingPrint == nil && manualDuplexSession == nil && duplexTestResult == nil
    }

    // A command from the reading window may enter the tray or request a fresh capture before output is ready.
    var canRequestSheetOutput: Bool {
        !isPrinting && !isExporting
            && (mode != .print || canOutput || showsWeb || isCapturingWeb
                || webCaptureFailed || isReviewingSmartRemoval || showsStaleDate)
    }

    var canRequestPrint: Bool {
        pendingPrint == nil && manualDuplexSession == nil && duplexTestResult == nil && canRequestSheetOutput
    }

    func printDocument(intent: PrintIntent) {
        guard canRequestPrint else { return }
        let output: Output = intent == .manualDuplex ? .manualDuplex : .print(quick: intent == .quick)
        guard !deferUntilPrintMode(output), !deferUntilWebIsCaptured(output), !deferUntilReviewEnds(output),
            !deferUntilDateIsCurrent(output)
        else { return }
        guard canOutput else { return }
        let knownIssue = issue(sending: printerLayout, to: selectedPrinterName)
        let intent = knownIssue != nil && knownIssue != .duplexNotAvailable ? PrintIntent.systemDialog : intent
        pendingPrint = PendingPrint(
            request: PrintRequest(printerName: selectedPrinterName, showsPanel: intent == .systemDialog), intent: intent
        )
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
        let destination = printers.request(
            quick: !pending.request.showsPanel, shown: pending.request.printerName, remembered: preferences.printerName)
        let route = PrintRoute.resolve(
            intent: pending.intent, request: destination, layout: printerLayout,
            issue: issue(sending: printerLayout, to: destination.printerName))
        pending.request = route.request
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
        sendPrint(
            result, route: route, request: request, prepared: self.result, pageOrder: pageOrder,
            intent: pending.intent)
    }

    /// The last step of a print. The manual route never falls through to an ordinary submission: that would send the
    /// job to a printer without duplex as automatic duplex, so without the preparation its passes come from, nothing
    /// is sent.
    func sendPrint(
        _ result: RenderResult, route: PrintRoute, request: PrintRequest, prepared: PreparedRender?,
        pageOrder: PrintPageOrder, intent: PrintIntent
    ) {
        if case .manualDuplex = route {
            guard let prepared else {
                outputError = String(localized: "The print job could not be created.")
                return
            }
            startManualDuplex(prepared: prepared, request: request, pageOrder: pageOrder)
            return
        }
        submitDocument(result, request: request, pageOrder: pageOrder, output: .print(quick: intent == .quick))
    }

    func submitDocument(
        _ result: RenderResult, request: PrintRequest, pageOrder: PrintPageOrder, output: Output? = nil,
        jobTitle: String? = nil
    ) {
        if let printSubmit { return printSubmit(result, request, pageOrder) }
        if let outputOverride { return outputOverride(output ?? .print(quick: !request.showsPanel), result) }
        guard let window else { return }
        outputError = nil
        let destination = request.printerName.flatMap(NSPrinter.init(name:))
        // Without a printer the system dialog still offers saving a PDF or adding a printer.
        let quick = !request.showsPanel && destination != nil
        guard
            let operation = makePrintOperation(for: result, request: request, pageOrder: pageOrder, jobTitle: jobTitle)
        else {
            outputError = String(localized: "The print job could not be created.")
            return
        }
        // The sheets are already the pages asked for, so a page range left over from another job must not cut them.
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
        PrintCompletion.run(
            operation, document: result.sheetDocument, in: window,
            completion: beginSheetPrint(quickPrinter: quick ? operation.printInfo.printer.name : nil))
    }

    func beginSheetPrint(quickPrinter: String?) -> (Bool) -> Void {
        isPrinting = true
        return { [weak self] success in
            guard let self else { return }
            isPrinting = false
            guard !isWindowClosed, let quickPrinter else { return }
            showToast(
                Toast(
                    systemImage: success ? "printer" : "exclamationmark.triangle",
                    title: success
                        ? String(format: String(localized: "Sent to %@"), quickPrinter)
                        : String(localized: "The print job was cancelled or could not be sent.")))
        }
    }

    /// Made apart from running it, so that what would be sent can be read without a printer.
    func makePrintOperation(
        for result: RenderResult, request: PrintRequest, pageOrder: PrintPageOrder, jobTitle: String? = nil
    )
        -> NSPrintOperation?
    {
        let destination = request.printerName.flatMap(NSPrinter.init(name:))
        return PrintJobFactory().printOperation(
            for: result.sheetDocument, layout: result.layout, showsPrintPanel: request.showsPanel || destination == nil,
            printer: destination, pageOrder: pageOrder, copies: request.copies, jobTitle: jobTitle ?? printJobTitle)
    }

    var additionalExportTask: Task<Void, Never>?
    @ObservationIgnored var exportPanel: NSSavePanel?
    @ObservationIgnored var sourceSharePicker: NSSharingServicePicker?
    @ObservationIgnored var readingShare: ReadingPDFShare?
    private var readingExportTask: Task<Void, Never>?
    @ObservationIgnored private var exportingSourceURLs: [URL] = []

    var canExportReadingPDF: Bool {
        isUpToDate && !isPrinting && !isExporting && !isCapturingWeb && !webCaptureFailed
            && !isBecomingBinder && !isReviewingSmartRemoval
            && renderedSettings?.smartRemoval?.highlightsCandidates != true
    }

    var readingExportName: String {
        let name =
            binder?.title(language: language) ?? imageBundle?.title(language: language)
            ?? title ?? fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Document")
        return name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-") + ".pdf"
    }

    var canRequestReadingOutput: Bool {
        !isExporting && !isPrinting
            && (error == nil || showsWeb || isCapturingWeb || webCaptureFailed || isReviewingSmartRemoval)
    }

    var canRequestReadingPDF: Bool { readingExportTask == nil && canRequestReadingOutput }

    func exportReadingPDF() {
        guard canRequestReadingPDF,
            !deferUntilWebIsCaptured(.exportReadingPDF), !deferUntilReviewEnds(.exportReadingPDF)
        else { return }
        // A render already in flight owns the request until its current pages are ready.
        guard isUpToDate else {
            guard error == nil else { return }
            outputAfterReview = .exportReadingPDF
            if !isRendering { render() }
            return
        }
        readingExportTask = Task { [weak self] in
            guard let self else { return }
            defer { readingExportTask = nil }
            guard await beginReadingPDFExport() else { return }
            guard let window else {
                completePDFExport(to: nil)
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = readingExportName
            panel.beginSheetModal(for: window) { [weak self] response in
                self?.completePDFExport(to: response == .OK ? panel.url : nil)
            }
        }
    }

    func beginDiagramExport() -> Bool {
        guard additionalExportTask == nil, !isExporting, !isPrinting else { return false }
        isExporting = true
        outputError = nil
        return true
    }

    func beginThemedExport() async -> String? {
        let structure = structureDocument
        await structureTask?.value
        guard !Task.isCancelled, structureDocument === structure, canExportReadingPDF,
            format.usesPrintTheme, binder == nil, imageBundle == nil, let result
        else { return nil }
        isExporting = true
        outputError = nil
        return [result.facts?.title, result.facts?.headings.first?.text, outlineEntries.first?.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? String(readingExportName.dropLast(4))
    }

    func endReadingExport() {
        pendingPDF = nil
        exportingSourceURLs = []
        isExporting = false
    }

    func beginReadingPDFExport() async -> Bool {
        await beginReadingPDFExport { current, settings in
            try await readingPDFProducer(from: current, settings: settings)()
        }
    }

    func beginReadingPDFExport(
        _ prepare: @MainActor (PreparedRender, RenderSettings) async throws -> Data
    ) async -> Bool {
        let generation = reloadGeneration
        let structure = structureDocument
        await structureTask?.value
        guard !Task.isCancelled, generation == reloadGeneration, structureDocument === structure,
            canExportReadingPDF, let current = result, let settings = renderSettings(in: .view)
        else { return false }
        let sources = protectedSourceURLs
        let originalData = data
        let originalURLs = sourceURLs
        let originalSettings = renderSettings
        func stillCurrent() -> Bool {
            !Task.isCancelled && generation == reloadGeneration && isUpToDate && result?.id == current.id
                && data == originalData && sourceURLs == originalURLs && renderSettings == originalSettings
        }
        isExporting = true
        outputError = nil
        do {
            let bytes = try await prepare(current, settings)
            guard stillCurrent() else { throw CancellationError() }
            // The panel, share picker and PNG renderer must consume the very bytes that passed readback.
            pendingPDF = .reading(bytes)
            exportingSourceURLs = sources
            return true
        } catch {
            isExporting = false
            if error is CancellationError || !stillCurrent() { return false }
            outputError = String(localized: "The PDF could not be exported.") + "\n" + error.localizedDescription
            return false
        }
    }

    /// A share can be consumed after the picker has closed. Keep the render inputs, never the window or model,
    /// in the work that runs across suspension points; recheck the selected revision before returning its bytes.
    func makeReadingShare(
        prepare: @escaping @MainActor (_ produce: @MainActor () async throws -> Data) async throws -> Data = {
            try await $0()
        }
    ) -> ReadingPDFShare? {
        guard canExportReadingPDF, let current = result, let settings = renderSettings(in: .view) else {
            return nil
        }
        let generation = reloadGeneration
        let originalSettings = renderSettings
        let originalData = data
        let originalURLs = protectedSourceURLs
        let isCurrent = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && reloadGeneration == generation && result?.id == current.id
                && isUpToDate
                && renderSettings == originalSettings && data == originalData
                && protectedSourceURLs == originalURLs
        }
        return ReadingPDFShare(name: readingExportName, protectedURLs: originalURLs) {
            [weak self, structureTask] in
            await structureTask?.value
            guard isCurrent(), let produce = self?.readingPDFProducer(from: current, settings: settings)
            else {
                throw CancellationError()
            }
            let bytes = try await prepare(produce)
            guard isCurrent() else { throw CancellationError() }
            return bytes
        }
    }

    private func readingPDFProducer(from current: PreparedRender, settings: RenderSettings)
        -> @MainActor () async throws -> Data
    {
        let singleSource = withFolderAccess(
            usesHTMLPresentation && liveSnapshot != nil
                ? DocumentSource.liveSnapshot(liveSnapshot?.html ?? "", of: fileURL)
                : DocumentSource(data: data, fileURL: fileURL, format: format, htmlBaseURL: htmlBaseURL)
                    .named(sourceFileName))
        var readingSettings = settings
        if format == .latex, binder == nil, imageBundle == nil {
            readingSettings = settings.forReadingLaTeX(
                renderer.latexClassInfo(for: singleSource, composition: settings.latexComposition))
        }
        let usesCurrent = mode == .view && readingSettings == settings
        let initialHeadings = readStructure?.headings ?? current.facts?.headings ?? []
        let initialTitle = format == .html ? readStructure?.title : nil
        let includesSourceContents = !finishAppliesToText || settings.finish.toc.showsSourceContents
        let fallbackTitle = String(readingExportName.dropLast(4))
        return { [outlineEntries, format, fileURL, binder, imageBundle, themeFormat, readingSettings] in
            try Task.checkCancellation()
            let prepared: PreparedRender
            var entries = outlineEntries
            var headings = initialHeadings
            var htmlTitle = initialTitle
            if usesCurrent {
                prepared = current
            } else {
                // Tray notes, ranges and slide selections must never enter a reading copy.
                let source: DocumentSource
                if let binder {
                    source = try await binder.source()
                } else if let imageBundle {
                    source = try await imageBundle.source()
                } else {
                    source = singleSource
                }
                prepared = try await DocumentRenderer().prepare(source, settings: readingSettings)
                if binder == nil, imageBundle == nil, source.format.isWebRendered {
                    let structure = await ReadingPDFExporter.outline(
                        of: source, in: prepared.logicalDocument, proof: settings.finish.proof,
                        includesSourceContents: includesSourceContents, facts: prepared.facts,
                        orgReading: settings.orgReading)
                    entries = structure.entries
                    headings = structure.headings
                    htmlTitle = structure.title
                }
            }
            try Task.checkCancellation()
            let document = prepared.viewDocument
            let candidates = [
                prepared.facts?.title, htmlTitle,
                format == .pdf
                    ? document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String : nil,
                prepared.facts?.headings.first?.text, entries.first?.title,
            ]
            let metadataTitle =
                candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? fallbackTitle
            return try await ReadingPDFExporter.data(
                from: document, entries: entries, title: metadataTitle, preservesOutline: format == .pdf,
                headings: headings, sourceURL: fileURL,
                furniture: themeFormat == .latex ? prepared.viewFurniture : [:])
        }
    }

    func exportPDF() {
        guard canRequestSheetOutput, !deferUntilPrintMode(.exportPDF),
            !deferUntilWebIsCaptured(.exportPDF), !deferUntilReviewEnds(.exportPDF),
            !deferUntilDateIsCurrent(.exportPDF)
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
        pendingPDF = .sheets(result.sheetDocument)
        exportingSourceURLs = protectedSourceURLs
        isExporting = true
        outputError = nil
        return true
    }

    func completePDFExport(to url: URL?) {
        guard isExporting, let pendingPDF else { return }
        defer {
            self.pendingPDF = nil
            exportingSourceURLs = []
            isExporting = false
        }
        guard let url else { return }
        do {
            let sources = protectedSourceURLs + exportingSourceURLs
            guard Self.canExport(to: url, sourceURLs: sources) else { throw CocoaError(.fileWriteNoPermission) }
            let data = try pendingPDF.bytes()
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

    static func message(for error: Error) -> String {
        guard let error = error as? DocumentRenderer.RenderingError else { return error.localizedDescription }
        switch error {
        case .noReadableDocuments: return String(localized: "None of the documents could be opened.")
        case .noReadableImages: return String(localized: "None of the images could be opened.")
        case .imageChanged: return String(localized: "The images keep changing. Try reloading the document.")
        case .tooLarge(let bytes):
            return String.localizedStringWithFormat(
                String(localized: "This file is too large to lay out as pages (%lld MB)."),
                Int64(ceil(Double(bytes) / 1_000_000)))
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
    // Closing or re-rendering the window can drop its render result while the print panel is open.
    private let document: PDFDocument
    private let operation: NSPrintOperation
    private let completion: (Bool) -> Void
    private var lifetime: PrintCompletion?

    private init(_ operation: NSPrintOperation, document: PDFDocument, completion: @escaping (Bool) -> Void) {
        self.document = document
        self.operation = operation
        self.completion = completion
    }

    static func run(
        _ operation: NSPrintOperation, document: PDFDocument, in window: NSWindow, completion: @escaping (Bool) -> Void
    ) {
        // The window and its model can disappear while the print system still needs the job and delegate.
        let delegate = PrintCompletion(operation, document: document, completion: completion)
        delegate.lifetime = delegate
        operation.runModal(
            for: window, delegate: delegate, didRun: #selector(didRun(_:success:context:)), contextInfo: nil)
    }

    @objc func didRun(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        defer { lifetime = nil }
        completion(success)
    }
}
