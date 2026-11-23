import CoreText
import PDFKit
import SurimonoFormats
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
              const japanese = document.body.hasAttribute('data-latex-js-toc') &&
                getComputedStyle(document.body).getPropertyValue('--js-pt').trim();
              const journal = document.body.hasAttribute('data-latex-publication-grid');
              for (const el of document.body.querySelectorAll('*:not(svg *,style,template,script)')) {
                const style = getComputedStyle(el);
                const outline = style.outlineStyle === 'none' ? 0 :
                  Math.max(0, parseFloat(style.outlineWidth) + parseFloat(style.outlineOffset));
                // A journal's plain equation number gets its baseline and strut at column width.
                // Isolating its preliminary line box here would discard the display's glue.
                if (journal && !outline && el.matches('.latex-equation > .eqno:not([style])') && !el.childElementCount &&
                    el.parentElement.querySelector(':scope > .math-display > svg:only-child')) continue;
                if (!outline && style.position !== 'absolute' && style.transform === 'none' &&
                    !(style.position === 'relative' && (style.top !== 'auto' || style.bottom !== 'auto')) &&
                    !(parseFloat(style.marginTop) < 0 || parseFloat(style.marginBottom) < 0) &&
                    !el.matches('svg,img,.latex-rule')) continue;
                let host = el.parentElement;
                while (host && getComputedStyle(host).display === 'inline') host = host.parentElement;
                // The display and its equation number share one atomic box. Only ink
                // outside that box requires a separate strip and capture margins.
                if (japanese) host = el.parentElement.closest('.math-block') || host;
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
            " data-latex-style=\"", "<template data-latex-columns=", "<div data-latex-columns=", "<div data-latex-wide",
            "<figure class=\"latex-figure\" data-latex-float=", "<figure class=\"latex-table\" data-latex-float=",
            "<div data-latex-break=", "<div class=\"latex-pagebreak\" data-latex-break=", "<template data-latex-break=",
            "<div class=\"latex-vfill\"", "<section class=\"footnotes\">", "<span class=\"latex-vspace\"",
            "<div class=\"latex-vspace\"", " data-latex-paged-table",
        ].contains { markup.contains($0) }
    }

    private static func script(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw WebPaginator.PaginationError.printFailed
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // Body prose and diagram labels share grapheme boundaries and prohibited line starts.
    static func japaneseLineScript() throws -> String {
        try script("latex-badness") + "\n" + script("tikz-label-layout") + "\n" + script("latex-japanese-lines")
    }

    // The pattern licence requires the resource to remain byte-for-byte identical to Plain TeX.
    // Encode it as data. Executing TeX source is unnecessary for Liang's pattern trie.
    private static let latinSource = Result {
        guard let url = Bundle.module.url(forResource: "hyphen", withExtension: "tex") else {
            throw WebPaginator.PaginationError.printFailed
        }
        let patterns = try String(contentsOf: url, encoding: .utf8)
        let literal = String(decoding: try JSONEncoder().encode(patterns), as: UTF8.self)
        return try "globalThis.surimonoEnglishPatterns = " + literal + ";\n"
            + script("latex-badness") + "\n" + script("latex-latin-plan") + "\n" + script("latex-latin-lines")
    }

    static func latinLineScript() throws -> String { try latinSource.get() }

    static func installLatinLines(
        in view: WKWebView, diagnostics: Bool = false, boxes: Bool = false, until deadline: ContinuousClock.Instant
    )
        async throws
    {
        _ = try await view.evaluateForPrinting(
            latinLineScript()
                + "\nglobalThis.surimonoComposeLatin = latinCompose; globalThis.surimonoLatinDiagnostics = diagnostics;"
                + "\nglobalThis.surimonoLatinBoxDiagnostics = boxes; globalThis.surimonoCheckMathSearch = true;",
            arguments: ["diagnostics": diagnostics, "boxes": boxes], until: deadline)
    }

    // Native page references keep handles to the prepared DOM and can change a word's width
    // between print passes. Restore those exact nodes after each successful print.
    static func prepareNativeLines(in view: WKWebView, width: CGFloat, until deadline: ContinuousClock.Instant)
        async throws
    {
        let media = view.mediaType
        view.mediaType = "print"
        defer { view.mediaType = media }
        let prepare = """
            const root = document.documentElement, saved = root.style.cssText;
            const zoom = parseFloat(getComputedStyle(root).zoom) || 1;
            const undo = [];
            globalThis.surimonoRestoreLatin = () => {
              for (const restore of undo.reverse()) restore();
              delete globalThis.surimonoRestoreLatin;
            };
            try {
              root.style.width = width / zoom + 'px';
              root.getBoundingClientRect();
              await document.fonts.ready;
              globalThis.surimonoLatinLast = surimonoComposeLatin(document.body, 1 / zoom, undo);
            } finally { root.style.cssText = saved; }
            return !!globalThis.surimonoMathProofs?.length;
            """
        let proof = try await view.evaluateForPrinting(prepare, arguments: ["width": width], until: deadline)
        if proof as? Bool == true, try await rejectsMathSpacing(in: view, until: deadline) {
            _ = try await view.evaluateForPrinting(
                "surimonoRestoreLatin();\n" + prepare, arguments: ["width": width], until: deadline)
        }
    }

    /// WebKit writes operators as separate text runs. A change in physical
    /// spacing can silently insert or remove a searchable space in PDFKit.
    private static func rejectsMathSpacing(in view: WKWebView, until deadline: ContinuousClock.Instant) async throws
        -> Bool
    {
        struct Proof: Decodable {
            struct Pair: Decodable {
                let index: Int
                let top, row: CGFloat
            }
            let x, y, width, height: CGFloat
            let samples: [Pair]
            let rejected: [Int]
        }
        let result = try await view.evaluateForPrinting(script("latex-math-search"), until: deadline)
        guard let json = result as? String else { throw WebPaginator.PaginationError.printFailed }
        let proof = try JSONDecoder().decode(Proof.self, from: Data(json.utf8))
        var rejected = Set(proof.rejected)
        if !proof.samples.isEmpty {
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: proof.x, y: proof.y, width: proof.width, height: proof.height)
            // A failed optional proof leaves these paragraphs on their original math widths.
            // Cancellation and an expired print deadline still terminate the pass.
            let bytes = try? await view.pdfForPrinting(configuration: config, until: deadline)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw WebPaginator.PaginationError.timedOut }
            let page = bytes.flatMap { PDFDocument(data: $0) }?.page(at: 0)
            for pair in proof.samples {
                func extract(_ top: CGFloat) -> String? {
                    let rect = CGRect(x: 0, y: proof.height - top - pair.row, width: proof.width, height: pair.row)
                    return page?.selection(for: rect)?.string
                }
                let original = extract(pair.top)
                if original?.isEmpty != false || original != extract(pair.top + pair.row) {
                    rejected.insert(pair.index)
                }
            }
        }
        _ = try await view.evaluateForPrinting(
            "surimonoFinishMathProof(rejected)", arguments: ["rejected": Array(rejected)], until: deadline)
        return !rejected.isEmpty
    }

    private struct Origin: Decodable {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
        let linkMarks: [LinkMark]?
        let hasOverhang: Bool
        let distributedHeadings: [DistributedHeading]?
    }

    private struct LinkMark: Decodable {
        let id, href: String?
        let pageTop: Bool?
        let x, y, width, height, start: CGFloat
    }

    private struct PageLinks {
        enum Link {
            case named(String, CGRect)
            case external(URL, CGRect)
        }

        var destinations: [String: CGPoint] = [:]
        var links: [Link] = []

        func write(to context: CGContext) {
            for (name, point) in destinations { context.addDestination(name as CFString, at: point) }
            for link in links {
                switch link {
                case .named(let name, let rect): context.setDestination(name as CFString, for: rect)
                case .external(let url, let rect): context.setURL(url as CFURL, for: rect)
                }
            }
        }
    }

    // Write destinations and links while Quartz owns the page tree. Attaching GoTo actions
    // to PDFKit wrappers after drawing can leave them without a target page on serialization.
    private static func pageLinks(
        pages: [LaTeXFlowLayout.Page], origins: [Origin], textOrigin: CGPoint
    ) -> [Int: PageLinks] {
        var targets: [String: (page: Int, point: CGPoint, name: String)] = [:]
        var links: [(page: Int, rect: CGRect, href: String, pageTop: Bool)] = []
        let grouped = origins.map { Dictionary(grouping: $0.linkMarks ?? [], by: \.start) }
        for (index, layout) in pages.enumerated() {
            for piece in layout.pieces {
                let ratio = WebPaginator.printPixelsPerPoint
                let scale = piece.scale / ratio
                for mark in grouped[piece.slice.strip][piece.slice.start] ?? [] {
                    let top = textOrigin.y - piece.y / ratio - (mark.y - piece.slice.start) * scale
                    let left = textOrigin.x + piece.x / ratio + mark.x * scale
                    if let id = mark.id, targets[id] == nil {
                        targets[id] = (index, CGPoint(x: left, y: top), "anchor-\(targets.count)")
                    }
                    if let href = mark.href {
                        let rect = CGRect(
                            x: left, y: top - mark.height * scale, width: mark.width * scale,
                            height: mark.height * scale)
                        links.append((index, rect, href, mark.pageTop == true))
                    }
                }
            }
        }
        var result: [Int: PageLinks] = [:]
        for link in links {
            if link.href.hasPrefix("#") {
                guard let target = targets[String(link.href.dropFirst())] else { continue }
                let name = link.pageTop ? "page-\(target.page)" : target.name
                result[target.page, default: PageLinks()].destinations[name] = link.pageTop ? textOrigin : target.point
                result[link.page, default: PageLinks()].links.append(.named(name, link.rect))
            } else if let url = URL(string: link.href) {
                result[link.page, default: PageLinks()].links.append(.external(url, link.rect))
            }
        }
        return result
    }

    struct DistributedHeading: Decodable {
        let text: String
        let x, y, width: CGFloat

        func draw(in context: CGContext, from origin: CGPoint, scale: CGFloat) {
            // The class sets a five-cell box. Core Text preserves one searchable run
            // while distributing the spare width at Japanese justification opportunities.
            let measure = width * scale
            let font = CTFontCreateWithName("HiraginoSans-W5" as CFString, measure / 5, nil)
            let title = NSAttributedString(string: text, attributes: [.font: font])
            let natural = CTLineCreateWithAttributedString(title)
            let line = CTLineCreateJustifiedLine(natural, 1, measure) ?? natural
            context.saveGState()
            defer { context.restoreGState() }
            context.setFillColor(gray: 0, alpha: 1)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: origin.x + x * scale, y: origin.y - y * scale)
            CTLineDraw(line, context)
        }
    }

    private struct Leader: Decodable {
        struct Glyph: Decodable {
            let x, y, descentFraction: CGFloat
            let text: String
        }

        let x, y, pitch, diameter: CGFloat
        let count: Int
        let folio: Glyph?

        func draw(in context: CGContext, from origin: CGPoint, scale: CGFloat, slice: FlowPageCapture.PrintedSlice) {
            let size = diameter * scale
            // WebKit snaps the painted glyph's baseline independently of its DOM line box.
            // TeX's period rests on that baseline, including when the digit has a curved descender.
            let baseline = folio.flatMap { glyph in
                let point = CGPoint(x: origin.x + glyph.x * scale, y: origin.y - glyph.y * scale)
                return slice.glyphBounds(of: glyph.text, at: point).map { $0.minY + $0.height * glyph.descentFraction }
            }
            let bottom = baseline ?? (origin.y - y * scale - size / 2)
            context.setFillColor(gray: 0, alpha: 1)
            for i in 0..<count {
                let left = origin.x + x * scale + (CGFloat(i) + 0.5) * pitch * scale - size / 2
                context.fillEllipse(in: CGRect(x: left, y: bottom, width: size, height: size))
            }
        }
    }

    struct Pass {
        var data: Data?
        var blankPages: Set<Int> = []
        var pageCount: Int
        var locations: [Int: Int]
    }

    typealias Evaluator = @MainActor (WKWebView, String, [String: Any], @escaping WebKitReply<Any>.Completion) -> Void

    typealias PlanObserver = @MainActor (LaTeXFlowLayout.Measurement, [LaTeXFlowLayout.Page]) -> Void

    static func paginate(
        in view: WKWebView, pageSize: CGSize, margins: WebPaginator.Margins, timeout: Duration,
        referencesOnly: Bool = false, htmlComposition: WebPaginator.HTMLComposition? = nil, sample: Bool = false,
        scriptTimeout: Duration? = nil, evaluator: Evaluator? = nil, inspectPlan: PlanObserver? = nil
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
        let measure = try japaneseLineScript() + "\n" + script("latex-flow")
        let dimensions: [String: Any] = [
            "width": width, "leftMargin": margins.left * ratio, "rightMargin": margins.right * ratio,
            "paperHeight": pageSize.height * ratio, "bodyHeight": height,
        ]
        func measurement(_ script: String) async throws -> LaTeXFlowLayout.Measurement {
            guard let json = try await run(script, dimensions) as? String else {
                throw WebPaginator.PaginationError.printFailed
            }
            return try await Self.decodeMeasurement(json)
        }
        var input = try await measurement(measure)
        if input.mathProof == true, try await rejectsMathSpacing(in: view, until: deadline) {
            input = try await measurement("surimonoRestoreFlow();\n" + measure)
        }
        let (pages, locations, review) = try await plan(
            input, width: width, height: height, recordsBreaks: inspectPlan != nil, until: deadline)
        inspectPlan?(input, pages)
        if let htmlComposition {
            let rows: [[String: Any]] = try pages.map { page in
                [
                    "pieces": try JSONSerialization.jsonObject(with: JSONEncoder().encode(page.pieces)),
                    "rules": page.rules.map { [$0.minX, $0.minY, $0.width, $0.height] },
                    "lines": review?.proofBaselines(in: page.pieces).map { $0 * ratio } ?? [],
                ]
            }
            let result = try await run(
                script("latex-flow-html"),
                [
                    "versoShift": htmlComposition.versoShift * ratio, "rightBound": htmlComposition.rightBound,
                    "pages": rows, "ratio": ratio, "mm": 72 / 25.4 * ratio,
                    "left": margins.left * ratio, "topMargin": margins.top * ratio,
                    "paperWidth": pageSize.width * ratio, "paperHeight": pageSize.height * ratio,
                    "pageWidthPT": pageSize.width, "pageHeightPT": pageSize.height,
                ])
            guard result as? Bool == true else { throw WebPaginator.PaginationError.printFailed }
            return Pass(pageCount: pages.count, locations: locations)
        }
        if referencesOnly {
            _ = try await run("surimonoRestoreFlow()")
            return Pass(
                blankPages: Set(pages.indices.filter { pages[$0].isBlankVersoOrRecto }), pageCount: pages.count,
                locations: locations)
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
        var lineNumber = 1
        let links =
            !sample && origins.contains { $0.linkMarks?.isEmpty == false }
            ? pageLinks(
                pages: pages, origins: origins, textOrigin: CGPoint(x: margins.left, y: pageSize.height - margins.top))
            : [:]
        let pdf = try await PDFDrawing.data(pageSize: pageSize) { context in
            for (pageIndex, page) in pages.enumerated() {
                if sample && pageIndex != (locations[-1] ?? 0) {
                    index += page.pieces.count
                    review?.forEachBaseline(in: page.pieces) { _, _, _ in lineNumber += 1 }
                    continue
                }
                context.beginPDFPage(nil)
                defer { context.endPDFPage() }
                links[pageIndex]?.write(to: context)
                let edges = verticalEdges(of: page.pieces, width: width)
                var position = 0
                while position < page.pieces.count {
                    var piece = page.pieces[position]
                    let offsets = captureOffsets(in: page.pieces, from: position)
                    let shown = try await run("return surimonoFlow.show(i, offsets)", ["i": index, "offsets": offsets])
                    let count = shown as? Int ?? 1
                    guard (1...offsets.count).contains(count), origins.indices.contains(piece.slice.strip) else {
                        throw WebPaginator.PaginationError.printFailed
                    }
                    let last = position + count - 1
                    let lastEnd = page.pieces[last].slice.end
                    if count > 1 { piece.slice.end = piece.slice.start + page.pieces[last].end - piece.y }
                    let s = piece.slice
                    let origin = origins[s.strip]
                    let startsStrip = s.start < 0.01 || origin.hasOverhang && firstStart[s.strip] == s.start
                    let capture = captureRects(
                        piece, origin: CGPoint(x: origin.x, y: origin.y), pageSize: pageSize, margins: margins,
                        above: (edges[position].above || origin.hasOverhang) && startsStrip,
                        below: (edges[last].below || origin.hasOverhang) && lastEnd >= origin.height - 0.01)
                    context.saveGState()
                    defer { context.restoreGState() }
                    // A fragmented strip may contain a continuous border. Keep its internal cut exclusive;
                    // neighbouring text is hidden too, so it cannot reappear in the searchable PDF stream.
                    var clip = CGRect(origin: .zero, size: pageSize)
                    if !startsStrip { clip.size.height = pageSize.height - margins.top - piece.y / ratio }
                    if lastEnd < origin.height - 0.01 {
                        let bottom = pageSize.height - margins.top - piece.end / ratio
                        clip = clip.intersection(
                            CGRect(x: 0, y: bottom, width: pageSize.width, height: pageSize.height))
                    }
                    context.clip(to: clip)
                    let printed = try await FlowPageCapture.draw(
                        capture.source, from: view, into: capture.target, in: context, transparent: true,
                        deadline: deadline)
                    if let leaders = shown as? String {
                        let start = CGPoint(
                            x: margins.left + piece.x / ratio,
                            y: pageSize.height - margins.top - (piece.y - s.start * piece.scale) / ratio)
                        for row in try JSONDecoder().decode([Leader].self, from: Data(leaders.utf8)) {
                            row.draw(in: context, from: start, scale: piece.scale / ratio, slice: printed)
                        }
                    }
                    if let headings = origin.distributedHeadings {
                        for band in page.pieces[position...last] {
                            let scale = band.scale / ratio
                            let start = CGPoint(
                                x: margins.left + band.x / ratio,
                                y: pageSize.height - margins.top - band.y / ratio + band.slice.start * scale)
                            for heading in headings where (band.slice.start..<band.slice.end).contains(heading.y) {
                                heading.draw(in: context, from: start, scale: scale)
                            }
                        }
                    }
                    index += count
                    position += count
                }
                review?.draw(
                    page.pieces, pageIndex: pageIndex,
                    textOrigin: CGPoint(x: margins.left, y: pageSize.height - margins.top), width: width / ratio,
                    next: &lineNumber, in: context)
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
        return Pass(data: pdf, pageCount: pages.count, locations: locations)
    }

    /// Candidate displacements, relative to the first source band. The DOM checks ink ownership
    /// before accepting a prefix. A new column, float strip, scale or overlapping band starts a new capture.
    static func captureOffsets(in pieces: [LaTeXFlowLayout.Piece], from index: Int) -> [CGFloat] {
        let first = pieces[index]
        var offsets: [CGFloat] = [0]
        guard first.scale == 1 else { return offsets }
        // Bound the candidate payload even when an unusual document has thousands of tiny fragments.
        for i in pieces.indices.dropFirst(index + 1).prefix(64) {
            let piece = pieces[i]
            guard piece.x == first.x, piece.scale == 1, piece.slice.strip == first.slice.strip,
                piece.slice.start >= pieces[i - 1].slice.end - 0.001,
                piece.y >= pieces[i - 1].end - 0.001
            else { break }
            offsets.append(piece.y - first.y - (piece.slice.start - first.slice.start))
        }
        return offsets
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

    @concurrent private static func decodeMeasurement(_ json: String) async throws -> LaTeXFlowLayout.Measurement {
        try JSONDecoder().decode(LaTeXFlowLayout.Measurement.self, from: Data(json.utf8))
    }

    @concurrent private static func plan(
        _ input: LaTeXFlowLayout.Measurement, width: CGFloat, height: CGFloat, recordsBreaks: Bool,
        until deadline: ContinuousClock.Instant
    ) async throws -> (
        [LaTeXFlowLayout.Page], [Int: Int], ConferenceReviewDrawing?
    ) {
        let pages = try LaTeXFlowLayout.pages(
            input, width: width, height: height, recordsBreaks: recordsBreaks, until: deadline)
        let review = input.review.map {
            ConferenceReviewDrawing(
                style: $0, lines: input.reviewLines ?? [], banner: input.reviewBanner, corner: input.reviewCorner)
        }
        return (pages, locations(of: input.probes ?? [], in: pages), review)
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
