import AppKit
import ObjectiveC
import PDFKit

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
    override var document: PDFDocument? {
        didSet { discardReplacedElements() }
    }

    private func discardReplacedElements() {
        guard elementsDocument !== document || (document == nil && !elements.isEmpty) else { return }
        for element in elements.values { element.position.anchor = nil }
        elements.removeAll()
        elementsDocument = document
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
            axProbeToken = token
            setAccessibilityIdentifier(token + ".paper")
            for element in elements.values {
                element.setAccessibilityIdentifier(token + ".page." + String(element.index))
            }
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

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityChildren() -> [Any]? { visibleElements }

    // AppKit asks these on the main thread, though NSObject declares them outside the main actor.
    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        nonisolated(unsafe) var element: Any?
        MainActor.assumeIsolated { element = visibleElements.first { $0.accessibilityFrame().contains(point) } }
        return element ?? self
    }

    nonisolated override var accessibilityFocusedUIElement: Any? { self }

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

    private var visibleElements: [PageTextElement] {
        discardReplacedElements()
        guard let document else { return [] }
        return visiblePages.map { page in
            if let element = elements[ObjectIdentifier(page)] { return element }
            #if DEBUG
                let start = ProcessInfo.processInfo.systemUptime
            #endif
            let element = PageTextElement(page: page, index: document.index(for: page), parent: self)
            #if DEBUG
                if ShownDocumentsProbe.measuresElements {
                    ShownDocumentsProbe.extractedCount += 1
                    ShownDocumentsProbe.extractionSeconds += ProcessInfo.processInfo.systemUptime - start
                    ShownDocumentsProbe.elements.add(element)
                }
                if let token = axProbeToken {
                    element.setAccessibilityIdentifier(token + ".page." + String(element.index))
                }
            #endif
            position(element, on: page)
            elements[ObjectIdentifier(page)] = element
            return element
        }
    }

    // Scroll and window movement are handled by AppKit's coordinate conversion. Only a changed PDF layout needs
    // a new page transform; a late AX request must never ask PDFKit to locate an outgoing page.
    private func observePageLayout() {
        for name: Notification.Name in [
            .PDFViewScaleChanged, .PDFViewDisplayModeChanged, .PDFViewDisplayBoxChanged, .PDFViewPageChanged,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(refreshElementPositions(_:)), name: name, object: self)
        }
    }

    private var isPositioningElements = false

    @objc private func refreshElementPositions(_ notification: Notification? = nil) {
        guard !elements.isEmpty, !isPositioningElements else { return }
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
