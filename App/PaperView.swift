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
    func goToPage(index: Int) { view?.goToPage(index: index) }
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
        view.configure(
            document, at: initialPageIndex, options: options, logicalMargin: logicalMargin,
            showsPageNumbers: showsPageNumbers, changeMarks: changeMarks)
        view.wheelSensitivity = wheelSensitivity
        view.selectsText = selectsText
        if abs(view.zoom - zoom) > 0.001 { view.setZoom(zoom, anchor: nil) }
    }
}

final class PaperPDFView: PDFView {
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
    /// unretained references to the pages they describe and are asked about them long after the document is replaced
    /// (VoiceOver, apps that read the screen); freeing those pages crashed inside PDFKit. Dropping even the oldest of
    /// sixteen still crashed, so there is no limit. View copies are reused for the same source, layout and marks, so
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

    func configure(
        _ source: PDFDocument, at index: Int, options: ViewOptions, logicalMargin: CGFloat?, showsPageNumbers: Bool,
        changeMarks: [ChangeMark] = []
    ) {
        guard
            sourceDocument !== source || self.options != options || self.logicalMargin != logicalMargin
                || self.showsPageNumbers != showsPageNumbers || self.changeMarks != changeMarks
        else { return }
        let position = sourceDocument === source ? currentPageIndex : index
        isUpdatingDocument = true
        self.logicalMargin = logicalMargin
        self.showsPageNumbers = showsPageNumbers
        self.changeMarks = changeMarks
        self.options = options
        configureDisplay(options)
        show(source, at: position)
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
        let plan = ViewPageLayout(
            pageCount: source.pageCount, options: effectiveOptions, hasLogicalMargins: logicalMargin != nil,
            showsNumbers: showsPageNumbers)
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
        pageSize = (0..<document.pageCount).reduce(into: CGSize.zero) { size, index in
            guard let page = document.page(at: index) else { return }
            let bounds = page.bounds(for: .cropBox)
            let pageSize =
                page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
            size = CGSize(width: max(size.width, pageSize.width), height: max(size.height, pageSize.height))
        }
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

    private var fitScale: CGFloat {
        let unit = unitSize
        guard unit.width > 0, unit.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / unit.width, bounds.height / unit.height)
    }

    override func layout() {
        super.layout()
        hideScrollersAndInsets()
        // Fit again when the window changes size; the zoom the user chose is relative to the fit.
        if bounds.size != fittedSize { refit() }
    }

    /// The paper is the window: legacy scroll bars would narrow it, and scrolling still works without them. PDFKit
    /// adds them again when the document or the display mode changes, so this runs after those too.
    private func hideScrollersAndInsets() {
        guard let scrollView = documentView?.enclosingScrollView else { return }
        if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
        if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
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
        guard bounds.width > 1, bounds.height > 1 else { return }
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
        guard !isMeasuringFit, !isUpdatingDocument else { return }
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
        let anchorInDocument = documentView.convert(anchorInView, from: self)
        let anchorInClip = clip.convert(anchorInView, from: self)
        let oldScale = scaleFactor
        refit()
        let ratio = scaleFactor / max(oldScale, 0.0001)
        let origin = NSPoint(
            x: anchorInDocument.x * ratio - (anchorInClip.x - clip.bounds.minX),
            y: anchorInDocument.y * ratio - (anchorInClip.y - clip.bounds.minY))
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

    func goToPage(index: Int) {
        guard let document, let pagePlan, let requested = pagePlan.viewIndex(for: index),
            let first = pagePlan.readingIndex(at: requested), let viewIndex = pagePlan.viewIndex(for: first),
            let page = document.page(at: viewIndex)
        else { return }
        finishZoomReturnForNavigation()
        go(to: page)
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
        origin.x -= event.deltaX
        origin.y += clip.isFlipped ? -event.deltaY : event.deltaY
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
