import OSLog
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

    /// Sequoia can return a PDFSelection with no pages for a range on a page inserted into an
    /// in-memory document. Reopen the finished page tree once, after all links and boxes are installed.
    static func selectableDocument(_ assembled: PDFDocument) -> PDFDocument? {
        if #available(macOS 26, *) { return assembled }
        return reopened(assembled, from: assembled.dataRepresentation())
    }

    static func binderForDisplay(_ assembled: PDFDocument, boundLinks: ReadingPDFNavigation.PageLinks) async throws
        -> PDFDocument
    {
        if assembled.binderNavigation == nil, !boundLinks.isEmpty {
            assembled.binderNavigation = .bound(boundLinks)
        }
        // XYZ can be installed in memory. PDFKit cannot author a Fit view from a point and zoom.
        if #available(macOS 26, *) {
            let needsFitView = assembled.boundLinkRecords.values.contains { links in
                links.values.contains { $0.action.target?.mode != "XYZ" }
            }
            if !needsFitView { return assembled }
        }
        return try await reopenBinder(assembled)
    }

    static func reopenBinder(_ assembled: PDFDocument) async throws -> PDFDocument {
        // PDFKit can move a copied page's origin without adjusting the coordinates of links into it.
        do {
            let data = try await ReadingPDFExporter.data(from: assembled)
            if let copy = reopened(assembled, from: data) { return copy }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Display can still use PDFKit's native result when unrelated navigation is unreadable.
        }
        try Task.checkCancellation()
        Logger(subsystem: "app.surimono.Surimono", category: "Binder")
            .warning("Navigation verification failed while reopening a binder for display. Using the native PDF.")
        let display: PDFDocument
        if let copy = reopened(assembled, from: assembled.dataRepresentation()) {
            display = copy
        } else if #available(macOS 26, *) {
            display = assembled
        } else {
            throw DocumentRenderer.RenderingError.invalidPDF
        }
        display.binderNavigation = .displayFallback
        return display
    }

    private static func reopened(_ assembled: PDFDocument, from data: Data?) -> PDFDocument? {
        guard let data, let copy = PDFDocument(data: data), copy.pageCount == assembled.pageCount else { return nil }
        copy.inheritDisplayFallback(from: assembled)
        SourcePaperText.include(assembled, in: copy, startingAt: 0)
        return copy
    }

    public static func copy(of page: PDFPage) -> PDFPage? {
        if !page.annotations.isEmpty || hasStoredAnnotations(page) {
            return independentCopy(of: page)
        }
        guard let copy = page.copy() as? PDFPage else { return nil }
        retainSources(of: page, on: copy)
        return copy
    }

    static func hasStoredAnnotations(_ page: PDFPage) -> Bool {
        guard let dict = page.pageRef?.dictionary else { return false }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, "Annots", &array), let array else { return false }
        return CGPDFArrayGetCount(array) > 0
    }

    // Never edit a native page copy's annotations: its /Annots can still belong to the source.
    // A single-page serialization can move the media origin. Callers rebind internal targets
    // on their completed page tree; preserve live annotations if the native write omitted any.
    static func independentCopy(of page: PDFPage) -> PDFPage? {
        guard let data = page.dataRepresentation, let copy = first(of: data) else { return nil }
        retainSources(of: page, on: copy)
        let annotations = page.annotations
        if copy.annotations.count != annotations.count {
            let before = page.bounds(for: .mediaBox).origin
            let after = copy.bounds(for: .mediaBox).origin
            for old in copy.annotations { copy.removeAnnotation(old) }
            for original in annotations {
                guard let annotation = original.copy() as? PDFAnnotation else { return nil }
                annotation.bounds = original.bounds.offsetBy(dx: after.x - before.x, dy: after.y - before.y)
                copy.addAnnotation(annotation)
            }
        }
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
