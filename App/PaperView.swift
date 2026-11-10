import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI

/// Lets menus and the overlay drive the paper view of one window.
final class PaperController {
    fileprivate weak var view: PaperPDFView?
    var onToast: ((Toast) -> Void)?

    func zoomIn() { view?.stepZoom(up: true) }
    func zoomOut() { view?.stepZoom(up: false) }
    func zoomToFit() { view?.setZoom(1, anchor: nil) }
    func turnPage(forward: Bool) { view?.turnPage(forward: forward) }
    /// Whether a paper view is on screen to receive turns (observed by tests).
    var isConnected: Bool { view != nil }
    func goToPage(index: Int, in document: PDFDocument? = nil) { view?.goToPage(index: index, in: document) }
    func focus() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }
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
    /// A spread that shows its cover alone shows it one page wide (`LoneCoverWidth.onePage`).
    var narrowsLoneCover = false
    var keepsSpotInPage = false
    let controller: PaperController
    var onZoomChange: (Double) -> Void
    var onPageChange: (Int) -> Void
    var onTurn: () -> Void
    /// Returns true when the overlay handled the key (menu keys such as Tab, M, V and Esc).
    var onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> PaperPDFView {
        let view = PaperPDFView()
        controller.view = view
        view.onToast = controller.onToast
        return view
    }

    func updateNSView(_ view: PaperPDFView, context: Context) {
        controller.view = view
        view.onToast = controller.onToast
        view.onZoomChange = onZoomChange
        view.onPageChange = onPageChange
        view.onTurn = onTurn
        view.onKey = onKey
        view.narrowsLoneCover = narrowsLoneCover
        view.configure(
            document, at: initialPageIndex, options: options, logicalMargin: logicalMargin,
            showsPageNumbers: showsPageNumbers, changeMarks: changeMarks, keepsSpotInPage: keepsSpotInPage)
        view.wheelSensitivity = wheelSensitivity
        view.selectsText = selectsText
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

final class PaperPDFView: PageTextPDFView {
    static let zoomSteps: [Double] = [1, 1.25, 1.5, 2, 3, 4, 6]
    /// Slows page-turn animations down; development screenshots use it to capture a turn halfway.
    static var animationScale: Double = 1
    static var maximumZoom: Double { zoomSteps[zoomSteps.count - 1] }

    var onZoomChange: ((Double) -> Void)?
    var onPageChange: ((Int) -> Void)?
    var onTurn: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onToast: ((Toast) -> Void)?
    // PDFView inherits delegate-shaped methods that forward to its delegate, so delegating to self recurses on zoom.
    private let linkDelegate = LinkDelegate()

    private final class LinkDelegate: NSObject, PDFViewDelegate {
        weak var view: PaperPDFView?

        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            // Only URL actions come here; PDFKit still handles destinations inside this document.
            Task { @MainActor [weak view] in
                await PaperLinkHandler().open(url) { [weak view] toast in view?.onToast?(toast) }
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
        let document: PDFDocument
    }
    private var shownDocuments: [ShownDocument] = []
    private var logicalMargin: CGFloat?
    private var showsPageNumbers = false
    private var changeMarks: [ChangeMark] = []
    private var drawnChangeMarks: [ChangeMark] = []
    private var isUpdatingDocument = false
    private var isSwitchingSpreadMode = false
    var narrowsLoneCover = false {
        didSet {
            guard narrowsLoneCover != oldValue, document != nil else { return }
            goToPage(index: currentPageIndex)
        }
    }

    func configure(
        _ source: PDFDocument, at index: Int, options: ViewOptions, logicalMargin: CGFloat?, showsPageNumbers: Bool,
        changeMarks: [ChangeMark] = [], keepsSpotInPage: Bool = false
    ) {
        guard
            sourceDocument !== source || self.options != options || self.logicalMargin != logicalMargin
                || self.showsPageNumbers != showsPageNumbers || self.changeMarks != changeMarks
        else { return }
        let point = keepsSpotInPage && sourceDocument !== source ? currentDestination?.point : nil
        let position = sourceDocument === source ? currentPageIndex : index
        isUpdatingDocument = true
        self.logicalMargin = logicalMargin
        self.showsPageNumbers = showsPageNumbers
        self.changeMarks = changeMarks
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

    isolated deinit {
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        zoomDisplayLink?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMagnifyMonitor()
        updateWheelMonitor()
        if window == nil {
            stopZoomReturn()
            if displayedZoom < 1 { setZoom(1, anchor: nil) }
            pinchActive = false
        }
        // Arrow keys and the menu keys should work as soon as the window opens, without clicking the paper first.
        Task { @MainActor [weak self] in
            guard let self, let window, window.firstResponder === window || window.firstResponder == nil else { return }
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
        let plan = ViewPageLayout(
            pageCount: source.pageCount, options: effectiveOptions, hasLogicalMargins: logicalMargin != nil,
            showsNumbers: showsPageNumbers, pageSizes: sizes)
        let key = plan.documentKey(margin: Double(logicalMargin ?? 0))
        if sourceDocument === source, documentKey == key, drawnChangeMarks == changeMarks, document != nil {
            // Layout and navigation may change without touching page content or losing the PDFKit page cache.
            pagePlan = plan
            hideScrollersAndInsets()
            refit()
            goToPage(index: min(index, max(source.pageCount - 1, 0)))
            return
        }
        sourceDocument = source
        let copy: PDFDocument?
        if key.requiresCopy || !changeMarks.isEmpty {
            if let shown = shownDocuments.first(where: {
                $0.source === source && $0.key == key && $0.marks == changeMarks
            }) {
                copy = shown.document
            } else {
                copy = ViewPageDocument.make(source, plan: plan, margin: logicalMargin ?? 0, changeMarks: changeMarks)
            }
        } else {
            copy = source
        }
        drawnChangeMarks = changeMarks
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
                    document: document))
        }
        self.document = document
        displayBox = .cropBox
        hideScrollersAndInsets()
        refit()
        goToPage(index: min(index, max(source.pageCount - 1, 0)))
    }

    func apply(_ options: ViewOptions) {
        guard options != self.options else { return }
        if let sourceDocument {
            configure(
                sourceDocument, at: currentPageIndex, options: options, logicalMargin: logicalMargin,
                showsPageNumbers: showsPageNumbers)
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
        guard window != nil else {
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

    override func go(to page: PDFPage) {
        super.go(to: page)
        alignHorizontalScroll(to: page)
    }

    override func go(to destination: PDFDestination) {
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
            guard let filter = CIFilter(name: "CIPageCurlTransition") else {
                transition.type = .fade
                break
            }
            filter.setDefaults()
            filter.setValue(forward == nextFromRight ? Double.pi : 0, forKey: kCIInputAngleKey)
            transition.filter = filter
            transition.duration = 0.45 * Self.animationScale
        }
        layer.add(transition, forKey: "pageTurn")
    }

    // MARK: - Events

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    private func updateWheelMonitor() {
        guard window != nil else {
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
        if !handleWheelEvent(event) { super.scrollWheel(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        guard let options else {
            super.keyDown(with: event)
            return
        }
        let rightToLeft = options.direction == .rightToLeft
        switch event.specialKey {
        case .leftArrow?: turnPage(forward: rightToLeft)
        case .rightArrow?: turnPage(forward: !rightToLeft)
        case .upArrow?, .downArrow?:
            if options.isContinuous || isZoomed {
                super.keyDown(with: event)
            } else {
                turnPage(forward: event.specialKey == .downArrow)
            }
        default:
            if event.charactersIgnoringModifiers == " ", !options.isContinuous, !isZoomed {
                turnPage(forward: !event.modifierFlags.contains(.shift))
            } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "=" {
                // ⌘= is the unshifted Zoom In key on US keyboards; the menu item shows ⌘+.
                stepZoom(up: true)
            } else {
                super.keyDown(with: event)
            }
        }
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragSelectsText = selectsText(for: event)
        if dragSelectsText {
            // PDFKit selects by drag, words by double-click and lines by triple-click; no page turns or zoom here. It
            // tracks the drag in a loop of its own and returns when the button goes up.
            mouseDownEvent = nil
            super.mouseDown(with: Self.withoutOption(event))
            return
        }
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
        guard mouseDownEvent != nil, !didDrag, let options, !options.isContinuous, !isZoomed else { return }
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

    // MARK: - Cursor

    /// PDFKit shows an I-beam over text; without the selection mode a drag moves the window, so the paper shows the
    /// arrow instead, or the open hand while a drag pans the zoomed paper.
    private var paperCursor: NSCursor { isZoomed ? .openHand : .arrow }

    override func mouseMoved(with event: NSEvent) {
        if selectsText(for: event) { super.mouseMoved(with: event) } else { paperCursor.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        if selectsText(for: event) { super.cursorUpdate(with: event) } else { paperCursor.set() }
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
        if selectsText != modifierFlags.contains(.option) {
            setCursorFor(areaOfInterest(for: point))
        } else {
            paperCursor.set()
        }
    }

    override func selectAll(_ sender: Any?) {
        // Select All would highlight every word while a drag still moves the window.
        guard selectsText else { return }
        super.selectAll(sender)
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

    static func == (left: Self, right: Self) -> Bool {
        left.pageIndex == right.pageIndex && left.anchor == right.anchor && left.document === right.document
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
        return convert(PrintIssue.spotFrame(around: anchor, in: page.bounds(for: .cropBox)), from: page)
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
        layer?.cornerRadius = 4
        layer?.backgroundColor = indigo.withAlphaComponent(0.08).cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
