import CoreGraphics
import PDFKit

public struct PDFViewerHints: Equatable, Sendable {
    public var pageLayout: String?
    public var direction: String?

    public init(pageLayout: String? = nil, direction: String? = nil) {
        self.pageLayout = pageLayout
        self.direction = direction
    }

    /// Reads the document catalog through CoreGraphics (`documentRef` and `CGPDFDocumentGetCatalog`).
    @MainActor
    public static func read(from document: PDFDocument) -> PDFViewerHints {
        guard let reference = document.documentRef, let catalog = reference.catalog else { return PDFViewerHints() }
        var preferences: CGPDFDictionaryRef?
        let direction: String?
        if CGPDFDictionaryGetDictionary(catalog, "ViewerPreferences", &preferences), let preferences {
            direction = name(in: preferences, key: "Direction")
        } else {
            direction = nil
        }
        return PDFViewerHints(pageLayout: name(in: catalog, key: "PageLayout"), direction: direction)
    }

    private static func name(in dictionary: CGPDFDictionaryRef, key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}
