import PDFKit
import WebKit

@MainActor
enum LaTeXFlowPaginator {
    nonisolated static func hasMarginInk(in markup: String) -> Bool {
        ["latex-numbered-listing", "latex-frame-single", "latex-fbox"].contains { markup.contains($0) }
    }

    /// Native pagination keeps its original page goal for ordinary prose. Switch only when paint
    /// protrudes from a box that controls page breaking (for example a positioned mark or a rotated image).
    static func markVerticalInk(in view: WKWebView, width: CGFloat, until deadline: ContinuousClock.Instant)
        async throws -> Bool
    {
        let media = view.mediaType
        view.mediaType = "print"
        defer { view.mediaType = media }
        return try await view.evaluateForPrinting(
            """
            const root = document.documentElement;
            const old = root.style.cssText;
            const zoom = parseFloat(getComputedStyle(root).zoom) || 1;
            root.style.width = width / zoom + 'px';
            const hosts = new Set();
            try {
              for (const el of document.body.querySelectorAll('*:not(svg *,style,template,script)')) {
                const style = getComputedStyle(el);
                const outline = style.outlineStyle === 'none' ? 0 :
                  Math.max(0, parseFloat(style.outlineWidth) + parseFloat(style.outlineOffset));
                if (!outline && style.position !== 'absolute' && style.transform === 'none' &&
                    !(style.position === 'relative' && (style.top !== 'auto' || style.bottom !== 'auto')) &&
                    !(parseFloat(style.marginTop) < 0 || parseFloat(style.marginBottom) < 0) &&
                    !el.matches('svg,img,.latex-rule')) continue;
                let host = el.parentElement;
                while (host && getComputedStyle(host).display === 'inline') host = host.parentElement;
                if (!host || getComputedStyle(host).overflowY !== 'visible') continue;
                const box = host.getBoundingClientRect(), ink = el.getBoundingClientRect();
                if (!ink.width || !ink.height) continue;
                let top = ink.top - outline, bottom = ink.bottom + outline;
                if (el instanceof SVGSVGElement && style.overflowY === 'visible' && el.getScreenCTM()) {
                  const b = el.getBBox(), matrix = el.getScreenCTM();
                  for (const x of [b.x,b.x+b.width]) for (const y of [b.y,b.y+b.height]) {
                    const p = new DOMPoint(x,y).matrixTransform(matrix);
                    top = Math.min(top, p.y); bottom = Math.max(bottom, p.y);
                  }
                }
                if (top < box.top - 0.1 || bottom > box.bottom + 0.1) hosts.add(host);
              }
            } finally { root.style.cssText = old; }
            for (const host of hosts) if (host !== document.body) host.dataset.flowInkBlock = '';
            return hosts.size > 0;
            """, arguments: ["width": width], until: deadline) as? Bool == true
    }

    nonisolated static func needed(in markup: String) -> Bool {
        [
            "<template data-latex-columns=", "<div data-latex-columns=", "<div data-latex-wide",
            "<figure class=\"latex-figure\" data-latex-float=", "<figure class=\"latex-table\" data-latex-float=",
            "<div data-latex-break=", "<div class=\"latex-pagebreak\" data-latex-break=", "<template data-latex-break=",
            "<section class=\"footnotes\">",
        ].contains { markup.contains($0) }
    }

    private static func script(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw WebPaginator.PaginationError.printFailed
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private struct Origin: Decodable {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
        let hasOverhang: Bool
    }

    struct Pass {
        var document: PDFDocument?
        var pageCount: Int
        var locations: [Int: Int]
    }

    typealias Evaluator = @MainActor (WKWebView, String, [String: Any], @escaping WebKitReply<Any>.Completion) -> Void

    static func paginate(
        in view: WKWebView, pageSize: CGSize, margins: WebPaginator.Margins, timeout: Duration,
        referencesOnly: Bool = false, sample: Bool = false, scriptTimeout: Duration? = nil, evaluator: Evaluator? = nil
    ) async throws -> Pass {
        guard PDFDrawing.validGeometry(pageSize: pageSize, margins: margins) else {
            throw WebPaginator.PaginationError.printFailed
        }
        let deadline = ContinuousClock.now + timeout
        let ratio = WebPaginator.printPixelsPerPoint
        let width = (pageSize.width - margins.left - margins.right) * ratio
        let height = (pageSize.height - margins.top - margins.bottom) * ratio
        let media = view.mediaType
        view.mediaType = "print"
        defer { view.mediaType = media }
        func run(_ js: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
            try Task.checkCancellation()
            let end = min(deadline, ContinuousClock.now + (scriptTimeout ?? timeout))
            if let evaluator {
                return try await WebKitReply<Any>.wait(until: end) { reply in evaluator(view, js, arguments, reply) }
            }
            return try await view.evaluateForPrinting(js, arguments: arguments, until: end)
        }
        // Failed passes are discarded with their session. Successful passes restore the exact preparation DOM.
        guard
            let json = try await run(
                script("latex-flow"),
                [
                    "width": width, "leftMargin": margins.left * ratio, "rightMargin": margins.right * ratio,
                    "paperHeight": pageSize.height * ratio,
                ]
            ) as? String
        else {
            throw WebPaginator.PaginationError.printFailed
        }
        let (pages, locations) = try await plan(json, width: width, height: height, until: deadline)
        if referencesOnly {
            _ = try await run("surimonoRestoreFlow()")
            return Pass(pageCount: pages.count, locations: locations)
        }
        let slices = pages.flatMap { $0.pieces.map(\.slice) }
        // The first printable box can start below the strip origin after discarding its margin.
        // An isolated overhanging box still owns its raised ink above that new start.
        var firstStart: [Int: CGFloat] = [:]
        for s in slices { firstStart[s.strip] = min(firstStart[s.strip] ?? s.start, s.start) }
        let arguments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(slices))
        guard let positions = try await run(script("latex-flow-capture"), ["pieces": arguments]) as? String else {
            throw WebPaginator.PaginationError.printFailed
        }
        let origins = try JSONDecoder().decode([Origin].self, from: Data(positions.utf8))
        var index = 0
        let pdf = try await PDFDrawing.document(pageSize: pageSize) { context in
            for (pageIndex, page) in pages.enumerated() {
                if sample && pageIndex != (locations[-1] ?? 0) {
                    index += page.pieces.count
                    continue
                }
                context.beginPDFPage(nil)
                defer { context.endPDFPage() }
                let edges = verticalEdges(of: page.pieces, width: width)
                for (piece, edge) in zip(page.pieces, edges) {
                    let s = piece.slice
                    guard origins.indices.contains(s.strip) else { throw WebPaginator.PaginationError.printFailed }
                    _ = try await run("surimonoFlow.show(i)", ["i": index])
                    let origin = origins[s.strip]
                    let startsStrip = s.start < 0.01 || origin.hasOverhang && firstStart[s.strip] == s.start
                    let capture = captureRects(
                        piece, origin: CGPoint(x: origin.x, y: origin.y), pageSize: pageSize, margins: margins,
                        above: (edge.above || origin.hasOverhang) && startsStrip,
                        below: (edge.below || origin.hasOverhang) && s.end >= origin.height - 0.01)
                    context.saveGState()
                    defer { context.restoreGState() }
                    // A fragmented strip may contain a continuous border. Keep its internal cut exclusive;
                    // neighbouring text is hidden too, so it cannot reappear in the searchable PDF stream.
                    var clip = CGRect(origin: .zero, size: pageSize)
                    if !startsStrip { clip.size.height = pageSize.height - margins.top - piece.y / ratio }
                    if s.end < origin.height - 0.01 {
                        let bottom = pageSize.height - margins.top - piece.end / ratio
                        clip = clip.intersection(
                            CGRect(x: 0, y: bottom, width: pageSize.width, height: pageSize.height))
                    }
                    context.clip(to: clip)
                    try await FlowPageCapture.draw(
                        capture.source, from: view, into: capture.target, in: context, transparent: true,
                        deadline: deadline)
                    index += 1
                }
                context.setFillColor(gray: 0, alpha: 1)
                for rule in page.rules {
                    context.fill(
                        CGRect(
                            x: margins.left + rule.minX / ratio,
                            y: pageSize.height - margins.top - rule.maxY / ratio, width: rule.width / ratio,
                            height: rule.height / ratio))
                }
            }
        }
        _ = try await run("surimonoRestoreFlow()")
        return Pass(document: pdf, pageCount: pages.count, locations: locations)
    }

    /// A wide strip can touch both columns. Only the first and last ink in each column can claim the
    /// respective physical margin; floats and notes may be appended out of vertical order.
    static func verticalEdges(of pieces: [LaTeXFlowLayout.Piece], width: CGFloat) -> [(above: Bool, below: Bool)] {
        var tops = [CGFloat.infinity, CGFloat.infinity]
        var bottoms = [-CGFloat.infinity, -CGFloat.infinity]
        func columns(_ piece: LaTeXFlowLayout.Piece) -> ClosedRange<Int> {
            if piece.x > 0.01 { return 1...1 }
            return 0...(piece.slice.width >= width - 0.01 ? 1 : 0)
        }
        for piece in pieces {
            for i in columns(piece) {
                tops[i] = min(tops[i], piece.y)
                bottoms[i] = max(bottoms[i], piece.end)
            }
        }
        return pieces.map { piece in
            let spans = columns(piece)
            return (
                spans.allSatisfy { piece.y <= tops[$0] + 0.001 }, spans.allSatisfy { piece.end >= bottoms[$0] - 0.001 }
            )
        }
    }

    /// Capture outside the strip's layout box without changing the measure or scaling its contents.
    /// Inner columns share their gutter; the outside columns can paint into their page margins.
    static func captureRects(
        _ piece: LaTeXFlowLayout.Piece, origin: CGPoint, pageSize: CGSize, margins: WebPaginator.Margins,
        above: Bool = false, below: Bool = false
    ) -> (source: CGRect, target: CGRect) {
        let ratio = WebPaginator.printPixelsPerPoint
        let width = (pageSize.width - margins.left - margins.right) * ratio
        let slice = piece.slice
        let gutter = max(0, width - 2 * slice.width) / 2
        let left = piece.x < 0.01 ? margins.left * ratio : gutter
        let right = piece.x + slice.width >= width - 0.01 ? margins.right * ratio : gutter
        let top = above ? min(origin.y + slice.start - 1, (margins.top * ratio + piece.y) / piece.scale) : 0
        let bottom = below ? max(0, (pageSize.height - margins.top) * ratio - piece.end) / piece.scale : 0
        // WebKit rounds its PDF viewport to device pixels. Enclose the last fractional stroke on each
        // edge; neighbouring pieces' text has already been hidden, and empty ink stays transparent.
        let rect = CGRect(
            x: origin.x - left, y: origin.y + slice.start - top, width: left + slice.width + right,
            height: top + slice.height + bottom
        ).insetBy(dx: -1, dy: -1).integral
        let scale = piece.scale / ratio
        let target = CGRect(
            x: margins.left + piece.x / ratio + (rect.minX - origin.x) * scale,
            y: pageSize.height - margins.top - piece.y / ratio - (rect.maxY - origin.y - slice.start) * scale,
            width: rect.width * scale, height: rect.height * scale)
        return (rect, target)
    }

    @concurrent private static func plan(
        _ json: String, width: CGFloat, height: CGFloat, until deadline: ContinuousClock.Instant
    ) async throws -> (
        [LaTeXFlowLayout.Page], [Int: Int]
    ) {
        let input = try JSONDecoder().decode(LaTeXFlowLayout.Measurement.self, from: Data(json.utf8))
        let pages = try LaTeXFlowLayout.pages(input, width: width, height: height, until: deadline)
        return (pages, locations(of: input.probes ?? [], in: pages))
    }

    // A probe in the margin above a heading belongs to the first printed slice below it.
    // Page order and source order can differ when a float waits for a later page.
    nonisolated static func locations(
        of probes: [LaTeXFlowLayout.Probe], in pages: [LaTeXFlowLayout.Page]
    ) -> [Int: Int] {
        guard !probes.isEmpty else { return [:] }
        var byStrip: [Int: [(end: CGFloat, page: Int)]] = [:]
        for (index, page) in pages.enumerated() {
            for piece in page.pieces {
                byStrip[piece.slice.strip, default: []].append((piece.slice.end, index))
            }
        }
        byStrip = byStrip.mapValues { $0.sorted { $0.end < $1.end } }
        var locations: [Int: Int] = [:]
        for probe in probes {
            guard let cuts = byStrip[probe.strip] else { continue }
            var low = 0
            var high = cuts.count
            while low < high {
                let mid = (low + high) / 2
                if cuts[mid].end <= probe.position { low = mid + 1 } else { high = mid }
            }
            locations[probe.index] = cuts[min(low, cuts.count - 1)].page
        }
        return locations
    }
}
