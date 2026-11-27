import ObjectiveC
import PDFKit

@MainActor
extension PDFDocument {
    enum BinderNavigation {
        case bound(ReadingPDFNavigation.PageLinks)
        case displayFallback
    }

    private static var binderNavigationKey: UInt8 = 0

    /// Travels with the document consumed by both reading export entry points.
    var binderNavigation: BinderNavigation? {
        get { objc_getAssociatedObject(self, &Self.binderNavigationKey) as? BinderNavigation }
        set { objc_setAssociatedObject(self, &Self.binderNavigationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var boundLinkRecords: ReadingPDFNavigation.PageLinks {
        if case .bound(let records) = binderNavigation { return records }
        return [:]
    }

    /// Page indices can change in derived documents. Only the display restriction transfers verbatim.
    func inheritDisplayFallback(from source: PDFDocument) {
        if case .displayFallback = source.binderNavigation { binderNavigation = .displayFallback }
    }

    private final class RetainedPages {
        var pages: [ObjectIdentifier: PDFPage] = [:]
    }
    private static var retainedPagesKey: UInt8 = 0

    /// A document loaded from bytes can discard and recreate its PDFPage wrappers.
    /// Keep the wrapper when a destination or an annotation source depends on its identity.
    func retainPage(_ page: PDFPage) {
        let retained: RetainedPages
        if let existing = objc_getAssociatedObject(self, &Self.retainedPagesKey) as? RetainedPages {
            retained = existing
        } else {
            retained = RetainedPages()
            objc_setAssociatedObject(self, &Self.retainedPagesKey, retained, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        retained.pages[ObjectIdentifier(page)] = page
    }

    /// PDFDestination.page is weak. Keeping its target on the annotation would form a cycle for self-links.
    func destination(on page: PDFPage, at point: CGPoint) -> PDFDestination {
        retainPage(page)
        return PDFDestination(page: page, at: point)
    }
}
