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

    private final class DestinationPages {
        var pages: [ObjectIdentifier: PDFPage] = [:]
    }
    private static var destinationPagesKey: UInt8 = 0

    /// PDFDestination.page is weak. A document loaded from bytes can discard and recreate
    /// its PDFPage wrappers before a link is followed or serialized. The owner must keep
    /// each target; keeping it on the annotation instead would form a cycle for self-links.
    func destination(on page: PDFPage, at point: CGPoint) -> PDFDestination {
        let targets: DestinationPages
        if let existing = objc_getAssociatedObject(self, &Self.destinationPagesKey) as? DestinationPages {
            targets = existing
        } else {
            targets = DestinationPages()
            objc_setAssociatedObject(self, &Self.destinationPagesKey, targets, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        targets.pages[ObjectIdentifier(page)] = page
        return PDFDestination(page: page, at: point)
    }
}
