import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI

/// Lets menus and the overlay drive the paper view of one window.
final class PaperController {
    fileprivate(set) weak var view: PaperPDFView?
    fileprivate private(set) var isClosed = false

    func disconnect() {
        isClosed = true
        pendingChange = nil
        view?.retire()
        view = nil
    }
    var onReadingJump: ((Int) -> Void)?
    var onToast: ((Toast) -> Void)?

    func zoomIn() { view?.stepZoom(up: true) }
    func zoomOut() { view?.stepZoom(up: false) }
    func zoomToFit() { view?.setZoom(1, anchor: nil) }
    func turnPage(forward: Bool) { view?.turnPage(forward: forward) }
    /// Whether a paper view is on screen to receive turns (observed by tests).
    var isConnected: Bool { view != nil }
    func goToPage(index: Int, in document: PDFDocument? = nil) { view?.goToPage(index: index, in: document) }
    private var pendingChange: (source: PDFDocument, pageIndex: Int, pinnedBandHeight: CGFloat)?

    func followChange(on pageIndex: Int, in source: PDFDocument, pinnedBandHeight: CGFloat) {
        // A save announces its changes before SwiftUI installs the new PDF. Never scroll the outgoing pages.
        pendingChange = (source, pageIndex, pinnedBandHeight)
        revealPendingChange()
    }

    fileprivate func revealPendingChange() {
        guard let request = pendingChange, let view, view.isMade(of: request.source),
            view.bounds.width > 1, view.bounds.height > 1, view.documentView?.enclosingScrollView != nil
        else { return }
        // Going to the page can lay the paper out again before the scroll completes.
        pendingChange = nil
        view.revealChange(on: request.pageIndex, pinnedBandHeight: request.pinnedBandHeight)
    }

    func canMarkProse(_ spans: [ProsePaperSpan], in source: PDFDocument) -> Bool {
        guard let view, view.isMade(of: source) else { return false }
        return view.proseSelections(spans) != nil
    }

    func revealProse(_ spans: [ProsePaperSpan]) { view?.revealProse(spans) }

    func isProsePageVisible(_ page: Int) -> Bool { view?.isLogicalPageVisible(page) == true }

    #if DEBUG
        var showsProseMark: Bool { view?.drawnProseSpans.isEmpty == false }

        func showSnapshotPage(_ index: Int, in source: PDFDocument) -> Bool {
            guard let view, view.isMade(of: source) else { return false }
            return view.showSnapshotPage(index)
        }
    #endif

    func focus() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }
    /// Marks which of the search's hits is the current one and, with `reveals`, turns and scrolls the paper to it.
    func markFindHit(_ index: Int?, reveals: Bool) { view?.markFindHit(index, reveals: reveals) }
}

/// The logical pages of the view mode: no margins, no page shadows, laid out by `ViewOptions`.
struct PaperView: NSViewRepresentable {
    let document: PDFDocument
    /// The reading position, which the model keeps in step with the page shown (`onPageChange`). A new paper view
    /// opens there, as on returning from the print mode, and so does a new document, such as a theme being tried;
    /// a document too short for it shows its last page, and the reading position stays for the next one.
    let initialPageIndex: Int
    let options: ViewOptions
    let zoom: Double
    var wheelSensitivity: WheelPageTurner.Sensitivity = .normal
    var selectsText = false
    var logicalMargin: CGFloat? = nil
    var showsPageNumbers = false
    var changeMarks: [ChangeMark] = []
    var displayOptions = DisplayAccessibility.shared.options
    var formulaIndex: PaperFormulaIndex?
    var diagrams: [RenderedDiagram] = []
    var onDiagram: (RenderedDiagram, PaperDiagramAction) -> Void = { _, _ in }
    /// The header and footer the sheets draw on a logical page, by its index.
    var furniture: [Int: FurniturePlacement] = [:]
    /// A spread that shows its cover alone shows it one page wide (`LoneCoverWidth.onePage`).
    var narrowsLoneCover = false
    var keepsSpotInPage = false
    /// The words to mark on the paper; nothing takes the marks away.
    var proseSpans: [ProsePaperSpan] = []
    var onPaperPress: () -> Void = {}
    var findQuery = ""
    /// The logical page of every hit, with the words they were found for.
    var onFindHits: ([Int], String) -> Void = { _, _ in }
    let controller: PaperController
    var onZoomChange: (Double) -> Void
    var onPageChange: (Int) -> Void
    var onTurn: () -> Void
    /// Returns true when the overlay handled a fixed key (Tab or Esc).
    var onKey: (NSEvent) -> Bool
    var onShortcut: (ShortcutOperationID) -> Void = { _ in }
    var allowsShortcutHandling: () -> Bool = { true }

    func makeNSView(context: Context) -> PaperPDFView {
        let view = PaperPDFView()
        guard !controller.isClosed else {
            view.retire()
            return view
        }
        controller.view = view
        view.onToast = controller.onToast
        view.onReadingJump = controller.onReadingJump
        return view
    }

    static func dismantleNSView(_ view: PaperPDFView, coordinator: ()) { view.retire() }

    func updateNSView(_ view: PaperPDFView, context: Context) {
        guard !controller.isClosed, !view.isRetired else { return }
        controller.view = view
        view.changeController = nil
        defer {
            // Fit and restored zoom must be applied before measuring a newly attached page.
            view.changeController = controller
            controller.revealPendingChange()
        }
        view.onToast = controller.onToast
        view.onReadingJump = controller.onReadingJump
        view.displayOptions = displayOptions
        let spotRadius = AppPreferences.shared.corners.radius(for: .badge, shortestSide: .infinity)
        view.subviews.first { $0 is PaperSpotFrameView }?.layer?.cornerRadius = spotRadius
        view.onZoomChange = onZoomChange
        view.onPageChange = onPageChange
        view.onTurn = onTurn
        view.onKey = onKey
        view.onShortcut = onShortcut
        view.allowsShortcutHandling = allowsShortcutHandling
        view.formulaIndex = formulaIndex
        view.diagrams = diagrams
        view.onDiagram = onDiagram
        view.narrowsLoneCover = narrowsLoneCover
        view.configure(
            document, at: initialPageIndex, options: options, logicalMargin: logicalMargin,
            showsPageNumbers: showsPageNumbers, changeMarks: changeMarks, furniture: furniture,
            keepsSpotInPage: keepsSpotInPage)
        view.wheelSensitivity = wheelSensitivity
        view.selectsText = selectsText
        view.onFindHits = onFindHits
        view.find(findQuery)
        view.onPaperPress = onPaperPress
        view.drawProse(proseSpans)
        if abs(view.zoom - zoom) > 0.001 {
            // A zoom that comes from the model, as when a document's settings are brought back, has no pointer; it
            // opens at the top of the page rather than in its middle.
            view.setZoom(zoom, anchor: NSPoint(x: view.bounds.midX, y: view.bounds.maxY))
        }
    }
}

/// A scroller for a scroll view that must not show one, even when something else turns its scrollers on.
final class InvisibleScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: ControlSize, scrollerStyle: Style) -> CGFloat { 0 }

    // Overlay scrollers fade the knob and the slot apart, so these are what they draw through, not draw(_:).
    override func drawKnob() {}

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

final class PaperPDFView: PageTextPDFView, ShortcutSurface {
    static let zoomSteps: [Double] = [1, 1.25, 1.5, 2, 3, 4, 6]
    /// Slows page-turn animations down; development screenshots use it to capture a turn halfway.
    static var animationScale: Double = 1
    #if DEBUG
        /// Holds a page turn still at this share of its length; development screenshots use it to look at a turn
        /// frame by frame.
        static var frozenTurnProgress: Double?
    #endif
    static var maximumZoom: Double { zoomSteps[zoomSteps.count - 1] }

    var onZoomChange: ((Double) -> Void)?
    var onPageChange: ((Int) -> Void)?
    var onTurn: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onShortcut: ((ShortcutOperationID) -> Void)?
    var allowsShortcutHandling: () -> Bool = { true }
    var shortcutController: ShortcutController = .shared
    var dispatchKey: (NSEvent) -> Bool = { ShortcutDispatcher.shared.handle($0) }
    var nativeKeyHandler: ((NSEvent) -> Void)?
    var fullKeyboardAccess: () -> Bool = { NSApp.isFullKeyboardAccessEnabled }
    var onReadingJump: ((Int) -> Void)?
    var onToast: ((Toast) -> Void)?
    // PDFView inherits delegate-shaped methods that forward to its delegate, so delegating to self recurses on zoom.
    private let linkDelegate = LinkDelegate()
    /// Opens the URLs of links; tests replace it so that no browser opens.
    var linkHandler = PaperLinkHandler()

    private final class LinkDelegate: NSObject, PDFViewDelegate {
        weak var view: PaperPDFView?

        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            // Only URL actions come here; PDFKit still handles destinations inside this document.
            Task { @MainActor [weak view] in
                guard let handler = view?.linkHandler else { return }
                await handler.open(url) { [weak view] toast in view?.onToast?(toast) }
            }
        }
    }
    private(set) var zoom: Double = 1
    private(set) var displayedZoom: Double = 1
    var shouldReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var isReturningToFit: Bool { zoomReturn != nil }
    private var pinchDetector = PinchFlickDetector()
    private var fingerZoom: Double = 1
    private var pinchActive = false
    private var ignoresPinchRemainder = false
    private var zoomDisplayLink: CADisplayLink?
    private var zoomReturn: ZoomReturn?
    private var isMeasuringFit = false

    private struct ZoomReturn {
        let path: PinchZoom.Return
        let startedAt: Double
        let page: PDFPage
        let pagePoint: NSPoint
        let start: NSPoint
        let end: NSPoint
    }

    // CADisplayLink retains its target; a weak relay lets a closed paper view release its link.
    private final class ZoomDisplayLinkTarget: NSObject {
        weak var view: PaperPDFView?

        init(view: PaperPDFView) { self.view = view }

        @objc func tick(_ link: CADisplayLink) {
            guard let view, let animation = view.zoomReturn else { return }
            view.advanceZoomReturn(elapsed: link.targetTimestamp - animation.startedAt)
        }
    }
    private var options: ViewOptions?
    private var sourceDocument: PDFDocument?
    private var pagePlan: ViewPageLayout?
    private var documentKey: ViewPageLayout.DocumentKey?
    /// Every document this view has shown, kept alive for as long as the view lives. PDFKit's accessibility nodes keep
    /// unretained references to the pages they describe, and freeing those pages crashed inside PDFKit even when only
    /// the oldest of sixteen was dropped, so there is no limit. Other apps no longer reach those nodes
    /// (`PageTextPDFView`). View copies are reused for the same source, layout and marks, so
    /// switching between spread and single pages does not keep adding copies; the list grows only with new content
    /// or new page decorations.
    private struct ShownDocument {
        let source: PDFDocument
        let key: ViewPageLayout.DocumentKey?
        let marks: [ChangeMark]
        let furniture: [Int: FurniturePlacement]
        let document: PDFDocument
    }
    private var shownDocuments: [ShownDocument] = []
    private var logicalMargin: CGFloat?
    private var showsPageNumbers = false
    fileprivate weak var changeController: PaperController?
    private var changeMarks: [ChangeMark] = []
    private var drawnChangeMarks: [ChangeMark] = []
    private var furniture: [Int: FurniturePlacement] = [:]
    private var drawnFurniture: [Int: FurniturePlacement] = [:]
    private var isUpdatingDocument = false
    private var isSwitchingSpreadMode = false
    var onFindHits: (([Int], String) -> Void)?
    private var findQuery = ""
    private var findSearch: PaperFindSearch?
    fileprivate var displayOptions = DisplayAccessibility.shared.options {
        didSet {
            guard oldValue != displayOptions else { return }
            subviews.compactMap { $0 as? PaperSpotFrameView }.first?.apply(displayOptions)
            if !findHits.isEmpty { markFindHit(currentFindIndex, reveals: false) }
        }
    }
    private let proseUnderlines = ProseUnderlines()
    fileprivate private(set) var drawnProseSpans: [ProsePaperSpan] = []
    fileprivate var onPaperPress: (() -> Void)?
    private var currentFindIndex: Int?
    private(set) var findHits: [PDFSelection] = []
    var narrowsLoneCover = false {
        didSet {
            guard narrowsLoneCover != oldValue, document != nil else { return }
            goToPage(index: currentPageIndex)
        }
    }

    var formulaIndex: PaperFormulaIndex?
    var diagrams: [RenderedDiagram] = []
    var onDiagram: ((RenderedDiagram, PaperDiagramAction) -> Void)?

    private var pendingMenu: Task<Void, Never>?

    override func menu(for event: NSEvent) -> NSMenu? {
        pendingMenu?.cancel()
        let existing = super.menu(for: event)
        let location = convert(event.locationInWindow, from: nil)
        guard formulaIndex != nil || !diagrams.isEmpty, let document, let plan = pagePlan,
            let page = page(for: location, nearest: false)
        else { return existing }
        let slot = document.index(for: page)
        guard let index = plan.logicalIndex(at: slot) else { return existing }
        let scale = plan.scale(at: slot)
        let point = convert(location, to: page).applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        let hit = RenderedDiagram.hitTest(point, pageIndex: index, in: diagrams)
        if let hit { return graphicMenu(existing, hit: hit) }
        guard let formulaIndex else { return existing }
        if let entries = formulaIndex.entries {
            return graphicMenu(existing, hit: RenderedDiagram.hitTest(point, pageIndex: index, in: entries))
        }
        // PDFKit requests a menu synchronously. Present the original event's menu once
        // the first index is ready, provided the same paper and window are still showing.
        pendingMenu = Task { [weak self, weak document] in
            let entries = (try? await formulaIndex.resolve()) ?? []
            guard !Task.isCancelled, let self, let document, self.document === document,
                self.formulaIndex === formulaIndex, let window, window.isVisible, window === event.window,
                let menu = graphicMenu(existing, hit: RenderedDiagram.hitTest(point, pageIndex: index, in: entries))
            else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        return nil
    }

    func graphicMenu(_ existing: NSMenu?, hit diagram: RenderedDiagram?) -> NSMenu? {
        guard let diagram else { return existing }
        let menu = existing?.copy() as? NSMenu ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for action in PaperDiagramAction.actions(for: diagram) {
            let item = NSMenuItem(
                title: action.title(for: diagram), action: #selector(chooseDiagramAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (diagram, action)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseDiagramAction(_ sender: NSMenuItem) {
        if let (diagram, action) = sender.representedObject as? (RenderedDiagram, PaperDiagramAction) {
            onDiagram?(diagram, action)
        }
    }

    func copySourceSelection(to board: NSPasteboard) -> Bool {
        guard let selection = currentSelection, let sourceDocument, let document, let pagePlan else { return false }
        guard
            let text = SourcePaperText.selected(
                selection, in: sourceDocument,
                logicalIndex: { page in pagePlan.logicalIndex(at: document.index(for: page)) }),
            !text.isEmpty
        else { return false }
        board.clearContents()
        return board.setString(text, forType: .string)
    }

    override func copy(_ sender: Any?) {
        copySelection(to: .general) { super.copy(sender) }
    }

    func copySelection(to board: NSPasteboard, ordinaryCopy: () -> Void) {
        if copySourceSelection(to: board) { return }
        guard !drawnChangeMarks.isEmpty, let selection = currentSelection,
            let sourceDocument, let document, let pagePlan
        else {
            ordinaryCopy()
            return
        }
        // PDFKit can copy the screen's foreground color as rich text. Take the same ranges from the clean pages.
        let clean = PDFSelection(document: sourceDocument)
        for page in selection.pages {
            guard let index = pagePlan.logicalIndex(at: document.index(for: page)),
                let original = sourceDocument.page(at: index)
            else { continue }
            for offset in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: offset, on: page)
                if NSMaxRange(range) <= original.numberOfCharacters, let part = original.selection(for: range) {
                    clean.add(part)
                }
            }
        }
        guard let text = selection.string, !text.isEmpty else {
            ordinaryCopy()
            return
        }
        let content = clean.string == text ? clean.attributedString : nil
        board.clearContents()
        if !board.writeObjects([content ?? NSAttributedString(string: text)]) { ordinaryCopy() }
    }

    func configure(
        _ source: PDFDocument, at index: Int, options: ViewOptions, logicalMargin: CGFloat?, showsPageNumbers: Bool,
        changeMarks: [ChangeMark] = [], furniture: [Int: FurniturePlacement] = [:], keepsSpotInPage: Bool = false
    ) {
        guard
            sourceDocument !== source || self.options != options || self.logicalMargin != logicalMargin
                || self.showsPageNumbers != showsPageNumbers || self.changeMarks != changeMarks
                || self.furniture != furniture
        else { return }
        let point = keepsSpotInPage && sourceDocument !== source ? currentDestination?.point : nil
        let position = sourceDocument === source ? currentPageIndex : index
        isUpdatingDocument = true
        self.logicalMargin = logicalMargin
        self.showsPageNumbers = showsPageNumbers
        self.changeMarks = changeMarks
        self.furniture = furniture
        self.options = options
        configureDisplay(options)
        show(source, at: position)
        if let point, let pagePlan,
            let viewIndex = pagePlan.viewIndex(for: min(position, max(source.pageCount - 1, 0))),
            let page = document?.page(at: viewIndex)
        {
            go(to: PDFDestination(page: page, at: point))
        }
        isUpdatingDocument = false
        onPageChange?(currentPageIndex)
    }

    private var pageSize = CGSize(width: 595, height: 842)
    private var fittedSize = CGSize.zero
    private var isSettingScale = false
    private var magnifyMonitor: Any?
    private var wheelMonitor: Any?
    private var wheelSequence = WheelSequence()
    private var wheelTurner = WheelPageTurner()
    var wheelSensitivity: WheelPageTurner.Sensitivity = .normal {
        didSet { if oldValue != wheelSensitivity { wheelTurner = WheelPageTurner() } }
    }
    private var mouseDownEvent: NSEvent?
    private var didDrag = false
    /// The first click of this run of clicks followed a link, so the clicks after it are not a zoom or a page turn.
    private var clickFollowedLink = false
    /// Whether the current click or drag belongs to PDFKit's text selection; decided when the button goes down.
    private var dragSelectsText = false
    /// Dragging selects text instead of moving the window or panning the zoomed paper.
    var selectsText = false {
        didSet {
            guard selectsText != oldValue else { return }
            if !selectsText { clearSelection() }
            updateCursor()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        linkDelegate.view = self
        delegate = linkDelegate
        pageOverlayViewProvider = proseUnderlines
        acceptsDraggedFiles = false
        autoScales = false
        displaysPageBreaks = false
        pageBreakMargins = NSEdgeInsetsZero
        pageShadowsEnabled = false
        wantsLayer = true
        // Page curl transitions run as Core Image filters on this view's layer.
        layerUsesCoreImageFilters = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(scaleDidChange), name: .PDFViewScaleChanged, object: self)
        center.addObserver(self, selector: #selector(pageDidChange), name: .PDFViewPageChanged, object: self)
    }

    required init?(coder: NSCoder) { nil }

    fileprivate private(set) var isRetired = false

    fileprivate func retire() {
        guard !isRetired else { return }
        isRetired = true
        if changeController?.view === self { changeController?.view = nil }
        changeController = nil
        onFindHits = nil
        onPaperPress = nil
        onPageChange = nil
        onZoomChange = nil
        onTurn = nil
        onKey = nil
        onShortcut = nil
        allowsShortcutHandling = { false }
        onReadingJump = nil
        onToast = nil
        onDiagram = nil
        pendingMenu?.cancel()
        findSearch?.cancel()
        findSearch = nil
        stopZoomReturn()
        updateMagnifyMonitor()
        updateWheelMonitor()
        NotificationCenter.default.removeObserver(self)
        // A gesture recognizer can retain its closed container. Unhook it from the discarded view.
        gestureRecognizers = []
    }

    isolated deinit {
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        zoomDisplayLink?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isRetired else { return }
        updateMagnifyMonitor()
        updateWheelMonitor()
        if window == nil {
            stopZoomReturn()
            if displayedZoom < 1 { setZoom(1, anchor: nil) }
            pinchActive = false
        }
        // Arrow keys and the menu keys should work as soon as the window opens, without clicking the paper first.
        Task { @MainActor [weak self] in
            guard let self, !isRetired, let window, window.firstResponder === window || window.firstResponder == nil
            else { return }
            window.makeFirstResponder(self)
        }
    }

    var currentPageIndex: Int {
        guard let document, let page = currentPage else { return 0 }
        return pagePlan?.readingIndex(at: document.index(for: page)) ?? 0
    }

    func show(_ source: PDFDocument, at index: Int) {
        let wasUpdating = isUpdatingDocument
        isUpdatingDocument = true
        defer {
            isUpdatingDocument = wasUpdating
            if !wasUpdating { onPageChange?(currentPageIndex) }
        }
        let effectiveOptions =
            options
            ?? ViewOptions(
                layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        let sizes = (0..<source.pageCount).map { index in
            guard let page = source.page(at: index) else { return CGSize.zero }
            return PageSizes.displayed(page.bounds(for: .cropBox).size, rotation: page.rotation)
        }
        pageSize = PageSizes.representative(sizes)
        // Joined pages keep the margins their printed header and footer stand in.
        let keptEdges = furniture.mapValues { placement in
            ViewPageLayout.CropEdges(
                top: placement.lines.top.contains { !$0.isEmpty },
                bottom: placement.lines.bottom.contains { !$0.isEmpty })
        }
        let plan = ViewPageLayout(
            pageCount: source.pageCount, options: effectiveOptions, hasLogicalMargins: logicalMargin != nil,
            showsNumbers: showsPageNumbers, pageSizes: sizes, keptEdges: keptEdges)
        let key = plan.documentKey(margin: Double(logicalMargin ?? 0))
        if sourceDocument === source, documentKey == key, drawnChangeMarks == changeMarks,
            drawnFurniture == furniture, document != nil
        {
            // Layout and navigation may change without touching page content or losing the PDFKit page cache.
            pagePlan = plan
            hideScrollersAndInsets()
            refit()
            goToPage(index: min(index, max(source.pageCount - 1, 0)))
            return
        }
        sourceDocument = source
        let copy: PDFDocument?
        if key.requiresCopy || !changeMarks.isEmpty || !furniture.isEmpty {
            if let shown = shownDocuments.first(where: {
                $0.source === source && $0.key == key && $0.marks == changeMarks && $0.furniture == furniture
            }) {
                copy = shown.document
            } else {
                copy = ViewPageDocument.make(
                    source, plan: plan, margin: logicalMargin ?? 0, changeMarks: changeMarks, furniture: furniture)
            }
        } else {
            copy = source
        }
        drawnChangeMarks = changeMarks
        drawnFurniture = furniture
        documentKey = copy != nil ? key : nil
        let document = copy ?? source
        pagePlan =
            copy != nil
            ? plan
            : ViewPageLayout(
                pageCount: source.pageCount,
                options: ViewOptions(
                    layout: .single, scrollAxis: .vertical, transition: effectiveOptions.transition,
                    showsCoverAlone: false), hasLogicalMargins: false, showsNumbers: showsPageNumbers)
        stopZoomReturn()
        // A replacement keeps the user's zoom, but must not inherit transient rubber or old gesture events.
        displayedZoom = zoom
        if pinchActive { ignoresPinchRemainder = true }
        pinchActive = false
        wheelTurner = WheelPageTurner()
        if !shownDocuments.contains(where: { $0.document === document }) {
            shownDocuments.append(
                ShownDocument(
                    source: source, key: copy != nil ? key : nil, marks: copy != nil ? changeMarks : [],
                    furniture: copy != nil ? furniture : [:],
                    document: document))
        }
        drawProse([])
        self.document = document
        displayBox = .cropBox
        hideScrollersAndInsets()
        refit()
        goToPage(index: min(index, max(source.pageCount - 1, 0)))
        // The marks were selections of the pages just replaced.
        restartFind()
    }

    func apply(_ options: ViewOptions) {
        guard options != self.options else { return }
        if let sourceDocument {
            configure(
                sourceDocument, at: currentPageIndex, options: options, logicalMargin: logicalMargin,
                showsPageNumbers: showsPageNumbers, changeMarks: changeMarks, furniture: furniture)
        } else {
            self.options = options
            configureDisplay(options)
        }
    }

    private func configureDisplay(_ options: ViewOptions) {
        wheelTurner = WheelPageTurner()
        let mode: PDFDisplayMode =
            switch options.layout {
            case .single: options.isContinuous ? .singlePageContinuous : .singlePage
            case .spread: options.isContinuous ? .twoUpContinuous : .twoUp
            }
        if displayMode != mode { displayMode = mode }
        displaysAsBook = false
        displaysRTL = options.direction == .rightToLeft
        displayDirection = options.scrollAxis == .vertical ? .vertical : .horizontal
    }

    /// One page, or two side by side, at 100 %.
    var unitSize: CGSize {
        guard let options, options.layout != .single else { return pageSize }
        return CGSize(width: pageSize.width * 2, height: pageSize.height)
    }

    private var fittedUnitSize: CGSize {
        guard options?.isContinuous != true, let document, let currentPage else { return unitSize }
        let count = displayMode == .twoUp || displayMode == .twoUpContinuous ? 2 : 1
        let index = document.index(for: currentPage)
        let start = index - index % count
        var size = CGSize.zero
        for index in start..<min(start + count, document.pageCount) {
            guard let page = document.page(at: index) else { continue }
            let displayed = PageSizes.displayed(page.bounds(for: .cropBox).size, rotation: page.rotation)
            size.width += displayed.width
            size.height = max(size.height, displayed.height)
        }
        return size
    }

    private var fitScale: CGFloat {
        let unit = fittedUnitSize
        guard unit.width > 0, unit.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / unit.width, bounds.height / unit.height)
    }

    override func layout() {
        super.layout()
        hideScrollersAndInsets()
        // Fit again when the window changes size; the zoom the user chose is relative to the fit.
        if bounds.size != fittedSize { refit() }
        changeController?.revealPendingChange()
    }

    /// The paper is the window: scroll bars would narrow it, and scrolling still works without them. PDFKit turns them
    /// back on by itself whenever the scroll view's bounds change, with no layout after it to turn them off again, so
    /// the scroll view keeps scrollers that take no room and draw nothing, whatever PDFKit asks of them.
    private func hideScrollersAndInsets() {
        guard let scrollView = documentView?.enclosingScrollView else { return }
        if !(scrollView.verticalScroller is InvisibleScroller) { scrollView.verticalScroller = InvisibleScroller() }
        if !(scrollView.horizontalScroller is InvisibleScroller) { scrollView.horizontalScroller = InvisibleScroller() }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        // Under the hidden title bar, the scroll view would inset the paper by the title bar's height.
        if scrollView.automaticallyAdjustsContentInsets {
            let index = currentPageIndex
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsetsZero
            goToPage(index: index)
        }
    }

    #if DEBUG
        fileprivate func showSnapshotPage(_ index: Int) -> Bool {
            guard let pagePlan, let slot = pagePlan.viewIndex(for: index),
                let first = pagePlan.readingIndex(at: slot)
            else { return false }
            goToPage(index: index)
            // A sliver of the next page can already be visible in continuous mode.
            return currentPageIndex == first && isLogicalPageVisible(index)
        }

        func alignSnapshotPaper() {
            // Intermediate resize fits can fall inside refit's dead band. Apply the final geometry exactly once.
            let unit = fittedUnitSize
            guard bounds.width > 1, bounds.height > 1, unit.width > 0, unit.height > 0,
                document != nil, let backing = window?.backingScaleFactor, backing > 0
            else { return }
            let fit = min(
                (bounds.width * backing).rounded() / (unit.width * backing),
                (bounds.height * backing).rounded() / (unit.height * backing))
            let target = max(fit * displayedZoom, 0.01)
            if scaleFactor != target {
                isSettingScale = true
                scaleFactor = target
                isSettingScale = false
            }
            layoutDocumentView()
            guard let clip = documentView?.enclosingScrollView?.contentView else { return }
            let offset = clip.bounds.origin
            let aligned = CGPoint(
                x: (offset.x * backing).rounded() / backing, y: (offset.y * backing).rounded() / backing)
            let origin = clip.constrainBoundsRect(CGRect(origin: aligned, size: clip.bounds.size)).origin
            if clip.bounds.origin != origin { clip.scroll(to: origin) }
        }
    #endif

    private func refit() {
        guard !isSettingScale, bounds.width > 1, bounds.height > 1 else { return }
        fittedSize = bounds.size
        let target = max(fitScale * displayedZoom, 0.01)
        guard abs(scaleFactor - target) > 0.0005 else { return }
        // PDFKit keeps the centre in place when the scale changes; keep the top-left of the view instead, so that
        // fitting a resized window does not scroll the reader away from the start of the page.
        let destination = currentDestination
        isSettingScale = true
        scaleFactor = target
        isSettingScale = false
        if let destination { go(to: destination) }
        // A new scale can bring PDFKit's scroll bars back over the paper.
        hideScrollersAndInsets()
    }

    override func magnify(with event: NSEvent) {
        magnify(
            by: event.magnification, at: convert(event.locationInWindow, from: nil), phase: event.phase,
            time: event.timestamp)
    }

    override func smartMagnify(with event: NSEvent) {
        setZoom(isZoomed ? 1 : 2, anchor: convert(event.locationInWindow, from: nil))
    }

    /// PDFKit's scroll view takes pinches before this view sees them and rescales by itself, which the fit then undid,
    /// so a pinch snapped back. Taking the gestures before PDFKit makes every zoom this view's own.
    private func updateMagnifyMonitor() {
        guard !isRetired, window != nil else {
            if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
            magnifyMonitor = nil
            return
        }
        guard magnifyMonitor == nil else { return }
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleZoomGesture(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Zooms for a pinch or a smart zoom over the paper and reports whether it did.
    private func handleZoomGesture(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        // Keep the rest of an accepted pinch, including its end, even when the pointer crosses a panel.
        let continuingPinch = event.type == .magnify && pinchActive && !event.phase.contains(.began)
        guard continuingPinch || isPaper(atWindowPoint: event.locationInWindow) else { return false }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .magnify {
            magnify(by: event.magnification, at: point, phase: event.phase, time: event.timestamp)
        } else {
            setZoom(isZoomed ? 1 : 2, anchor: point)
        }
        return true
    }

    /// Whether this point of the window shows the paper itself, not the band or a panel laid over it: the monitor sees
    /// every gesture of the window, and those over the panels are theirs.
    func isPaper(atWindowPoint point: NSPoint) -> Bool {
        guard let content = window?.contentView, !isHiddenOrHasHiddenAncestor else { return false }
        let location = content.superview?.convert(point, from: nil) ?? point
        guard let hit = content.hitTest(location) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    /// Follows the fingers: each step of a pinch scales the zoom around the pointer, and the zoom stays where the
    /// fingers leave it.
    func magnify(by magnification: CGFloat, at anchor: NSPoint) {
        setZoom(zoom * (1 + Double(magnification)), anchor: anchor)
    }

    func magnify(by magnification: CGFloat, at anchor: NSPoint, phase: NSEvent.Phase, time: Double) {
        if phase.isEmpty {
            guard !ignoresPinchRemainder else { return }
            magnify(by: magnification, at: anchor)
            return
        }
        if phase.contains(.began) {
            stopZoomReturn()
            pinchActive = true
            ignoresPinchRemainder = false
            fingerZoom = PinchZoom.fingerZoom(for: displayedZoom)
            _ = pinchDetector.update(timestamp: time, zoom: fingerZoom, phase: .began)
        }
        guard pinchActive else { return }
        let ended = phase.contains(.ended) || phase.contains(.cancelled)
        defer { if ended { pinchActive = false } }
        guard !ignoresPinchRemainder else { return }
        fingerZoom = min(Self.maximumZoom, max(Double.leastNormalMagnitude, fingerZoom * (1 + Double(magnification))))
        let detectorPhase: PinchFlickDetector.Phase =
            phase.contains(.cancelled) ? .cancelled : ended ? .ended : .changed
        let flick = pinchDetector.update(timestamp: time, zoom: fingerZoom, phase: detectorPhase)
        setDisplayedZoom(PinchZoom.rubberBand(fingerZoom), anchor: anchor)
        if flick || (ended && displayedZoom < 1) {
            ignoresPinchRemainder = true
            returnToFit()
        }
    }

    @objc private func scaleDidChange() {
        // PDFKit also rescales on its own, for example when the display mode changes; the zoom stays the user's.
        guard !isSettingScale, fitScale > 0 else { return }
        refit()
    }

    @objc private func pageDidChange() {
        guard !isMeasuringFit, !isUpdatingDocument, !isSettingScale, !isSwitchingSpreadMode else { return }
        // PDFKit may turn pages itself, such as onto the blank before the cover or past the cover while showing one
        // page; show what the reader expects there.
        if let document, let page = currentPage, options?.layout == .spread, options?.isContinuous != true {
            let index = document.index(for: page)
            let narrow = isNarrowCover(at: index)
            if narrow != (displayMode == .singlePage) || (narrow && index == 0) {
                goToPage(index: pagePlan?.readingIndex(at: index) ?? 0)
                // Going to the page PDFKit already shows may post no notification of its own.
                onPageChange?(currentPageIndex)
                return
            }
        }
        if options?.isContinuous != true { refit() }
        onPageChange?(currentPageIndex)
    }

    // MARK: - Zoom

    func stepZoom(up: Bool) {
        let next =
            up
            ? Self.zoomSteps.first { $0 > zoom + 0.001 } ?? Self.maximumZoom
            : Self.zoomSteps.last { $0 < zoom - 0.001 } ?? 1
        setZoom(next, anchor: nil)
    }

    /// Changes the zoom while keeping the point under `anchor` (view coordinates) in place.
    func setZoom(_ value: Double, anchor: NSPoint?) {
        stopZoomReturn()
        if pinchActive { ignoresPinchRemainder = true }
        setDisplayedZoom(min(max(value, 1), Self.maximumZoom), anchor: anchor)
    }

    private func setDisplayedZoom(_ value: Double, anchor: NSPoint?, notify: Bool = true) {
        let previousZoom = zoom
        displayedZoom = value
        zoom = max(value, 1)
        defer {
            // Rubber-band values are presentation only; the model must never persist a zoom below fit.
            if notify && previousZoom != zoom { onZoomChange?(zoom) }
        }
        guard let documentView, let scrollView = documentView.enclosingScrollView else {
            refit()
            return
        }
        let clip = scrollView.contentView
        let anchorInView = anchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        // Remember the anchor as a point of its page: the document view's own coordinates do not scale with the zoom
        // by a plain ratio (the pages are centred and padded), so scaling them moved the paper under the pointer.
        guard let page = page(for: anchorInView, nearest: true) else {
            refit()
            return
        }
        let anchorOnPage = convert(anchorInView, to: page)
        refit()
        let actual = clip.convert(convert(anchorOnPage, from: page), from: self)
        let target = clip.convert(anchorInView, from: self)
        let origin = NSPoint(x: clip.bounds.minX + actual.x - target.x, y: clip.bounds.minY + actual.y - target.y)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func stopZoomReturn() {
        zoomDisplayLink?.invalidate()
        zoomDisplayLink = nil
        zoomReturn = nil
    }

    private func returnToFit() {
        stopZoomReturn()
        guard !shouldReduceMotion(), displayedZoom != 1,
            let page = currentPage, let clip = documentView?.enclosingScrollView?.contentView
        else {
            setDisplayedZoom(1, anchor: nil)
            return
        }
        let startZoom = displayedZoom
        let startOrigin = clip.bounds.origin
        let pagePoint = page.bounds(for: displayBox).origin
        let start = convert(pagePoint, from: page)
        // Ask PDFKit for the exact fitted destination (also valid in continuous and facing-page modes),
        // then restore before drawing. No transient fitted state is sent to the document model.
        isMeasuringFit = true
        setDisplayedZoom(1, anchor: nil, notify: false)
        let end = convert(pagePoint, from: page)
        setDisplayedZoom(startZoom, anchor: nil, notify: false)
        clip.scroll(to: startOrigin)
        documentView?.enclosingScrollView?.reflectScrolledClipView(clip)
        isMeasuringFit = false
        zoomReturn = ZoomReturn(
            path: PinchZoom.Return(startZoom: startZoom), startedAt: CACurrentMediaTime(), page: page,
            pagePoint: pagePoint, start: start, end: end)
        let link = displayLink(
            target: ZoomDisplayLinkTarget(view: self), selector: #selector(ZoomDisplayLinkTarget.tick(_:)))
        zoomDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    /// Shared by the display-link callback and deterministic tests, with elapsed time in seconds.
    func advanceZoomReturn(elapsed: Double) {
        guard let animation = zoomReturn else { return }
        let value = animation.path.zoom(elapsed: elapsed)
        setDisplayedZoom(value, anchor: nil)
        if let scrollView = documentView?.enclosingScrollView {
            let clip = scrollView.contentView
            let desired = NSPoint(
                x: animation.path.position(start: animation.start.x, end: animation.end.x, zoom: value),
                y: animation.path.position(start: animation.start.y, end: animation.end.y, zoom: value))
            let actual = clip.convert(convert(animation.pagePoint, from: animation.page), from: self)
            let target = clip.convert(desired, from: self)
            let origin = NSPoint(x: clip.bounds.minX + actual.x - target.x, y: clip.bounds.minY + actual.y - target.y)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        }
        if elapsed >= PinchZoom.Return.duration { stopZoomReturn() }
    }

    private var isZoomed: Bool { zoom > 1.001 }

    // MARK: - Turning pages

    func goToPage(index: Int, in source: PDFDocument? = nil) {
        guard source == nil || sourceDocument === source else { return }
        guard let document, let pagePlan, let requested = pagePlan.viewIndex(for: index),
            let first = pagePlan.readingIndex(at: requested), let viewIndex = pagePlan.viewIndex(for: first),
            let page = document.page(at: viewIndex)
        else { return }
        finishZoomReturnForNavigation()
        applySpreadMode(narrow: isNarrowCover(at: viewIndex))
        go(to: page)
        if options?.isContinuous != true { refit() }
    }

    fileprivate func revealChange(on index: Int, pinnedBandHeight: CGFloat) {
        goToPage(index: index)
        guard isZoomed || pinnedBandHeight > 0, let pagePlan, let slot = pagePlan.viewIndex(for: index),
            let page = document?.page(at: slot), let original = sourceDocument?.page(at: index),
            let scroll = documentView?.enclosingScrollView
        else { return }
        layoutDocumentView()
        let scale = pagePlan.scale(at: slot)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let crop = original.bounds(for: .cropBox)
        // Deletion marks can be appended after later paragraphs. Follow the first visible mark in reading order.
        let visibleBox = page.bounds(for: .cropBox)
        let frames = changeMarks.lazy.filter { $0.pageIndex == index }.map {
            $0.highlight(in: crop).applying(transform).intersection(visibleBox)
        }
        guard
            let first = frames.filter({ !$0.isEmpty }).min(by: {
                $0.maxY == $1.maxY ? $0.minX < $1.minX : $0.maxY > $1.maxY
            })
        else { return }

        let clip = scroll.contentView
        let viewport = convert(clip.bounds, from: clip)
        let frame = convert(first, from: page)
        let mark = CGRect(
            x: frame.minX - viewport.minX, y: isFlipped ? frame.minY - viewport.minY : viewport.maxY - frame.maxY,
            width: frame.width, height: frame.height)
        let target = ChangeNavigation.targetViewport(
            for: mark, size: viewport.size, zoomed: isZoomed, pinnedBandHeight: pinnedBandHeight)
        guard target.origin != .zero else { return }
        let moved = viewport.offsetBy(dx: target.minX, dy: isFlipped ? target.minY : -target.minY)
        clip.scroll(to: clip.constrainBoundsRect(clip.convert(moved, from: self)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    override func go(to page: PDFPage) {
        super.go(to: page)
        alignHorizontalScroll(to: page)
    }

    override func go(to destination: PDFDestination) {
        if isTrackingSelectionLink, let page = destination.page, let document, page.document === document,
            let target = pagePlan?.readingIndex(at: document.index(for: page))
        {
            onReadingJump?(target)
        }
        super.go(to: destination)
        if let page = destination.page { alignHorizontalScroll(to: page) }
    }

    /// In one page after another across the window, PDFKit moves its current page but not the paper.
    private func alignHorizontalScroll(to page: PDFPage) {
        guard let options, options.isSinglePageContinuous, options.scrollAxis == .horizontal,
            let scrollView = documentView?.enclosingScrollView
        else { return }
        layoutDocumentView()
        let clip = scrollView.contentView
        var origin = clip.convert(convert(page.bounds(for: displayBox), from: page).origin, from: self)
        origin.y = clip.bounds.minY
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The cover of a paged spread, shown alone: the view copy puts a blank page before it (view index 0), and the
    /// cover itself is view index 1.
    private func isNarrowCover(at viewIndex: Int) -> Bool {
        guard narrowsLoneCover, let options, let pagePlan,
            options.layout == .spread, options.showsCoverAlone, !options.isContinuous,
            pagePlan.logicalIndex(at: 0) == nil
        else { return false }
        return viewIndex < 2
    }

    /// PDFKit shows two pages side by side or one; the lone cover takes one so that the window can be one page wide
    /// instead of showing a blank page beside it.
    private func applySpreadMode(narrow: Bool) {
        guard let options, options.layout == .spread, !options.isContinuous else { return }
        let mode: PDFDisplayMode = narrow ? .singlePage : .twoUp
        guard displayMode != mode else { return }
        isSwitchingSpreadMode = true
        displayMode = mode
        isSwitchingSpreadMode = false
    }

    func turnPage(forward: Bool) {
        guard let options else { return }
        finishZoomReturnForNavigation()
        guard let document, let page = currentPage,
            let next = pagePlan?.adjacentReadingIndex(at: document.index(for: page), forward: forward)
        else { return }
        addTransition(forward: forward, options: options)
        goToPage(index: next)
        onTurn?()
    }

    private func finishZoomReturnForNavigation() {
        guard isReturningToFit else { return }
        // Only explicit navigation settles the return; PDFKit's scale-driven page notifications must not.
        let page = currentPage
        setZoom(1, anchor: nil)
        // Fitting a continuous document may change currentPage; a relative turn must still start at the old page.
        if let page { go(to: page) }
    }

    private func addTransition(forward: Bool, options: ViewOptions) {
        guard !options.isContinuous, !shouldReduceMotion(), let layer else {
            return
        }
        let transition = CATransition()
        transition.duration = 0.28 * Self.animationScale
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // The next page comes from the side the book opens towards.
        let nextFromRight = options.direction == .leftToRight
        switch options.transition {
        case .scroll, .instant:
            return
        case .slide, .cover, .reveal:
            transition.type = options.transition == .cover ? .moveIn : options.transition == .reveal ? .reveal : .push
            transition.subtype =
                switch options.slideEdge(forward: forward) {
                case .left: .fromLeft
                case .right: .fromRight
                case .top: .fromTop
                case .bottom: .fromBottom
                }
        case .fade:
            transition.type = .fade
        case .wipe:
            guard let filter = CIFilter(name: "CISwipeTransition") else {
                transition.type = .fade
                break
            }
            filter.setDefaults()
            let angle: Double =
                switch options.slideEdge(forward: forward) {
                case .right: .pi
                case .left: 0
                case .bottom: .pi / 2
                case .top: -.pi / 2
                }
            filter.setValue(angle, forKey: kCIInputAngleKey)
            filter.setValue(CIVector(cgRect: bounds), forKey: kCIInputExtentKey)
            filter.setValue(24, forKey: "inputWidth")
            transition.filter = filter
        case .zoom:
            transition.type = .fade
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = forward ? 0.96 : 1.04
            scale.toValue = 1
            scale.duration = transition.duration
            scale.timingFunction = transition.timingFunction
            layer.add(scale, forKey: "pageTurnScale")
        case .pageCurl:
            let curl = PageCurl(forward: forward, nextFromRight: nextFromRight)
            guard let filter = curl.filter(extent: layer.bounds) else {
                transition.type = .fade
                break
            }
            transition.filter = filter
            transition.duration = PageCurl.duration * Self.animationScale
            transition.timingFunction = PageCurl.timing
        }
        #if DEBUG
            if let progress = Self.frozenTurnProgress {
                transition.speed = 0
                transition.timeOffset = progress * transition.duration
            }
        #endif
        layer.add(transition, forKey: "pageTurn")
    }

    // MARK: - Events

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    private func updateWheelMonitor() {
        guard !isRetired, window != nil else {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
            wheelSequence = WheelSequence()
            wheelTurner = WheelPageTurner()
            return
        }
        guard wheelMonitor == nil else { return }
        // PDFKit's inner scroll view can consume wheel events before the PDFView override.
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleWheelEvent(event) ?? false }
            return handled ? nil : event
        }
    }

    /// Shared by the local monitor and responder fallback; hit testing excludes overlay controls.
    func handleWheelEvent(_ event: NSEvent) -> Bool {
        let phase: WheelPageTurner.Phase
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            phase = .momentumEnded
        } else if !event.momentumPhase.isEmpty {
            phase = .momentum
        } else if event.phase.contains(.cancelled) {
            phase = .cancelled
        } else if event.phase.contains(.ended) {
            phase = .ended
        } else if event.phase.contains(.began) {
            phase = .began
        } else if !event.phase.isEmpty {
            phase = .changed
        } else {
            phase = .discrete
        }
        let canTurn = options?.isContinuous == false && !isZoomed && !pinchActive && !isReturningToFit
        let command = event.modifierFlags.contains(.command)
        // Observe starts and ends even outside the paper. Current pointer position cannot steal momentum.
        let ownership = wheelSequence.update(
            phase: phase, timestamp: event.timestamp,
            startsOnPaper: event.window === window && isPaper(atWindowPoint: event.locationInWindow)
                && (command || canTurn))
        if ownership.startsSequence { wheelTurner.beginSequence() }
        guard ownership.owns, event.window === window else { return false }
        if phase == .momentum || phase == .momentumEnded { return true }
        if command {
            let anchor = convert(event.locationInWindow, from: nil)
            setZoom(zoom * exp(Double(event.scrollingDeltaY) * 0.01), anchor: anchor)
            return true
        }
        guard canTurn, let options else { return true }
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        // Discrete mice report lines; trackpads report precise point travel.
        let delta =
            phase == .discrete
            ? (horizontal ? event.deltaX : event.deltaY)
            : (horizontal ? event.scrollingDeltaX : event.scrollingDeltaY)
        let sign: Double = horizontal && options.direction == .rightToLeft ? 1 : -1
        if let forward = wheelTurner.update(
            delta: Double(delta) * sign, phase: phase, timestamp: event.timestamp, sensitivity: wheelSensitivity)
        {
            turnPage(forward: forward)
        }
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        pendingMenu?.cancel()
        if !handleWheelEvent(event) { super.scrollWheel(with: event) }
    }

    var shortcutRegion: ShortcutRegion { selectsText ? .paperSelection : .paperReading }

    /// Both the application monitor and the responder fallback use this same operation adapter.
    func performShortcut(_ operation: ShortcutOperationID, event: NSEvent) {
        guard let options else { return }
        switch operation {
        case .readingLeft: turnPage(forward: options.direction == .rightToLeft)
        case .readingRight: turnPage(forward: options.direction != .rightToLeft)
        case .readingPrevious, .readingNext:
            if options.isContinuous || isZoomed {
                // Keep PDFKit's scrolling for the default vertical arrows and Space. A replacement key has
                // the same meaning, so use the responder's scroll action rather than interpreting its letter.
                if let key = ShortcutDispatcher.combination(event, allowsBareKeys: true),
                    ShortcutDefaults.keys(for: operation).contains(key)
                {
                    passKeyToPDFKit(event)
                } else if operation == .readingNext {
                    scrollPageDown(nil)
                } else {
                    scrollPageUp(nil)
                }
            } else {
                turnPage(forward: operation == .readingNext)
            }
        case .readingPageUp: performNativeNavigation(.pageUp, code: 116, event: event)
        case .readingPageDown: performNativeNavigation(.pageDown, code: 121, event: event)
        case .readingFirst: performNativeNavigation(.home, code: 115, event: event)
        case .readingLast: performNativeNavigation(.end, code: 119, event: event)
        default: onShortcut?(operation)
        }
    }

    /// Invoke PDFKit's existing navigation without posting a key to the application or its menus. Default events
    /// go through unchanged; a replacement key asks PDFKit for the same named navigation, never for its new letter.
    private func performNativeNavigation(_ key: ShortcutNamedKey, code: UInt16, event: NSEvent) {
        if ShortcutDispatcher.combination(event, allowsBareKeys: true) == ShortcutCombination(key: .named(key)) {
            passKeyToPDFKit(event)
            return
        }
        guard let text = ShortcutMenuKey.character(.named(key)),
            let native = NSEvent.keyEvent(
                with: .keyDown, location: event.locationInWindow, modifierFlags: [], timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: event.isARepeat, keyCode: code)
        else { return }
        passKeyToPDFKit(native)
    }

    override func keyDown(with event: NSEvent) {
        pendingMenu?.cancel()
        if dispatchKey(event) { return }
        guard !shortcutController.hotKeys.isRecording, window?.attachedSheet == nil, NSApp.modalWindow == nil,
            allowsShortcutHandling(), ShortcutSurfaceKeys.owner(of: window?.firstResponder) === self
        else {
            passKeyToPDFKit(event)
            return
        }
        // Tab remains a fixed contextual alias; keyboard-access navigation takes precedence.
        if event.specialKey != .tab || !fullKeyboardAccess() {
            if onKey?(event) == true { return }
        }
        if let operation = ShortcutSurfaceKeys.match(event, region: shortcutRegion, controller: shortcutController) {
            performShortcut(operation, event: event)
            return
        }
        // A moved/cleared reading or zoom key must not revive PDFKit's internal binding. Selection navigation
        // remains native; its region excludes unmodified navigation bindings.
        if let key = ShortcutDispatcher.combination(event, allowsBareKeys: true),
            ShortcutDispatcher.blocksNativePaperKey(key, region: shortcutRegion)
        {
            return
        }
        passKeyToPDFKit(event)
    }

    private func passKeyToPDFKit(_ event: NSEvent) {
        if event.specialKey == .home { onReadingJump?(0) }
        if event.specialKey == .end, let sourceDocument { onReadingJump?(sourceDocument.pageCount - 1) }
        if let nativeKeyHandler { nativeKeyHandler(event) } else { super.keyDown(with: event) }
    }

    /// Option swaps the two drags for as long as it is held, so a word can be copied without switching modes.
    func selectsText(for event: NSEvent) -> Bool {
        selectsText != event.modifierFlags.contains(.option)
    }

    /// With Option held PDFKit would select a rectangle; here Option only means "select text for now".
    static func withoutOption(_ event: NSEvent) -> NSEvent {
        guard event.modifierFlags.contains(.option) else { return event }
        return NSEvent.mouseEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags.subtracting(.option),
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
            clickCount: event.clickCount, pressure: event.pressure) ?? event
    }

    private var isTrackingSelectionLink = false

    override func mouseDown(with event: NSEvent) {
        onPaperPress?()
        pendingMenu?.cancel()
        window?.makeFirstResponder(self)
        dragSelectsText = selectsText(for: event)
        if dragSelectsText {
            // Record only a destination actually followed, not a drag or a cancelled link click.
            isTrackingSelectionLink = link(at: convert(event.locationInWindow, from: nil)) != nil
            defer { isTrackingSelectionLink = false }
            // PDFKit selects by drag, words by double-click and lines by triple-click; no page turns or zoom here. It
            // tracks the drag in a loop of its own and returns when the button goes up.
            mouseDownEvent = nil
            super.mouseDown(with: Self.withoutOption(event))
            return
        }
        if event.clickCount > 1, clickFollowedLink {
            mouseDownEvent = nil
            return
        }
        clickFollowedLink = false
        if event.clickCount == 2 {
            setZoom(isZoomed ? 1 : 2, anchor: convert(event.locationInWindow, from: nil))
            mouseDownEvent = nil
            return
        }
        mouseDownEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        if dragSelectsText {
            super.mouseDragged(with: event)
            return
        }
        guard let start = mouseDownEvent else { return }
        let distance = hypot(
            event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        if !didDrag, distance < 3 { return }
        if !isZoomed {
            // The paper is the window: dragging it moves the window, as in QuickTime Player.
            mouseDownEvent = nil
            window?.performDrag(with: start)
            return
        }
        didDrag = true
        guard let clip = documentView?.enclosingScrollView?.contentView else { return }
        var origin = clip.bounds.origin
        // The deltas are points of the window, and a magnified paper's own points are smaller: taken as they are,
        // the paper ran ahead of the pointer by the zoom.
        let scale = clip.convert(NSSize(width: 1, height: 1), from: nil)
        origin.x -= event.deltaX * scale.width
        origin.y += (clip.isFlipped ? -event.deltaY : event.deltaY) * scale.height
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        documentView?.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if dragSelectsText {
            dragSelectsText = false
            super.mouseUp(with: event)
            return
        }
        defer { mouseDownEvent = nil }
        guard let start = mouseDownEvent, !didDrag else { return }
        // A link wins over the edge it may lie on: the reader aimed at the link, not at the margin.
        if let link = link(at: convert(start.locationInWindow, from: nil)) {
            clickFollowedLink = true
            follow(link)
            return
        }
        guard let options, !options.isContinuous, !isZoomed else { return }
        // Clicking near the left or right edge turns the page towards that side.
        let x = convert(event.locationInWindow, from: nil).x
        let edge = bounds.width * 0.15
        let rightToLeft = options.direction == .rightToLeft
        if x < edge {
            turnPage(forward: rightToLeft)
        } else if x > bounds.width - edge {
            turnPage(forward: !rightToLeft)
        }
    }

    // MARK: - Links

    /// The link under a point of this view. PDFKit follows links only while it tracks the mouse itself, which is
    /// the text selection; an ordinary click is handled here, so the link has to be found here too.
    func link(at point: NSPoint) -> PDFAnnotation? {
        guard let page = page(for: point, nearest: false),
            let annotation = page.annotation(at: convert(point, to: page)), annotation.type == "Link",
            annotation.action != nil || annotation.destination != nil || annotation.url != nil
        else { return nil }
        return annotation
    }

    private func follow(_ link: PDFAnnotation) {
        let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination
        if let destination, let page = destination.page, let document, page.document === document {
            if let target = pagePlan?.readingIndex(at: document.index(for: page)) { onReadingJump?(target) }
            if let options, !options.isContinuous, !isZoomed,
                let target = pagePlan?.readingIndex(at: document.index(for: page))
            {
                // Whole pages are turned the way the keys turn them, so a spread and its lone cover stay right.
                guard target != currentPageIndex else { return }
                addTransition(forward: target > currentPageIndex, options: options)
                goToPage(index: target)
                onTurn?()
            } else {
                go(to: destination)
            }
        } else if let action = link.action {
            // PDFKit hands a URL to the delegate, the same way as for a click while selecting text.
            perform(action)
        } else if let url = link.url {
            perform(PDFActionURL(url: url))
        }
    }

    // MARK: - Cursor

    /// PDFKit shows an I-beam over text; without the selection mode a drag moves the window, so the paper shows the
    /// arrow instead, or the open hand while a drag pans the zoomed paper.
    private var paperCursor: NSCursor { isZoomed ? .openHand : .arrow }

    /// The cursor over a point of the paper when a drag does not select text: a click follows a link, so a link
    /// shows the pointing hand in every mode.
    func cursor(at point: NSPoint) -> NSCursor {
        link(at: point) != nil ? .pointingHand : paperCursor
    }

    override func mouseMoved(with event: NSEvent) {
        setCursor(for: event) { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        setCursor(for: event) { super.cursorUpdate(with: event) }
    }

    private func setCursor(for event: NSEvent, selecting: () -> Void) {
        let point = convert(event.locationInWindow, from: nil)
        if link(at: point) != nil {
            NSCursor.pointingHand.set()
        } else if selectsText(for: event) {
            selecting()
        } else {
            paperCursor.set()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCursor(modifierFlags: event.modifierFlags)
    }

    private func updateCursor(modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard let window, window.isKeyWindow else { return }
        // The band and the panels lie over the paper; the cursor over them is theirs.
        let location = window.mouseLocationOutsideOfEventStream
        guard isPaper(atWindowPoint: location) else { return }
        let point = convert(location, from: nil)
        if link(at: point) == nil, selectsText != modifierFlags.contains(.option) {
            setCursorFor(areaOfInterest(for: point))
        } else {
            cursor(at: point).set()
        }
    }

    override func selectAll(_ sender: Any?) {
        // Select All would highlight every word while a drag still moves the window.
        guard selectsText else { return }
        super.selectAll(sender)
    }
}

extension PaperPDFView {
    fileprivate func isLogicalPageVisible(_ index: Int) -> Bool {
        guard let slot = pagePlan?.viewIndex(for: index), let page = document?.page(at: slot) else { return false }
        return visiblePages.contains(page)
    }

    fileprivate func proseSelections(_ spans: [ProsePaperSpan]) -> [PDFSelection]? {
        guard !spans.isEmpty else { return nil }
        var selections: [PDFSelection] = []
        for span in spans {
            guard let slot = pagePlan?.viewIndex(for: span.page), let page = document?.page(at: slot),
                let original = sourceDocument?.page(at: span.page),
                page === original || page.string == original.string,
                NSMaxRange(span.range) <= page.numberOfCharacters, let selection = page.selection(for: span.range),
                selection.string == span.text
            else { return nil }
            selections.append(selection)
        }
        return selections
    }

    func revealProse(_ spans: [ProsePaperSpan]) {
        guard let document, let selections = proseSelections(spans) else { return }
        layoutDocumentView()
        guard let documentView else { return }
        let visible = documentView.visibleRect
        guard !visible.isEmpty else { return }
        var nearest: NSRect?
        var leastDistance = CGFloat.infinity
        let onScreen = visiblePages
        let readingPage = currentPageIndex
        for selection in selections {
            guard let page = selection.pages.first,
                onScreen.contains(page) || pagePlan?.readingIndex(at: document.index(for: page)) == readingPage
            else { continue }
            func frame(of selection: PDFSelection) -> CGRect {
                documentView.convert(convert(selection.bounds(for: page), from: page), from: self)
            }
            let whole = frame(of: selection)
            let fits = whole.width <= visible.width && whole.height <= visible.height
            let boxes = fits ? [whole] : selection.selectionsByLine().map { frame(of: $0) }
            for box in boxes {
                guard !box.isEmpty else { continue }
                let width = min(box.width, visible.width)
                let height = min(box.height, visible.height)
                // A line wider than the viewport can already be readable at the current scroll position.
                let target = NSRect(
                    x: max(box.minX, min(visible.minX, box.maxX - width)),
                    y: max(box.minY, min(visible.minY, box.maxY - height)), width: width, height: height)
                if visible.contains(target) { return }
                let dx = max(0, visible.minX - target.minX, target.maxX - visible.maxX)
                let dy = max(0, visible.minY - target.minY, target.maxY - visible.maxY)
                let distance = dx * dx + dy * dy
                if distance < leastDistance {
                    nearest = target
                    leastDistance = distance
                }
            }
        }
        if let nearest { documentView.scrollToVisible(nearest) }
    }

    func drawProse(_ spans: [ProsePaperSpan]) {
        guard spans != drawnProseSpans else { return }
        drawnProseSpans = []
        proseUnderlines.show([])
        guard findQuery.isEmpty else { return }
        highlightedSelections = nil
        guard let selections = proseSelections(spans) else { return }
        for selection in selections { selection.color = NSColor(PrintPalette.paperAi).withAlphaComponent(0.50) }
        proseUnderlines.show(selections)
        highlightedSelections = selections
        drawnProseSpans = spans
    }
}

// MARK: - Find

/// One search of a document for the find bar.
///
/// PDFKit's `beginFindString` returns at once, reads the pages a few at a time between the main run loop's other
/// work and posts each match on the main thread, so a long document never holds the window up and no page is read off
/// the main actor, which PDFDocument does not promise to be safe for. The matches are selections of the document:
/// nothing is added to its pages.
private final class PaperFindSearch: NSObject {
    private let document: PDFDocument
    private let onEnd: ([PDFSelection]) -> Void
    private var selections: [PDFSelection] = []
    private var isRunning = false

    init(document: PDFDocument, onEnd: @escaping ([PDFSelection]) -> Void) {
        self.document = document
        self.onEnd = onEnd
    }

    func start(_ query: String) {
        isRunning = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didFindMatch), name: .PDFDocumentDidFindMatch, object: document)
        center.addObserver(self, selector: #selector(didEndFind), name: .PDFDocumentDidEndFind, object: document)
        // PDFKit honours these two options; it ignores the width-insensitive one.
        document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    func cancel() {
        guard isRunning else { return }
        stopObserving()
        document.cancelFindString()
    }

    private func stopObserving() {
        isRunning = false
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func didFindMatch(_ note: Notification) {
        guard isRunning, let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
        selections.append(selection)
    }

    @objc private func didEndFind(_ note: Notification) {
        guard isRunning else { return }
        stopObserving()
        onEnd(selections)
    }
}

extension PaperPDFView {
    private static let findHitColor = NSColor.systemYellow.withAlphaComponent(0.55)
    private static let findCurrentHitColor = NSColor.systemOrange

    /// Marks every place the pages hold `query`, and takes the marks away for no words. The marks are the view's own
    /// highlights, not annotations, so the pages that are printed and exported never carry them.
    func find(_ query: String) {
        guard query != findQuery else { return }
        if !query.isEmpty { drawProse([]) }
        findQuery = query
        restartFind()
    }

    /// Searches the pages now shown for the words of the bar, dropping a search still under way.
    private func restartFind() {
        findSearch?.cancel()
        findSearch = nil
        guard !findHits.isEmpty || !findQuery.isEmpty else { return }
        findHits = []
        highlightedSelections = nil
        guard !findQuery.isEmpty, let document else { return }
        let query = findQuery
        let search = PaperFindSearch(document: document) { [weak self] selections in
            self?.finishFind(selections, for: query, in: document)
        }
        findSearch = search
        search.start(query)
    }

    private func finishFind(_ selections: [PDFSelection], for query: String, in searched: PDFDocument) {
        findSearch = nil
        guard query == findQuery, document === searched else { return }
        findHits = selections
        let pages = selections.map { selection in
            guard let page = selection.pages.first else { return 0 }
            let viewIndex = searched.index(for: page)
            return pagePlan?.logicalIndex(at: viewIndex) ?? pagePlan?.readingIndex(at: viewIndex) ?? 0
        }
        markFindHit(nil, reveals: false)
        onFindHits?(pages, query)
    }

    /// Colours the current hit apart from the others and, with `reveals`, turns to its page the way the outline does
    /// and scrolls a paper that does not fit until the hit is in sight.
    func markFindHit(_ index: Int?, reveals: Bool) {
        currentFindIndex = index
        let other =
            displayOptions.reduceTransparency || displayOptions.increasedContrast
            ? NSColor(srgbRed: 1, green: 0.93, blue: 0.55, alpha: 1) : Self.findHitColor
        for (offset, hit) in findHits.enumerated() {
            hit.color = offset == index ? Self.findCurrentHitColor : other
        }
        // PDFKit draws the highlights again only when it is given others than it has, so the same selections in new
        // colours go in after none.
        highlightedSelections = nil
        if !findHits.isEmpty { highlightedSelections = findHits }
        guard reveals, let index, findHits.indices.contains(index), let page = findHits[index].pages.first,
            let document, let pagePlan
        else { return }
        let viewIndex = document.index(for: page)
        if !visiblePages.contains(page),
            let logical = pagePlan.logicalIndex(at: viewIndex) ?? pagePlan.readingIndex(at: viewIndex)
        {
            goToPage(index: logical)
        }
        layoutDocumentView()
        _ = scrollIntoSight(convert(findHits[index].bounds(for: page), from: page))
    }
}

// MARK: - A frame around a spot

/// A spot on the paper to point out: the logical page it is on, and the rectangle that marks it there, in the page's
/// own coordinates. It belongs to one set of pages, the ones the paper was given (the render's `viewDocument`): the
/// rectangle means nothing on the pages of another document, not even one of the same number of pages.
struct PaperSpot: Equatable {
    let pageIndex: Int
    let anchor: CGRect
    let document: PDFDocument
    var framesLine = false

    static func == (left: Self, right: Self) -> Bool {
        left.pageIndex == right.pageIndex && left.anchor == right.anchor && left.document === right.document
            && left.framesLine == right.framesLine
    }
}

extension PaperController {
    /// Frames `spot` for a moment, once the paper is made of the spot's document. It reports false while no such paper
    /// is on screen, so that a caller that has just changed the window can ask again.
    @discardableResult
    func showSpot(_ spot: PaperSpot) -> Bool {
        view?.showSpot(spot) ?? false
    }
}

extension PaperPDFView {
    /// Frames `spot` once the paper has held still on it, and takes the frame away after `lifetime`.
    @discardableResult
    func showSpot(_ spot: PaperSpot, lifetime: Duration = PaperSpotFrameView.defaultLifetime) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor, isMade(of: spot.document), viewRect(for: spot) != nil
        else { return false }
        let frame: PaperSpotFrameView
        if let existing = subviews.compactMap({ $0 as? PaperSpotFrameView }).first {
            frame = existing
        } else {
            frame = PaperSpotFrameView()
            addSubview(frame)
        }
        frame.show(spot, lifetime: lifetime)
        return true
    }

    /// Whether these are the pages `document` stands for. Showing it another way (spread, single page) is still the
    /// same pages; being given another document is not.
    fileprivate func isMade(of document: PDFDocument) -> Bool { sourceDocument === document }

    /// Where `spot` lies in this view, or nil when the paper has no such page or does not show it now. A page that is
    /// not shown is no place to draw: PDFKit still converts a rectangle on it, to wherever it would lie.
    fileprivate func viewRect(for spot: PaperSpot) -> NSRect? {
        guard isMade(of: spot.document), let document, let pagePlan,
            let viewIndex = pagePlan.viewIndex(for: spot.pageIndex),
            let page = document.page(at: viewIndex), visiblePages.contains(page)
        else { return nil }
        // A page that the continuous layout scales carries its marks with it.
        let scale = pagePlan.scale(at: viewIndex)
        let anchor = spot.anchor.applying(CGAffineTransform(scaleX: scale, y: scale))
        let box = page.bounds(for: .cropBox)
        let frame =
            spot.framesLine
            ? anchor.insetBy(dx: -2, dy: 0).intersection(box) : PrintIssue.spotFrame(around: anchor, in: box)
        return convert(frame, from: page)
    }

    /// Scrolls a magnified paper, when the frame would lie out of sight, until the frame's whole height and the end
    /// where it starts are in view. The other end may run past the window, as it does on a paper that fits. It reports
    /// whether the paper moved.
    fileprivate func scrollIntoSight(_ frame: NSRect) -> Bool {
        let focus = NSRect(x: frame.minX, y: frame.minY, width: min(frame.width, 24), height: frame.height)
        guard !bounds.contains(focus), let scrollView = documentView?.enclosingScrollView else { return false }
        let clip = scrollView.contentView
        let visible = clip.bounds
        let wanted = clip.convert(focus, from: self)
        var origin = visible.origin
        if focus.minY < bounds.minY || focus.maxY > bounds.maxY {
            origin.y = wanted.midY - visible.height / 2
        }
        if focus.minX < bounds.minX || focus.maxX > bounds.maxX {
            // 16 points in from the window's edge, in the clip view's own units.
            origin.x = wanted.minX - 16 * visible.width / max(bounds.width, 1)
        }
        let moved = clip.constrainBoundsRect(NSRect(origin: origin, size: visible.size)).origin
        guard moved != visible.origin else { return false }
        clip.scroll(to: moved)
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}

/// The frame the paper shows around a spot for a moment. It is a view laid over the paper view and no part of the
/// pages, so the print and the export never carry it, and it passes every click through to the paper.
@MainActor
final class PaperSpotFrameView: NSView {
    static let defaultLifetime = Duration.seconds(2)
    /// A frame that the paper has not held still under for this long is dropped.
    private static let patience = Duration.seconds(5)
    private static let fadeIn = 0.2
    private static let fadeOut = 0.3
    /// How many ticks in a row the spot must stay in one place before the frame shows, so that it does not slide
    /// along with a window that is still resizing or a page that PDFKit is still placing.
    private static let steadyTicks = 3
    /// How often the paper is scrolled towards a spot out of sight before it is left as it is.
    private static let scrollAttempts = 20
    private static let tick = Duration.milliseconds(33)

    private var spot: PaperSpot?
    private var task: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        isHidden = true
        let indigo = NSColor(PrintPalette.paperAi)
        layer?.borderColor = indigo.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = AppPreferences.shared.corners.radius(for: .badge, shortestSide: .infinity)
        apply(DisplayAccessibility.shared.options)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    fileprivate func apply(_ options: DisplayAccessibility.Options) {
        // An opaque wash would cover the very text the spot locates. Keep only its perimeter.
        layer?.borderWidth = options.increasedContrast ? 3 : 2
        layer?.backgroundColor =
            options.reduceTransparency ? nil : NSColor(PrintPalette.paperAi).withAlphaComponent(0.08).cgColor
    }

    func show(_ spot: PaperSpot, lifetime: Duration) {
        task?.cancel()
        self.spot = spot
        alphaValue = 0
        isHidden = true
        task = Task { @MainActor [weak self] in await self?.follow(lifetime: lifetime) }
    }

    /// The spot is meant for the pages the paper was made of when it was found. Once the paper is given others, a
    /// reload or a new layout, its coordinates would mark some other text.
    private var isCurrent: Bool {
        guard let paper = superview as? PaperPDFView, let spot else { return false }
        return paper.isMade(of: spot.document)
    }

    /// Scrolls the paper to the spot if it lies out of sight, shows the frame once the spot has held still, keeps it
    /// on the spot while the paper moves, and takes it away after `lifetime`.
    private func follow(lifetime: Duration) async {
        let clock = ContinuousClock()
        let started = clock.now
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var previous: NSRect?
        var steady = 0
        var scrolls = 0
        while !Task.isCancelled, isCurrent {
            if scrolls < Self.scrollAttempts, scrollToSpot() { scrolls += 1 }
            let target = place()
            steady = Self.isSame(target, previous) ? steady + 1 : 0
            previous = target
            if steady >= Self.steadyTicks { break }
            if clock.now - started > Self.patience {
                removeFromSuperview()
                return
            }
            try? await Task.sleep(for: Self.tick)
        }
        let shown = clock.now
        while !Task.isCancelled, isCurrent {
            let elapsed = clock.now - shown
            alphaValue = reducesMotion ? 1 : min(1, elapsed / .seconds(Self.fadeIn))
            place()
            if elapsed >= lifetime { break }
            try? await Task.sleep(for: Self.tick)
        }
        let fading = clock.now
        let faded = alphaValue
        while !Task.isCancelled, isCurrent, !reducesMotion {
            let elapsed = (clock.now - fading) / .seconds(Self.fadeOut)
            if elapsed >= 1 { break }
            alphaValue = faded * (1 - elapsed)
            place()
            try? await Task.sleep(for: Self.tick)
        }
        // A newer request owns the frame now.
        guard !Task.isCancelled else { return }
        removeFromSuperview()
    }

    /// Scrolls the paper towards the spot when it lies out of sight, and reports whether the paper moved.
    private func scrollToSpot() -> Bool {
        guard let paper = superview as? PaperPDFView, let spot, let target = paper.viewRect(for: spot) else {
            return false
        }
        return paper.scrollIntoSight(target)
    }

    /// Lays the frame over the spot and says where that is, or nil while the spot is off the screen.
    @discardableResult
    private func place() -> NSRect? {
        guard let paper = superview as? PaperPDFView, let spot, let target = paper.viewRect(for: spot) else {
            isHidden = true
            return nil
        }
        let visible = target.intersection(paper.bounds)
        guard !visible.isNull, !visible.isEmpty else {
            isHidden = true
            return nil
        }
        isHidden = false
        if frame != visible { frame = visible }
        return visible
    }

    private static func isSame(_ left: NSRect?, _ right: NSRect?) -> Bool {
        guard let left, let right else { return false }
        return abs(left.minX - right.minX) < 0.5 && abs(left.minY - right.minY) < 0.5
            && abs(left.width - right.width) < 0.5 && abs(left.height - right.height) < 0.5
    }
}
