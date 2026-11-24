import CoreText
import PDFKit
import SurimonoCore
import WebKit

@MainActor
enum VerticalPaginator {
    private static let measurement = Bundle.module.url(forResource: "vertical-lines", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

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

    private static func captureRect(_ band: FlowPageCuts.Band, height: CGFloat) -> CGRect {
        let left = max(band.end, band.ink?.end ?? band.end)
        let right = min(band.start, band.ink?.start ?? band.start)
        let top = min(0, band.ink?.top ?? 0)
        let bottom = max(height, band.ink?.bottom ?? height)
        return CGRect(x: -left, y: top, width: left - right, height: bottom - top)
    }

    /// The optional sample position is an x coordinate in the prepared strip, measured after the theme took effect.
    /// Only that page needs a PDF capture in the palette. It receives the deadline of the whole call, so that looking
    /// the position up spends what is left of the budget instead of starting one of its own.
    static func pages(
        in webView: WKWebView, pageSize: CGSize, margins: WebPaginator.Margins, timeout: Duration,
        booklet: Bool = false, textScale: Double = 1,
        samplePosition: (@MainActor (ContinuousClock.Instant) async throws -> CGFloat?)? = nil
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        guard PDFDrawing.validGeometry(pageSize: pageSize, margins: margins), let measurement else {
            throw WebPaginator.PaginationError.printFailed
        }
        // A PDF capture is in screen coordinates. 96 CSS pixels occupy 72 physical points on the logical paper.
        let pixelsPerPoint: CGFloat = 96.0 / 72
        // Each WebKit reply below is awaited only until this deadline, and fails at once when the page's process
        // has ended: awaiting WebKit's own async calls left the capture task (and its session) waiting for good.
        let deadline = ContinuousClock.now + timeout
        var result: Result<PDFDocument, any Error>?
        let capture = Task { @MainActor in
            do {
                let values =
                    try await webView.evaluateForPrinting(
                        """
                        const d = document.body.dataset;
                        return d.latexVerticalRows ? [d.latexVerticalRows, d.latexSize, d.latexTextWidth, d.latexTextHeight].map(Number) : null;
                        """, until: deadline) as? [Double]
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
                let (pages, originY) = try await measure(
                    in: webView, script: measurement, width: width, height: height, font: frame.font,
                    rowCount: frame.rows, booklet: booklet, until: deadline)
                try Task.checkCancellation()
                let multipleSlices = pages.count > 1 || (pages.first?.count ?? 0) > 1
                var selected = pages.startIndex..<pages.endIndex
                if let samplePosition, !pages.isEmpty {
                    let position = try await samplePosition(deadline)
                    let index = position.flatMap { x in pages.firstIndex { ($0.last?.end ?? 0) >= -x } } ?? 0
                    selected = index..<(index + 1)
                }
                let document = try await PDFDrawing.document(pageSize: pageSize) { context in
                    if pages.isEmpty {
                        context.beginPDFPage(nil)
                        context.endPDFPage()
                    }
                    var index = pages.prefix(selected.lowerBound).reduce(0) { $0 + $1.count }
                    for page in selected {
                        context.beginPDFPage(nil)
                        defer { context.endPDFPage() }
                        for (row, slice) in pages[page].enumerated() {
                            try Task.checkCancellation()
                            if multipleSlices {
                                _ = try await webView.evaluateForPrinting(
                                    "surimonoCaptureSlice(index)", arguments: ["index": index], until: deadline)
                            }
                            index += 1
                            // Assign rows by their layout width, then keep annotation overhang at its natural scale.
                            let ink = captureRect(slice, height: height)
                            let rect = ink.offsetBy(dx: 0, dy: originY)
                            let scale = min(1, width / (slice.end - slice.start)) / pixelsPerPoint
                            let target = CGRect(
                                x: frame.right + (ink.minX + slice.start) * scale,
                                y: frame.top(of: row) - ink.maxY * scale,
                                width: rect.width * scale, height: rect.height * scale)
                            try await FlowPageCapture.draw(
                                rect, from: webView, into: target, in: context, deadline: deadline)
                        }
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

    private static func measure(
        in webView: WKWebView, script: String, width: CGFloat, height: CGFloat, font: CGFloat,
        rowCount: Int, booklet: Bool, until deadline: ContinuousClock.Instant
    ) async throws -> ([[FlowPageCuts.Band]], CGFloat) {
        let value = try await webView.evaluateForPrinting(
            script,
            arguments: [
                "width": width, "height": height, "font": font, "booklet": booklet, "inkEdges": punctuationEdges,
            ],
            until: deadline)
        try Task.checkCancellation()
        guard var json = value as? String else { throw WebPaginator.PaginationError.printFailed }
        while true {
            let result = try await cuts(from: json, capacity: width, rowsPerPage: rowCount)
            let slices = result.0.flatMap {
                $0.map { band in
                    let rect = captureRect(band, height: height)
                    return [band.start, band.end, rect.maxX, rect.minX, rect.minY, rect.maxY]
                }
            }
            guard slices.count > 1 else { return result }
            let update = try await webView.evaluateForPrinting(
                "return surimonoIndexSlices(slices)", arguments: ["slices": slices], until: deadline)
            guard let changed = update as? String else { return result }
            json = changed
        }
    }

    @concurrent private static func cuts(from json: String, capacity: CGFloat, rowsPerPage: Int) async throws
        -> ([[FlowPageCuts.Band]], CGFloat)
    {
        struct Measurement: Decodable {
            let bands: [FlowPageCuts.Band]
            let originY: CGFloat
        }
        let measurement = try JSONDecoder().decode(Measurement.self, from: Data(json.utf8))
        try Task.checkCancellation()
        return (rows(for: measurement.bands, capacity: capacity, rowsPerPage: rowsPerPage), measurement.originY)
    }

    nonisolated static func rows(for fragments: [FlowPageCuts.Band], capacity: CGFloat, rowsPerPage: Int)
        -> [[FlowPageCuts.Band]]
    {
        let lines = FlowPageCuts.lines(for: fragments)
        var pages: [[FlowPageCuts.Band]] = []
        var start = 0
        // Chapter boundaries start a fresh sheet of logical paper even when its preceding lower row is empty.
        for end in lines.indices.dropFirst().filter({ lines[$0].chapter == true }) + [lines.endIndex] {
            let groups = FlowPageCuts.groups(of: lines[start..<end], capacity: capacity, keepsTwoLines: true)
            let rows = FlowPageCuts.pages(forGroups: groups, capacity: capacity)
            for first in stride(from: 0, to: rows.count, by: rowsPerPage) {
                pages.append(Array(rows[first..<min(first + rowsPerPage, rows.count)]))
            }
            start = end
        }
        return pages
    }
}

/// Each capture goes into an open logical page. A different flow can place several slices in distinct columns.
@MainActor
enum FlowPageCapture {
    struct PrintedSlice {
        let page: PDFPage
        let transform: CGAffineTransform

        func glyphBounds(of text: String, at point: CGPoint) -> CGRect? {
            let index = page.characterIndex(at: point.applying(transform.inverted()))
            let length = text.utf16.count
            guard index >= 0, length > 0, index <= page.numberOfCharacters - length,
                page.selection(for: NSRange(location: index, length: length))?.string == text
            else { return nil }
            let bounds = page.characterBounds(at: index).applying(transform)
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
        return PrintedSlice(page: page, transform: transform)
    }
}
