import CoreGraphics
import Foundation
import SurimonoCore
import WebKit

/// Draws an SVG file as vector ink for an image page. ImageIO cannot decode SVG, so WebKit draws it, as an `<img>`:
/// an SVG loaded as an image runs no script and loads nothing outside itself, which is how an image file should print.
@MainActor
enum SVGImageDrawing {
    /// The whole of one SVG image, from reading its root to taking the PDF.
    static let timeout: Duration = .seconds(15)

    /// A one-page PDF of the SVG drawn at `size` CSS pixels (one PDF point each), finished before `deadline`.
    static func document(_ data: Data, size: CGSize, until deadline: ContinuousClock.Instant) async throws
        -> CGPDFDocument
    {
        guard data.count <= SVGIntrinsicSize.maximumBytes, SVGIntrinsicSize.usable(size),
            ContinuousClock.now < deadline
        else { throw ImagePageRenderer.RenderingError.invalidImage }
        try Task.checkCancellation()
        let width = max(1, size.width)
        let height = max(1, size.height)
        let html = """
            <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'">
            <style>*{margin:0}img{display:block;width:\(width)px;height:\(height)px}</style>
            <img src="data:image/svg+xml;base64,\(data.base64EncodedString())" alt="">
            """
        let source = WebPaginator.Source.html(html, baseURL: nil)
        let session = PaginationSession(
            source: source, pageSize: CGSize(width: width, height: height), margins: .uniform(millimeters: 0),
            allowsJavaScript: false, printsBackgrounds: true, printTimeout: timeout, onPrintStart: { _ in },
            onPrintFinish: {}, onClose: {})
        defer { session.requestClose() }
        do {
            try session.load(source)
            try await WebPaginator.waitUntil(timeout: ContinuousClock.now.duration(to: deadline)) {
                session.navigationState != .loading || session.terminationError != nil
            }
            guard session.terminationError == nil, session.navigationState == .finished,
                try await session.webView.evaluateForPrinting(
                    "const image = document.images[0]; await image.decode(); return true;", until: deadline)
                    as? Bool == true
            else { throw ImagePageRenderer.RenderingError.invalidImage }
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
            let pdf = try await session.webView.pdfForPrinting(configuration: configuration, until: deadline)
            guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider),
                document.numberOfPages > 0
            else { throw ImagePageRenderer.RenderingError.invalidImage }
            return document
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // A file WebKit cannot decode, a lost web process and a deadline all leave the image unreadable.
            throw ImagePageRenderer.RenderingError.invalidImage
        }
    }
}
