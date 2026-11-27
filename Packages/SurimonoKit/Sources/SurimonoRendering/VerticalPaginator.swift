import CoreText
import PDFKit
import SurimonoCore
import WebKit

@MainActor
enum VerticalPaginator {
    private static let measurement = Bundle.module.url(forResource: "vertical-lines", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    // WebKit can report line zero for a native DOM exception. Only include our own
    // stage and operation labels, never the document or a page-provided error message.
    private static func diagnosed(_ script: String, stage: String) -> String {
        """
        const trace = {call: ''};
        try {
            \(script)
        } catch (error) {
            const name = error instanceof DOMException && error.code ? error.name :
                error instanceof TypeError ? 'TypeError' : error instanceof RangeError ? 'RangeError' : 'Error';
            const detail = trace.call ? ' / ' + trace.call : '';
            const reason = error?.message === 'Vertical layout exceeds the fragment limit' ? error.message : name;
            throw new Error('Vertical pagination: \(stage)' + detail + ' (' + reason + ')');
        }
        """
    }

    // Full-width cells include white inside the font. Shape the theme's vertical alternates
    // so the gap is measured between their outlines, including for asymmetric brackets.
    private static let punctuationEdges: [String: Double] = {
        let size: CGFloat = 1000
        let font = CTFontCreateWithName("Hiragino Mincho ProN" as CFString, size, nil)
        var edges: [String: Double] = [:]
        for mark in VerticalText.openingMarks + VerticalText.closingMarks {
            let sample = NSAttributedString(
                string: String(mark), attributes: [.font: font, .verticalGlyphForm: true])
            let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(sample)) as NSArray
            guard let run = (runs as? [CTRun])?.first, CTRunGetGlyphCount(run) == 1,
                let face = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as? NSFont
            else { continue }
            var glyph = CGGlyph()
            CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
            let ink = CTFontGetBoundingRectsForGlyphs(face as CTFont, .vertical, &glyph, nil, 1)
            guard ink.width > 0, ink.minX >= 0, ink.maxX <= size else { continue }
            edges[String(mark)] = (VerticalText.openingMarks.contains(mark) ? ink.minX : ink.maxX) / size
        }
        return edges
    }()

    nonisolated struct Manuscript {
        let rows: Int
        let font: CGFloat
        let textArea: CGSize
    }

    /// All measurements are physical points. Zoom changes how many glyphs fit, while the grid stays on the paper.
    nonisolated struct Frame {
        let rows: Int
        let font: CGFloat
        let width: CGFloat
        let height: CGFloat
        let right: CGFloat
        private let firstTop: CGFloat
        private let gap: CGFloat

        init(pageSize: CGSize, margins: WebPaginator.Margins, textScale: Double, manuscript: Manuscript? = nil) {
            let availableWidth = pageSize.width - margins.left - margins.right
            let availableHeight = pageSize.height - margins.top - margins.bottom
            func matches(_ paper: PaperSize) -> Bool {
                abs(min(pageSize.width, pageSize.height) - paper.size.width) < 0.5
                    && abs(max(pageSize.width, pageSize.height) - paper.size.height) < 0.5
            }
            let a4 = matches(.a4)
            let twoRows = manuscript.map { $0.rows == 2 } ?? a4
            rows = twoRows ? 2 : 1
            font = manuscript?.font ?? 10.5
            let scale = textScale.isFinite && textScale > 0 ? textScale : 1
            // Even extreme custom margins leave each row some printable height.
            let textHeight = min(availableHeight, manuscript?.textArea.height ?? availableHeight)
            gap = twoRows ? min(3 * font * scale, textHeight / 3) : 0
            let maxHeight = (textHeight - gap) / CGFloat(rows)
            let a5 = matches(.a5)
            let usesGrid = a4 || a5
            // Snap in physical points after zoom. If even one cell cannot fit, keep the available
            // length so that extreme reader margins still produce a nonempty capture.
            func fitted(_ available: CGFloat, step: CGFloat) -> CGFloat {
                available >= step ? available - available.truncatingRemainder(dividingBy: step) : available
            }
            let cell = font * scale
            let preferredWidth =
                manuscript?.textArea.width ?? (usesGrid ? font * 1.75 * (a5 ? 18 : 24) : availableWidth)
            let maxWidth = min(availableWidth, preferredWidth)
            let preferredHeight: CGFloat
            if manuscript != nil {
                preferredHeight = maxHeight
            } else if twoRows {
                preferredHeight = 30 * font
            } else if a5 {
                preferredHeight = 42 * font
            } else {
                preferredHeight = maxHeight
            }
            height = fitted(min(maxHeight, preferredHeight), step: cell)
            width = fitted(maxWidth, step: 1.75 * cell)
            right = pageSize.width - margins.right - (availableWidth - width) / 2
            firstTop = pageSize.height - margins.top - (availableHeight - CGFloat(rows) * height - gap) / 2
        }

        func top(of row: Int) -> CGFloat { firstTop - CGFloat(row) * (height + gap) }
    }

    /// The optional sample position is an x coordinate in the prepared strip, measured after the theme took effect.
    /// Only that page needs a PDF capture in the palette. It receives the deadline of the whole call, so that looking
    /// the position up spends what is left of the budget instead of starting one of its own.
    static func pages(
        in webView: WKWebView, pageSize: CGSize, margins: WebPaginator.Margins, timeout: Duration,
        booklet: Bool = false, textScale: Double = 1,
        samplePosition: (@MainActor (ContinuousClock.Instant) async throws -> CGFloat?)? = nil
    ) async throws -> PDFDocument {
        let bytes = try await data(
            in: webView, pageSize: pageSize, margins: margins, timeout: timeout,
            booklet: booklet, textScale: textScale, samplePosition: samplePosition)
        guard let document = PDFDocument(data: bytes), document.pageCount > 0 else {
            throw WebPaginator.PaginationError.emptyDocument
        }
        return document
    }

    static func data(
        in webView: WKWebView, pageSize: CGSize, margins: WebPaginator.Margins, timeout: Duration,
        booklet: Bool = false, textScale: Double = 1,
        samplePosition: (@MainActor (ContinuousClock.Instant) async throws -> CGFloat?)? = nil,
        recordSlice: (@MainActor (Int, PrintedFragmentLinks.VerticalLayout.Slice) -> Void)? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        guard PDFDrawing.validGeometry(pageSize: pageSize, margins: margins), let measurement else {
            throw WebPaginator.PaginationError.printFailed
        }
        // A PDF capture is in screen coordinates. 96 CSS pixels occupy 72 physical points on the logical paper.
        let pixelsPerPoint: CGFloat = 96.0 / 72
        // Each WebKit reply below is awaited only until this deadline, and fails at once when the page's process
        // has ended: awaiting WebKit's own async calls left the capture task (and its session) waiting for good.
        return try await capturedData(timeout: timeout) { deadline in
            let values =
                try await webView.evaluateForPrinting(
                    diagnosed(
                        """
                        const d = document.body.dataset;
                        return d.latexVerticalRows ? [d.latexVerticalRows, d.latexSize, d.latexTextWidth, d.latexTextHeight].map(Number) : null;
                        """, stage: "read manuscript dimensions"), until: deadline) as? [Double]
            let manuscript: Manuscript?
            if let values, values.count == 4, values[1].isFinite, values[1] > 0 {
                // A contradictory geometry override may leave one dimension empty. Keep the
                // declared font and columns and fit that axis to the available paper.
                let textWidth = values[2] > 0 ? values[2] : pageSize.width
                let textHeight = values[3] > 0 ? values[3] : pageSize.height
                manuscript = Manuscript(
                    rows: values[0] == 2 ? 2 : 1, font: values[1],
                    textArea: CGSize(width: textWidth, height: textHeight))
            } else {
                manuscript = nil
            }
            let frame = Frame(pageSize: pageSize, margins: margins, textScale: textScale, manuscript: manuscript)
            let width = frame.width * pixelsPerPoint
            let height = frame.height * pixelsPerPoint
            let (plan, originY) = try await measure(
                in: webView, script: measurement, width: width, height: height, font: frame.font,
                booklet: booklet, rows: frame.rows, until: deadline)
            try Task.checkCancellation()
            let pages = plan.pages
            var selected = pages.startIndex..<pages.endIndex
            if let samplePosition, !pages.isEmpty {
                let position = try await samplePosition(deadline)
                let index =
                    position.flatMap { x in
                        pages.firstIndex { page in
                            guard let last = page.last else { return false }
                            return plan.sources[last.index].end >= -x
                        }
                    } ?? 0
                selected = index..<(index + 1)
            }
            return try await PDFDrawing.data(pageSize: pageSize) { context in
                if pages.isEmpty {
                    context.beginPDFPage(nil)
                    context.endPDFPage()
                }
                // The original header stays selectable. Repeated furniture is ink only, including any links.
                var headerImage: (CGRect, CGImage)?
                @MainActor func repeatedHeader(_ source: CGRect) async throws -> CGImage {
                    if let headerImage, headerImage.0 == source { return headerImage.1 }
                    let config = WKPDFConfiguration()
                    config.rect = source
                    let data = try await webView.pdfForPrinting(configuration: config, until: deadline)
                    guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else {
                        throw WebPaginator.PaginationError.printFailed
                    }
                    let image = try PageImageExporter.image(page, dpi: 288)
                    headerImage = (source, image)
                    return image
                }
                for page in selected {
                    context.beginPDFPage(nil)
                    defer { context.endPDFPage() }
                    for slice in pages[page] {
                        try Task.checkCancellation()
                        if plan.sources.count > 1 {
                            _ = try await webView.evaluateForPrinting(
                                diagnosed("surimonoCaptureSlice(index)", stage: "show source slice \(slice.index)"),
                                arguments: ["index": slice.index], until: deadline)
                        }
                        // Assign rows by their layout width, then keep annotation overhang at its natural scale.
                        let rect = slice.rect.offsetBy(dx: 0, dy: originY)
                        let scale = slice.fit / pixelsPerPoint
                        let target = CGRect(
                            x: frame.right + slice.offset.x / pixelsPerPoint,
                            y: frame.top(of: slice.row) - slice.offset.y / pixelsPerPoint,
                            width: rect.width * scale, height: rect.height * scale)
                        try await FlowPageCapture.draw(
                            rect, from: webView, into: target, in: context, deadline: deadline)
                        recordSlice?(slice.index, .init(source: rect, paper: target, page: page))
                        if let header = slice.header {
                            let image = try await repeatedHeader(header.offsetBy(dx: 0, dy: originY))
                            context.draw(
                                image,
                                in: CGRect(
                                    x: target.minX + (header.minX - rect.minX) * scale, y: target.maxY,
                                    width: header.width * scale, height: header.height * scale))
                        }
                        if let rule = slice.bottomRule, rule.color.count == 4 {
                            context.setFillColor(
                                CGColor(
                                    srgbRed: rule.color[0], green: rule.color[1],
                                    blue: rule.color[2], alpha: rule.color[3]))
                            context.fill(
                                CGRect(
                                    x: target.minX + (rule.rect.minX - rect.minX) * scale,
                                    y: target.minY - rule.rect.height * scale, width: rule.rect.width * scale,
                                    height: rule.rect.height * scale))
                        }
                    }
                }
            }
        }
    }

    /// Only the capture shares the print deadline. Its caller may still spend a separate
    /// budget on navigation after it receives these complete bytes.
    static func capturedData(
        timeout: Duration, operation: @escaping @MainActor (ContinuousClock.Instant) async throws -> Data
    ) async throws -> Data {
        let deadline = ContinuousClock.now + timeout
        var result: Result<Data, any Error>?
        let capture = Task {
            do { result = .success(try await operation(deadline)) } catch { result = .failure(error) }
        }
        // WebKit's async capture has no cancellation API. Release the owning session promptly, and never start
        // another slice or publish a partial PDF if an outstanding callback arrives after the deadline.
        defer { capture.cancel() }
        try await WebPaginator.waitUntil(timeout: timeout) { result != nil }
        try Task.checkCancellation()
        guard let result else { throw WebPaginator.PaginationError.printFailed }
        return try result.get()
    }

    private static func measure(
        in webView: WKWebView, script: String, width: CGFloat, height: CGFloat, font: CGFloat,
        booklet: Bool, rows: Int, until deadline: ContinuousClock.Instant
    ) async throws -> (VerticalCapturePlan, CGFloat) {
        let value = try await webView.evaluateForPrinting(
            diagnosed(script, stage: "prepare vertical strip"),
            arguments: [
                "width": width, "height": height, "font": font, "booklet": booklet, "inkEdges": punctuationEdges,
            ],
            until: deadline)
        try Task.checkCancellation()
        guard var json = value as? String else { throw WebPaginator.PaginationError.printFailed }
        while true {
            let result = try await cuts(from: json, width: width, height: height, rows: rows)
            let slices = result.0.sources.map { band in
                let rect = VerticalCapturePlan.captureRect(band, height: height)
                return [band.start, band.end, rect.maxX, rect.minX, rect.minY, rect.maxY]
            }
            guard slices.count > 1 else { return result }
            let update = try await webView.evaluateForPrinting(
                diagnosed("return surimonoIndexSlices(slices, trace)", stage: "index and remeasure slices"),
                arguments: ["slices": slices], until: deadline)
            guard let changed = update as? String else { return result }
            json = changed
        }
    }

    @concurrent private static func cuts(from json: String, width: CGFloat, height: CGFloat, rows: Int) async throws
        -> (VerticalCapturePlan, CGFloat)
    {
        struct Measurement: Decodable {
            let bands: [FlowPageCuts.Band]
            let originY: CGFloat
        }
        let measurement = try JSONDecoder().decode(Measurement.self, from: Data(json.utf8))
        try Task.checkCancellation()
        let chapters = chapterGroups(for: measurement.bands, capacity: width)
        return (
            try VerticalCapturePlan(chapters: chapters, width: width, height: height, rows: rows), measurement.originY
        )
    }

    nonisolated static func chapterGroups(for fragments: [FlowPageCuts.Band], capacity: CGFloat)
        -> [[FlowPageCuts.Band]]
    {
        let lines = FlowPageCuts.lines(for: fragments)
        var chapters: [[FlowPageCuts.Band]] = []
        var start = 0
        // Chapter boundaries start a fresh sheet of logical paper even when its preceding lower row is empty.
        for end in lines.indices.dropFirst().filter({ lines[$0].chapter == true }) + [lines.endIndex] {
            let groups = FlowPageCuts.groups(of: lines[start..<end], capacity: capacity, keepsTwoLines: true)
            if !groups.isEmpty { chapters.append(groups) }
            start = end
        }
        return chapters
    }
}

/// Each capture goes into an open logical page. A different flow can place several slices in distinct columns.
@MainActor
enum FlowPageCapture {
    struct PrintedSlice {
        let page: PDFPage
        let transform: CGAffineTransform
        private let search: GlyphSearch?

        fileprivate init(document: PDFDocument, page: PDFPage, transform: CGAffineTransform) {
            self.page = page
            self.transform = transform
            if #available(macOS 26, *) {
                search = nil
            } else {
                search = GlyphSearch(document)
            }
        }

        // PDFPage holds its document weakly. On Sequoia point-based selections can yield the
        // advance and line height, while the attached document's search exposes the glyph ink.
        final class GlyphSearch {
            private let document: PDFDocument
            private var hits: [String: [Int: CGRect]] = [:]

            init(_ document: PDFDocument) { self.document = document }

            func bounds(of text: String, on page: PDFPage, at point: CGPoint) -> CGRect? {
                if hits[text] == nil {
                    var byIndex: [Int: CGRect] = [:]
                    let matches = document.findString(text)
                    let characterCount = page.numberOfCharacters
                    for hit in matches {
                        // Search ranges include inferred newlines. Character geometry indexes the PDF glyphs.
                        let box = hit.bounds(for: page)
                        let index = page.characterIndex(at: CGPoint(x: box.midX, y: box.midY))
                        if (0..<characterCount).contains(index) {
                            byIndex[index] = page.characterBounds(at: index)
                        }
                    }
                    hits[text] = byIndex
                }
                return hits[text]?[page.characterIndex(at: point)]
            }
        }

        func glyphBounds(of text: String, at point: CGPoint) -> CGRect? {
            let local = point.applying(transform.inverted())
            let bounds: CGRect
            if let search {
                guard !text.isEmpty, let ink = search.bounds(of: text, on: page, at: local) else { return nil }
                bounds = ink.applying(transform)
            } else {
                let index = page.characterIndex(at: local)
                let length = text.utf16.count
                guard index >= 0, length > 0, index <= page.numberOfCharacters - length,
                    page.selection(for: NSRange(location: index, length: length))?.string == text
                else { return nil }
                bounds = page.characterBounds(at: index).applying(transform)
            }
            // PDFKit can pick the nearest character in a neighbouring row for a blank label.
            guard bounds.width > 0, bounds.height > 0,
                bounds.insetBy(dx: -bounds.width / 2, dy: -bounds.height / 2).contains(point)
            else { return nil }
            return bounds
        }
    }

    @discardableResult
    static func draw(
        _ rect: CGRect, from webView: WKWebView, into target: CGRect, in context: CGContext, transparent: Bool = false,
        deadline: ContinuousClock.Instant
    ) async throws -> PrintedSlice {
        let config = WKPDFConfiguration()
        config.rect = rect
        config.allowTransparentBackground = transparent
        let data = try await webView.pdfForPrinting(configuration: config, until: deadline)
        try Task.checkCancellation()
        return try draw(data, into: target, in: context)
    }

    @discardableResult
    static func draw(_ data: Data, into target: CGRect, in context: CGContext) throws -> PrintedSlice {
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
        return PrintedSlice(document: source, page: page, transform: transform)
    }
}
