import ObjectiveC
import PDFKit

@MainActor
extension PDFDocument {
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
