import ObjectiveC
import PDFKit

/// Keeps the CoreGraphics document behind a page alive for as long as the page lives, when the page leaves the
/// temporary PDFDocument it was drawn into. A PDFPage keeps its CGPDFPage, but not the CGPDFDocument behind it. Once
/// that temporary document was freed, PDFKit's accessibility (VoiceOver, apps that read the screen) read the page's
/// tagged structure through the freed document and crashed inside CoreGraphics; optimized builds crashed every time.
/// The page holds the CGPDFDocument rather than the PDFDocument, which holds its pages and would never be freed.
@MainActor
public enum StandalonePage {
    private static let documentKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    public static func first(of data: Data) -> PDFPage? {
        guard let document = PDFDocument(data: data) else { return nil }
        return first(of: document)
    }

    public static func first(of document: PDFDocument) -> PDFPage? {
        guard let page = document.page(at: 0) else { return nil }
        if let source = page.pageRef?.document {
            objc_setAssociatedObject(page, documentKey, source, .OBJC_ASSOCIATION_RETAIN)
        }
        return withExtendedLifetime(document) { page }
    }
}
