import PDFKit
import WebKit

@MainActor
enum VerticalPaginator {
    private static let measurement = Bundle.module.url(forResource: "vertical-lines", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The optional sample position is an x coordinate in the prepared strip, measured after the theme took effect.
    /// Only that page needs a PDF capture in the palette.
    static func pages(
        in webView: WKWebView, pageSize: CGSize, margins: WebPaginator.Margins, timeout: Duration,
        samplePosition: (@MainActor () async throws -> CGFloat?)? = nil
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        guard PDFDrawing.validGeometry(pageSize: pageSize, margins: margins), let measurement else {
            throw WebPaginator.PaginationError.printFailed
        }
        // A PDF capture is in screen coordinates. 96 CSS pixels occupy 72 physical points on the logical paper.
        let pixelsPerPoint = 96.0 / 72
        let width = (pageSize.width - margins.left - margins.right) * pixelsPerPoint
        let height = (pageSize.height - margins.top - margins.bottom) * pixelsPerPoint
        var result: Result<PDFDocument, any Error>?
        let capture = Task { @MainActor in
            do {
                let slices = try await measure(in: webView, script: measurement, width: width, height: height)
                try Task.checkCancellation()
                var indices = slices.indices
                if let samplePosition, !indices.isEmpty {
                    let position = try await samplePosition()
                    let index = position.flatMap { x in slices.firstIndex { $0.end >= -x } } ?? indices.startIndex
                    indices = index..<(index + 1)
                }
                if slices.count > 1 {
                    _ = try await webView.callAsyncJavaScript(
                        "surimonoIndexSlices(cuts)", arguments: ["cuts": slices.map(\.end)], in: nil,
                        contentWorld: WebPaginator.preparationWorld)
                }
                let document = try await PDFDrawing.document(pageSize: pageSize) { context in
                    if slices.isEmpty {
                        context.beginPDFPage(nil)
                        context.endPDFPage()
                    }
                    for index in indices {
                        let slice = slices[index]
                        try Task.checkCancellation()
                        if slices.count > 1 {
                            _ = try await webView.callAsyncJavaScript(
                                "surimonoCaptureSlice(index)", arguments: ["index": index], in: nil,
                                contentWorld: WebPaginator.preparationWorld)
                        }
                        let rect = CGRect(x: -slice.end, y: 0, width: slice.end - slice.start, height: ceil(height))
                        let scale = min(1, width / rect.width) / pixelsPerPoint
                        let target = CGRect(
                            x: pageSize.width - margins.right - rect.width * scale,
                            y: pageSize.height - margins.top - rect.height * scale,
                            width: rect.width * scale, height: rect.height * scale)
                        context.beginPDFPage(nil)
                        defer { context.endPDFPage() }
                        try await FlowPageCapture.draw(rect, from: webView, into: target, in: context)
                    }
                }
                result = .success(document)
            } catch {
                result = .failure(error)
            }
        }
        // WebKit's async capture has no cancellation API. Release the owning session promptly, and never start
        // another slice or publish a partial PDF if an outstanding callback arrives after the deadline.
        defer { capture.cancel() }
        try await WebPaginator.waitUntil(timeout: timeout) { result != nil }
        try Task.checkCancellation()
        guard let result else { throw WebPaginator.PaginationError.printFailed }
        return try result.get()
    }

    private static func measure(in webView: WKWebView, script: String, width: CGFloat, height: CGFloat) async throws
        -> [FlowPageCuts.Band]
    {
        let value = try await webView.callAsyncJavaScript(
            script, arguments: ["width": width, "height": height], in: nil, contentWorld: WebPaginator.preparationWorld)
        try Task.checkCancellation()
        guard let json = value as? String else { throw WebPaginator.PaginationError.printFailed }
        return try await cuts(from: json, capacity: width)
    }

    @concurrent private static func cuts(from json: String, capacity: CGFloat) async throws -> [FlowPageCuts.Band] {
        let fragments = try JSONDecoder().decode([FlowPageCuts.Band].self, from: Data(json.utf8))
        try Task.checkCancellation()
        return FlowPageCuts.pages(for: fragments, capacity: capacity)
    }
}

/// Each capture goes into an open logical page. A different flow can place several slices in distinct columns.
@MainActor
enum FlowPageCapture {
    static func draw(
        _ rect: CGRect, from webView: WKWebView, into target: CGRect, in context: CGContext, transparent: Bool = false,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        let config = WKPDFConfiguration()
        config.rect = rect
        config.allowTransparentBackground = transparent
        let data: Data
        if let deadline {
            data = try await webView.pdfForPrinting(configuration: config, until: deadline)
        } else {
            data = try await webView.pdf(configuration: config)
        }
        try Task.checkCancellation()
        try draw(data, into: target, in: context)
    }

    static func draw(_ data: Data, into target: CGRect, in context: CGContext) throws {
        guard let source = PDFDocument(data: data), source.pageCount == 1, let page = source.page(at: 0),
            let ref = page.pageRef
        else { throw WebPaginator.PaginationError.printFailed }
        let box = ref.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { throw WebPaginator.PaginationError.emptyDocument }
        let transform = CGAffineTransform(translationX: target.minX, y: target.minY)
            .scaledBy(x: target.width / box.width, y: target.height / box.height)
            .translatedBy(x: -box.minX, y: -box.minY)
        context.saveGState()
        context.clip(to: target)
        context.concatenate(transform)
        context.drawPDFPage(ref)
        context.restoreGState()
        for annotation in page.annotations {
            if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
                let area = annotation.bounds.intersection(box)
                if !area.isEmpty { context.setURL(url as CFURL, for: area.applying(transform)) }
            }
        }
    }
}
