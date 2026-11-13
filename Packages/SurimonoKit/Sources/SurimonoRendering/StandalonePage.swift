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

    public static func copy(of page: PDFPage) -> PDFPage? {
        guard let copy = page.copy() as? PDFPage else { return nil }
        retainSources(of: page, on: copy)
        return copy
    }

    // An annotation's appearance can still refer to the document before the page was redrawn. Keeping only
    // pageRef.document loses that owner on the next copy, so carry the full set through every composition.
    static func retainSources(of source: PDFPage, on target: PDFPage) {
        var documents = objc_getAssociatedObject(target, documentKey) as? [CGPDFDocument] ?? []
        let inherited = objc_getAssociatedObject(source, documentKey) as? [CGPDFDocument] ?? []
        for document in inherited + [source.pageRef?.document, target.pageRef?.document].compactMap({ $0 }) {
            if !documents.contains(where: { $0 === document }) { documents.append(document) }
        }
        objc_setAssociatedObject(target, documentKey, documents, .OBJC_ASSOCIATION_RETAIN)
    }

    public static func first(of data: Data) -> PDFPage? {
        guard let document = PDFDocument(data: data) else { return nil }
        return first(of: document)
    }

    public static func first(of document: PDFDocument) -> PDFPage? {
        guard let page = document.page(at: 0) else { return nil }
        retainSources(of: page, on: page)
        return withExtendedLifetime(document) { page }
    }
}
