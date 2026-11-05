import AppKit
import ObjectiveC
import PDFKit

/// A PDFView that shows screen readers its pages' text through elements of its own, in place of PDFKit's.
///
/// PDFKit's accessibility nodes read a page's tagged structure through an unretained pointer to the CGPDFPage, and an
/// app reading the screen can hold on to a node for as long as it likes. Once the page was freed (a paper thrown away
/// on the way to the print tray, a closed window), asking such a node for its text crashed inside CoreGraphics. Keeping
/// documents alive only moved the crash, because nothing tells when the last reader lets go, so the nodes are not
/// handed out at all. An element here keeps its document, so it stays safe to read however late it is asked.
class PageTextPDFView: PDFView {
    private var elements: [ObjectIdentifier: PageTextElement] = [:]
    private weak var elementsDocument: PDFDocument?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if DEBUG
            stopPageAnalysisInTests()
        #endif
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    #if DEBUG
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
        guard let document else { return [] }
        if elementsDocument !== document {
            elementsDocument = document
            elements = [:]
        }
        return visiblePages.map { page in
            if let element = elements[ObjectIdentifier(page)] { return element }
            let element = PageTextElement(page: page, document: document, view: self)
            elements[ObjectIdentifier(page)] = element
            return element
        }
    }

    /// Where a page of the shown document lies on screen; nothing, once `documentID` is no longer the one shown.
    fileprivate func screenFrame(ofPageAt index: Int, documentID: ObjectIdentifier) -> NSRect {
        guard let document, ObjectIdentifier(document) == documentID, let page = document.page(at: index),
            let window
        else { return .zero }
        return window.convertToScreen(convert(convert(page.bounds(for: displayBox), from: page), to: nil))
    }
}

/// A page's text for screen readers. See `PageTextPDFView`.
nonisolated final class PageTextElement: NSAccessibilityElement {
    private let page: PDFPage
    /// A page does not keep the document behind it, and its text is read through that document.
    private let document: PDFDocument
    private let index: Int
    private weak var view: PageTextPDFView?
    private var text: String { page.string ?? "" }

    init(page: PDFPage, document: PDFDocument, view: PageTextPDFView) {
        self.page = page
        self.document = document
        self.index = document.index(for: page)
        self.view = view
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityParent(view)
        setAccessibilityLabel(String(localized: "Page \(index + 1)"))
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityValue() -> Any? { text }

    override func accessibilityNumberOfCharacters() -> Int { text.utf16.count }

    override func accessibilityFrame() -> NSRect {
        guard let view else { return .zero }
        let (index, documentID) = (index, ObjectIdentifier(document))
        return MainActor.assumeIsolated { view.screenFrame(ofPageAt: index, documentID: documentID) }
    }
}
