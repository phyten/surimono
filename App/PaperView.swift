import AppKit
import PDFKit
import SurimonoCore
import SwiftUI

/// Lets menus and the overlay drive the paper view of one window.
final class PaperController {
    fileprivate weak var view: PaperPDFView?

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
    /// Where a new paper view opens, as on returning from the print mode; afterwards the view keeps its own page.
    let initialPageIndex: Int
    let options: ViewOptions
    let zoom: Double
    let controller: PaperController
    var onZoomChange: (Double) -> Void
    var onPageChange: (Int) -> Void
    var onTurn: () -> Void
    /// Returns true when the overlay handled the key (menu keys such as Tab, M, V and Esc).
    var onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> PaperPDFView {
        let view = PaperPDFView()
        controller.view = view
        return view
    }

    func updateNSView(_ view: PaperPDFView, context: Context) {
        controller.view = view
        view.onZoomChange = onZoomChange
        view.onPageChange = onPageChange
        view.onTurn = onTurn
        view.onKey = onKey
        if view.document !== document {
            view.show(document, at: view.document == nil ? initialPageIndex : view.currentPageIndex)
        }
        view.apply(options)
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
    private(set) var zoom: Double = 1
    private var options: ViewOptions?
    private var pageSize = CGSize(width: 595, height: 842)
    private var fittedSize = CGSize.zero
    private var isSettingScale = false
    private var magnifyMonitor: Any?
    private var wheelDistance: CGFloat = 0
    private var wheelTurnedInGesture = false
    private var lastWheelTurn = Date.distantPast
    private var mouseDownEvent: NSEvent?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMagnifyMonitor()
        // Arrow keys and the menu keys should work as soon as the window opens, without clicking the paper first.
        Task { @MainActor [weak self] in
            guard let self, let window, window.firstResponder === window || window.firstResponder == nil else { return }
            window.makeFirstResponder(self)
        }
    }

    var currentPageIndex: Int {
        guard let document, let page = currentPage else { return 0 }
        return document.index(for: page)
    }

    func show(_ document: PDFDocument, at index: Int) {
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
        goToPage(index: min(index, max(document.pageCount - 1, 0)))
    }

    func apply(_ options: ViewOptions) {
        guard options != self.options else { return }
        let index = currentPageIndex
        self.options = options
        let mode: PDFDisplayMode =
            switch options.layout {
            case .single: options.isContinuous ? .singlePageContinuous : .singlePage
            case .spread: options.isContinuous ? .twoUpContinuous : .twoUp
            }
        if displayMode != mode { displayMode = mode }
        displaysAsBook = options.usesCoverOption && options.showsCoverAlone
        displaysRTL = options.direction == .rightToLeft
        displayDirection = options.scrollAxis == .vertical ? .vertical : .horizontal
        hideScrollersAndInsets()
        refit()
        goToPage(index: index)
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
        let target = max(fitScale * zoom, 0.01)
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
        magnify(by: event.magnification, at: convert(event.locationInWindow, from: nil))
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
        guard event.window === window, isPaper(atWindowPoint: event.locationInWindow) else { return false }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .magnify {
            magnify(by: event.magnification, at: point)
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

    @objc private func scaleDidChange() {
        // PDFKit also rescales on its own, for example when the display mode changes; the zoom stays the user's.
        guard !isSettingScale, fitScale > 0 else { return }
        refit()
    }

    @objc private func pageDidChange() {
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
        let clamped = min(max(value, 1), Self.maximumZoom)
        guard let documentView, let scrollView = documentView.enclosingScrollView else {
            zoom = clamped
            refit()
            return
        }
        let clip = scrollView.contentView
        let anchorInView = anchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let anchorInDocument = documentView.convert(anchorInView, from: self)
        let anchorInClip = clip.convert(anchorInView, from: self)
        let oldScale = scaleFactor
        zoom = clamped
        refit()
        let ratio = scaleFactor / max(oldScale, 0.0001)
        let origin = NSPoint(
            x: anchorInDocument.x * ratio - (anchorInClip.x - clip.bounds.minX),
            y: anchorInDocument.y * ratio - (anchorInClip.y - clip.bounds.minY))
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        onZoomChange?(zoom)
    }

    private var isZoomed: Bool { zoom > 1.001 }

    // MARK: - Turning pages

    func goToPage(index: Int) {
        guard let document, let page = document.page(at: index) else { return }
        go(to: page)
    }

    func turnPage(forward: Bool) {
        guard let options else { return }
        guard forward ? canGoToNextPage : canGoToPreviousPage else { return }
        addTransition(forward: forward, options: options)
        if forward { goToNextPage(nil) } else { goToPreviousPage(nil) }
        onTurn?()
    }

    private func addTransition(forward: Bool, options: ViewOptions) {
        guard !options.isContinuous, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else {
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
        case .slide:
            transition.type = .push
            transition.subtype =
                switch options.slideEdge(forward: forward) {
                case .left: .fromLeft
                case .right: .fromRight
                case .top: .fromTop
                case .bottom: .fromBottom
                }
        case .fade:
            transition.type = .fade
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

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let anchor = convert(event.locationInWindow, from: nil)
            setZoom(zoom * exp(Double(event.scrollingDeltaY) * 0.01), anchor: anchor)
            return
        }
        guard let options, !options.isContinuous, !isZoomed else {
            super.scrollWheel(with: event)
            return
        }
        // Momentum after a turn must not keep turning pages.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) {
            wheelDistance = 0
            wheelTurnedInGesture = false
        }
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        // Content moving left or up reveals the next page of a left-to-right book.
        let forwardSign: CGFloat = horizontal && options.direction == .rightToLeft ? 1 : -1
        wheelDistance += delta * forwardSign
        let isGesture = !event.phase.isEmpty
        let threshold: CGFloat = isGesture ? 36 : 1
        if abs(wheelDistance) >= threshold, !wheelTurnedInGesture,
            isGesture || Date().timeIntervalSince(lastWheelTurn) > 0.25
        {
            turnPage(forward: wheelDistance > 0)
            lastWheelTurn = Date()
            wheelDistance = 0
            wheelTurnedInGesture = isGesture
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            wheelDistance = 0
            wheelTurnedInGesture = false
        }
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            setZoom(isZoomed ? 1 : 2, anchor: convert(event.locationInWindow, from: nil))
            mouseDownEvent = nil
            return
        }
        mouseDownEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
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
}
