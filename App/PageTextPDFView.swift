import AppKit
import ObjectiveC
import PDFKit
import Synchronization

/// A PDFView that shows screen readers its pages' text through elements of its own, in place of PDFKit's.
///
/// PDFKit's accessibility nodes read a page's tagged structure through an unretained pointer to the CGPDFPage, and an
/// app reading the screen can hold on to a node for as long as it likes. Once the page was freed (a paper thrown away
/// on the way to the print tray, a closed window), asking such a node for its text crashed inside CoreGraphics. Keeping
/// documents alive only moved the crash, because nothing tells when the last reader lets go, so the nodes are not
/// handed out at all. Each published element owns the text and character bounds it may be asked for later.
class PageTextPDFView: PDFView {
    private var elements: [ObjectIdentifier: PageTextElement] = [:]
    private weak var elementsDocument: PDFDocument?
    // AppKit can ask for the focused AX element on a background queue while the main thread is closing the window.
    private let retired = Atomic(false)
    nonisolated var isRetired: Bool { retired.load(ordering: .relaxed) }

    func retire() {
        guard !isRetired else { return }
        retired.store(true, ordering: .relaxed)
        clearElements()
        elementsDocument = nil
        NSAccessibility.post(element: self, notification: .uiElementDestroyed)
    }

    private func discardReplacedElements() {
        guard elementsDocument !== document || (document == nil && !elements.isEmpty) else { return }
        elementsDocument = document
        clearElements()
    }

    private func clearElements() {
        let discarded = elements.values
        elements.removeAll()
        // A reader can still have the previous leaf when it asks for its parent or frame again.
        for element in discarded {
            element.position.anchor = nil
            element.setAccessibilityParent(nil)
            NSAccessibility.post(element: element, notification: .uiElementDestroyed)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observePageLayout()
        #if DEBUG
            stopPageAnalysisInTests()
        #endif
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observePageLayout()
    }

    #if DEBUG
        private var axProbeToken: String?

        func identifyProbePaper(_ token: String) {
            guard axProbeToken != token else { return }
            axProbeToken = token
            setAccessibilityIdentifier(token + ".paper")
            // A page published before the reader started still has the ordinary accessibility contract.
            clearElements()
        }

        /// PDFKit hands every page it shows to Vision. Tests show the pages of far more documents than a reader does,
        /// and on a CI runner the waiting work took all of dispatch's threads: the recent documents, which the main
        /// thread waits for, then never ran and the test host hung. The switch is private, so only tests use it.
        private func stopPageAnalysisInTests() {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
                responds(to: NSSelectorFromString("setDocumentAnalysisEnabled:"))
            else { return }
            setValue(false, forKey: "documentAnalysisEnabled")
        }
    #endif

    nonisolated override func isAccessibilityElement() -> Bool { !isRetired }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    nonisolated override func accessibilityLabel() -> String? { String(localized: "Paper") }

    override func accessibilityChildren() -> [Any]? { visibleElements }

    // The synchronous main-thread read finishes before this local result crosses back to its caller.
    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        nonisolated(unsafe) var element: Any?
        onPaperAccessibilityMain {
            if !isRetired { element = visibleElements.first { $0.accessibilityFrame().contains(point) } ?? self }
        }
        return element
    }

    nonisolated override var accessibilityFocusedUIElement: Any? { isRetired ? nil : self }

    override func layout() {
        super.layout()
        guard let documentView, let scrollView = documentView.enclosingScrollView else { return }
        Self.closeNodes(documentView: type(of: documentView), scrollView: type(of: scrollView))
        refreshElementPositions()
    }

    /// PDFKit's document view hands out the nodes, and it is the first responder once the paper was clicked, so the
    /// focused element leads to it. It ignores `setAccessibilityElement(_:)` and is a private class, so the answers are
    /// replaced: neither view counts as an element, which sends the focus up to this view, and the scroll view, the way
    /// from there to the document view, has no children. The document view keeps its own children, because PDFKit
    /// reads them itself: with none, the test host stopped being able to quit.
    private static func closeNodes(documentView: AnyClass, scrollView: AnyClass) {
        guard !closedClasses.contains(ObjectIdentifier(documentView)) else { return }
        closedClasses.insert(ObjectIdentifier(documentView))
        let isElement: @convention(block) (AnyObject) -> Bool = { _ in false }
        let children: @convention(block) (AnyObject) -> NSArray = { _ in [] }
        let answers: [(AnyClass, Selector, AnyObject)] = [
            (documentView, #selector(NSView.isAccessibilityElement), unsafeBitCast(isElement, to: AnyObject.self)),
            (scrollView, #selector(NSView.isAccessibilityElement), unsafeBitCast(isElement, to: AnyObject.self)),
            (scrollView, #selector(NSView.accessibilityChildren), unsafeBitCast(children, to: AnyObject.self)),
        ]
        for (target, selector, answer): (AnyClass, Selector, AnyObject) in answers {
            guard let method = class_getInstanceMethod(target, selector) else { continue }
            class_replaceMethod(target, selector, imp_implementationWithBlock(answer), method_getTypeEncoding(method))
        }
    }

    private static var closedClasses: Set<ObjectIdentifier> = []

    func characterSelectionBounds(for range: NSRange, on page: PDFPage) -> CGRect? {
        page.selection(for: range)?.bounds(for: page)
    }

    var selectionRetryTime: ContinuousClock.Instant { .now }

    func withSelectionCopy(of page: PDFPage, matching text: NSString, read: (PDFPage) -> Bool) {
        PageTextGeometry.withCopy(of: page, matching: text, read: read)
    }

    private func makeElement(for page: PDFPage, index: Int) -> PageTextElement {
        #if DEBUG
            if let axProbeToken {
                return ProbePageTextElement(page: page, index: index, parent: self, token: axProbeToken)
            }
        #endif
        return PageTextElement(page: page, index: index, parent: self)
    }

    private var visibleElements: [PageTextElement] {
        guard !isRetired else { return [] }
        discardReplacedElements()
        guard let document else { return [] }
        return visiblePages.map { page in
            if let element = elements[ObjectIdentifier(page)] {
                if element.position.anchor == nil { position(element, on: page) }
                return element
            }
            #if DEBUG
                let start = ProcessInfo.processInfo.systemUptime
            #endif
            let element = makeElement(for: page, index: document.index(for: page))
            #if DEBUG
                if ShownDocumentsProbe.measuresElements {
                    ShownDocumentsProbe.extractedCount += 1
                    ShownDocumentsProbe.extractionSeconds += ProcessInfo.processInfo.systemUptime - start
                    ShownDocumentsProbe.elements.add(element)
                }
            #endif
            position(element, on: page)
            elements[ObjectIdentifier(page)] = element
            return element
        }
    }

    // Scroll and window movement are handled by AppKit's coordinate conversion. Only a changed PDF layout needs
    // a new page transform; a late AX request must never ask PDFKit to locate an outgoing page.
    private static let pageLayoutNotifications: [Notification.Name] = [
        .PDFViewDocumentChanged, .PDFViewScaleChanged, .PDFViewDisplayModeChanged, .PDFViewDisplayBoxChanged,
        .PDFViewPageChanged,
    ]

    private func observePageLayout() {
        // PDFKit reads its document getter from its analysis queue. Observe replacements without overriding it.
        for name in Self.pageLayoutNotifications {
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageLayoutChanged(_:)), name: name, object: self)
        }
    }

    func stopObservingPageLayout() {
        // The paper also observes scale and page changes from this same sender.
        for name in Self.pageLayoutNotifications {
            NotificationCenter.default.removeObserver(self, name: name, object: self)
        }
    }

    @objc private nonisolated func pageLayoutChanged(_ notification: Notification) {
        // Invalidate synchronously during a UI replacement. A notification from another queue can use the latest layout.
        if Thread.isMainThread {
            MainActor.assumeIsolated { refreshElementPositions() }
        } else {
            Task { @MainActor [weak self] in self?.refreshElementPositions() }
        }
    }

    private var isPositioningElements = false

    private func refreshElementPositions() {
        guard !elements.isEmpty, !isPositioningElements else { return }
        discardReplacedElements()
        isPositioningElements = true
        defer { isPositioningElements = false }
        for element in elements.values {
            if let page = document?.page(at: element.index) { position(element, on: page) }
        }
    }

    private func position(_ element: PageTextElement, on page: PDFPage) {
        guard let anchor = documentView else {
            element.position.anchor = nil
            return
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            anchor.convert(convert(CGPoint(x: x, y: y), from: page), from: self)
        }
        let origin = point(0, 0)
        let x = point(1, 0)
        let y = point(0, 1)
        element.position.anchor = anchor
        element.position.pageToAnchor = CGAffineTransform(
            a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y,
            tx: origin.x, ty: origin.y)
        element.position.pageBounds = page.bounds(for: displayBox)
    }
}
