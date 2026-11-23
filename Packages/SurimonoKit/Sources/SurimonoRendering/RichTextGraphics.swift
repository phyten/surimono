import AppKit
import PDFKit
import WebKit

@MainActor
protocol GraphicSnapshotting {
    func png(in view: WKWebView, viewport: CGRect, document: CGRect, until deadline: ContinuousClock.Instant)
        async throws -> Data
}

@MainActor
struct WebGraphicSnapshot: GraphicSnapshotting {
    var requestedScale: CGFloat?

    static func scale(for size: CGSize) -> CGFloat {
        min(2, 4000 / max(size.width, size.height))
    }

    /// Both the snapshot and the PDF fallback wait at most until `deadline`, and end at once when the page's process
    /// has ended or the task is cancelled; only WebKit's own failure to snapshot falls back to the PDF.
    func png(in view: WKWebView, viewport: CGRect, document: CGRect, until deadline: ContinuousClock.Instant)
        async throws -> Data
    {
        let scale = requestedScale ?? Self.scale(for: document.size)
        if view.bounds.contains(viewport) {
            let config = WKSnapshotConfiguration()
            config.rect = viewport
            config.snapshotWidth = NSNumber(value: viewport.width * scale)
            let snapshot: NSImage?
            do {
                snapshot = try await view.snapshotForPrinting(configuration: config, until: deadline)
            } catch let error as WebPaginator.PaginationError where error != .emptyDocument {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                snapshot = nil
            }
            if let snapshot, let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
                let png = bitmap(size: document.size, scale: scale, draw: { $0.draw(image, in: $1) })
            {
                return png
            }
        }
        // The hidden window can have no composited backing, or the figure can extend outside the viewport.
        try Task.checkCancellation()
        let config = WKPDFConfiguration()
        config.rect = document
        let bytes = try await view.pdfForPrinting(configuration: config, until: deadline)
        guard let page = PDFDocument(data: bytes)?.page(at: 0) else { throw WebPaginator.PaginationError.emptyDocument }
        let pdfSize = page.bounds(for: .cropBox).size
        guard pdfSize.width > 0, pdfSize.height > 0 else { throw WebPaginator.PaginationError.emptyDocument }
        if let requestedScale {
            // The snapshot PDF may round a fractional rectangle to whole points. Map it back to the requested
            // pixel dimensions on both axes, including when a long diagram spans several paper pages.
            guard let reference = page.pageRef,
                let png = bitmap(
                    size: document.size, scale: requestedScale, checksInk: false,
                    draw: { context, box in
                        context.scaleBy(x: box.width / pdfSize.width, y: box.height / pdfSize.height)
                        context.concatenate(
                            reference.getDrawingTransform(
                                .cropBox, rect: CGRect(origin: .zero, size: pdfSize), rotate: 0,
                                preserveAspectRatio: true))
                        context.drawPDFPage(reference)
                    })
            else { throw WebPaginator.PaginationError.emptyDocument }
            return png
        }
        let pdfScale = min(document.width * scale / pdfSize.width, 4000 / max(pdfSize.width, pdfSize.height))
        return try PageImageExporter.png(page, dpi: 72 * pdfScale)
    }

    private func bitmap(
        size: CGSize, scale: CGFloat, checksInk: Bool = true, draw: (CGContext, CGRect) -> Void
    ) -> Data? {
        // snapshotWidth is in points. Normalize Retina backing pixels to the requested pixel budget.
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4 * width,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let bytes = context.data?.assumingMemoryBound(to: UInt32.self)
        else { return nil }
        let box = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        draw(context, box)
        guard !checksInk || (0..<(width * height)).contains(where: { bytes[$0] != bytes[0] }),
            let rendered = context.makeImage()
        else { return nil }
        return NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
    }
}

@MainActor
enum RichTextGraphics {
    static let limit = 400
    static let selection = """
        const alt = svg => svg.getAttribute('aria-label')?.trim() || svg.getAttribute('alt')?.trim()
          || svg.querySelector(':scope > title')?.textContent.trim() || 'diagram';
        const selected = [];
        for (const svg of document.body.querySelectorAll('svg,img')) {
          if (svg.ownerSVGElement) continue;
          if (svg.localName === 'img') {
            const src = svg.currentSrc || svg.src;
            if (!svg.naturalWidth || !(/^data:image[/]svg[+]xml/i.test(src) || /[.]svgz?([?#]|$)/i.test(src))) continue;
          }
          const r = svg.getBoundingClientRect();
          if (svg.matches('.callout-icon, pre.surimono-source .source-no, pre.surimono-source .source-digits') || (svg.closest('[aria-hidden="true"]') && Math.max(r.width,r.height)<=32)) {
            svg.remove(); continue;
          }
          if (selected.length >= limit || !r.width || !r.height) {
            const span = document.createElement('span'); span.textContent = alt(svg); svg.replaceWith(span); continue;
          }
          selected.push({svg, alt: alt(svg)});
        }
        globalThis.surimonoGraphics = selected;
        return selected.length;
        """

    static func replace(
        in view: WKWebView, snapshot: any GraphicSnapshotting = WebGraphicSnapshot(),
        until deadline: ContinuousClock.Instant
    ) async throws {
        func run(_ script: String, _ args: [String: Any]) async throws -> Any? {
            try await view.evaluateForPrinting(script, arguments: args, until: deadline)
        }
        guard let count = try await run(selection, ["limit": limit]) as? Int else {
            throw WebPaginator.PaginationError.emptyDocument
        }
        for index in 0..<count {
            try Task.checkCancellation()
            let measure = """
                const {svg} = surimonoGraphics[index];
                svg.style.setProperty('background','white','important');
                if (svg.closest('.math')) svg.style.setProperty('color','black','important');
                svg.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});
                const r = svg.getBoundingClientRect();
                return [r.x,r.y,r.width,r.height,r.x+scrollX,r.y+scrollY];
                """
            guard let r = try await run(measure, ["index": index]) as? [Double], r.count == 6,
                r.allSatisfy(\.isFinite), r[2] > 0, r[3] > 0
            else { throw WebPaginator.PaginationError.emptyDocument }
            let png = try await snapshot.png(
                in: view, viewport: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]),
                document: CGRect(x: r[4], y: r[5], width: r[2], height: r[3]), until: deadline)
            _ = try await run(
                """
                const {svg,alt} = surimonoGraphics[index];
                const image = document.createElement('img');
                image.alt = alt;
                image.style.verticalAlign = getComputedStyle(svg).verticalAlign;
                image.style.width = width+'px'; image.style.height = height+'px';
                image.src = 'data:image/png;base64,' + png;
                // Diagram preparation blocks further resource loads. Explicit dimensions suffice here;
                // the receiving app will decode the embedded bytes in its own document.
                svg.replaceWith(image);
                """, ["index": index, "width": r[2], "height": r[3], "png": png.base64EncodedString()])
        }
    }
}
