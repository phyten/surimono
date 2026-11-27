import CoreGraphics
import Foundation
import PDFKit

/// Lays a theme's paper under pages laid out without it, so the paper covers the margins too (see `PaperBackground`).
@MainActor
enum PaperComposer {
    static func compose(
        _ document: PDFDocument, paper: PDFPage?, bindsPrintedLinks: Bool, shift: (Int) -> CGFloat = { _ in 0 }
    ) async throws -> PDFDocument? {
        if #available(macOS 26, *) {
            return compose(document, paper: paper, rebuildingPageTree: bindsPrintedLinks, shift: shift)
        }
        // Without annotations the Quartz output already has a complete, searchable page tree.
        guard bindsPrintedLinks,
            (0..<document.pageCount).contains(where: {
                document.page(at: $0)?.annotations.isEmpty == false
            })
        else {
            return compose(document, paper: paper, shift: shift)
        }
        guard let composed = compose(document, paper: paper, rebuildingPageTree: true, shift: shift) else { return nil }
        // Preserve the authored destinations when materializing the tree for Sequoia's text selections.
        do {
            let bytes = try await ReadingPDFExporter.data(from: composed)
            return reopenedPaper(from: bytes, annotationSources: document) ?? composed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Keep the live links if PDFKit cannot serialize them faithfully.
            return composed
        }
    }

    static func reopenedPaper(from data: Data, annotationSources source: PDFDocument) -> PDFDocument? {
        guard let reopened = PDFDocument(data: data), reopened.pageCount == source.pageCount else { return nil }
        for index in 0..<source.pageCount {
            guard let original = source.page(at: index) else { return nil }
            guard !original.annotations.isEmpty else { continue }
            guard let page = reopened.page(at: index) else { return nil }
            // Serialization does not carry StandalonePage's owners. The next view copy inherits
            // them from this wrapper even if the theme trial has already evicted its source.
            StandalonePage.retainSources(of: original, on: page)
            reopened.retainPage(page)
        }
        reopened.inheritDisplayFallback(from: source)
        return reopened
    }

    /// Each page of `document` drawn over `paper`, as vectors. The paper is stretched to each page, which it matches
    /// unless the page kept the paginator's allowance. Links and other annotations move along with their page.
    /// - Parameter shift: How far the content of the page at an index moves to the right, on a paper that stays.
    static func compose(
        _ document: PDFDocument, paper: PDFPage?, rebuildingPageTree: Bool = false, shift: (Int) -> CGFloat = { _ in 0 }
    ) -> PDFDocument? {
        let paperBox = paper.map { $0.bounds(for: .cropBox).intersection($0.bounds(for: .mediaBox)) }
        if let paperBox, paperBox.width <= 0 || paperBox.height <= 0 { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { return nil }
        var boxes: [CGRect] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox).intersection(page.bounds(for: .mediaBox))
            boxes.append(box)
            var mediaBox = CGRect(origin: .zero, size: box.size)
            context.beginPage(mediaBox: &mediaBox)
            if let paper, let paperBox {
                context.saveGState()
                context.scaleBy(x: box.width / paperBox.width, y: box.height / paperBox.height)
                paper.draw(with: .cropBox, to: context)
                context.restoreGState()
            }
            context.saveGState()
            context.translateBy(x: shift(index), y: 0)
            page.draw(with: .cropBox, to: context)
            context.restoreGState()
            context.endPage()
        }
        context.closePDF()
        guard let drawn = PDFDocument(data: data as Data), drawn.pageCount == boxes.count else { return nil }
        let composed: PDFDocument
        if rebuildingPageTree {
            // Reopening the drawn bytes and only adding annotations can leave PDFKit's
            // drawing as its saved data. A new page tree serializes the live annotations.
            let pages = (0..<drawn.pageCount).compactMap { drawn.page(at: $0) }
            guard pages.count == boxes.count else { return nil }
            composed = PDFDocument()
            for (index, page) in pages.enumerated() { composed.insert(page, at: index) }
        } else {
            composed = drawn
        }
        // A link into the document points at a page of the old one; it is pointed at the same place in the new one.
        func moved(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let page = destination.page else { return nil }
            let index = document.index(for: page)
            guard index >= 0, index < boxes.count, let target = composed.page(at: index) else { return nil }
            let box = boxes[index]
            let point = destination.point
            // PDFKit marks an unspecified coordinate with a huge value, which must stay as it is.
            let x = point.x == kPDFDestinationUnspecifiedValue ? point.x : point.x - box.minX + shift(index)
            let y = point.y == kPDFDestinationUnspecifiedValue ? point.y : point.y - box.minY
            return composed.destination(on: target, at: CGPoint(x: x, y: y))
        }
        var bound: ReadingPDFNavigation.PageLinks = [:]
        for (index, box) in boxes.enumerated() {
            guard let source = document.page(at: index), let target = composed.page(at: index) else { continue }
            StandalonePage.retainSources(of: source, on: target)
            var slot = target.annotations.count
            for annotation in source.annotations {
                guard let copy = annotation.copy() as? PDFAnnotation else { return nil }
                copy.bounds = annotation.bounds.offsetBy(dx: shift(index) - box.minX, dy: -box.minY)
                var rebound = moved(annotation.destination)
                if let rebound { copy.destination = rebound }
                if let action = annotation.action as? PDFActionGoTo, let destination = moved(action.destination) {
                    copy.action = PDFActionGoTo(destination: destination)
                    rebound = destination
                }
                if rebuildingPageTree, let rebound, let page = rebound.page {
                    // These XYZ destinations were authored on the newly drawn pages. A
                    // copied annotation's backing array can still refer to the old page tree.
                    let record = ReadingPDFNavigationWriter.Destination(
                        page: composed.index(for: page), point: rebound.point, zoom: rebound.zoom)
                    bound[index, default: [:]][slot] = .init(
                        page: index, annotation: slot, bounds: copy.bounds, action: .internalDestination(record))
                }
                target.addAnnotation(copy)
                slot += 1
            }
        }
        if !bound.isEmpty { composed.binderNavigation = .bound(bound) }
        composed.inheritDisplayFallback(from: document)
        return composed
    }

    /// A style sample's whole page: `text`, the first page's text area, inside the margins over `paper`, if any.
    static func sample(text: PDFPage, paper: PDFPage?, pageSize: CGSize, margins: WebPaginator.Margins) -> PDFPage? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        context.beginPage(mediaBox: &mediaBox)
        if let paper {
            let box = paper.bounds(for: .cropBox).intersection(paper.bounds(for: .mediaBox))
            if box.width > 0, box.height > 0 {
                context.saveGState()
                context.scaleBy(x: pageSize.width / box.width, y: pageSize.height / box.height)
                paper.draw(with: .cropBox, to: context)
                context.restoreGState()
            }
        }
        // The text area's top left corner sits at the margins; PDF pages count upward from the bottom.
        let textBox = text.bounds(for: .cropBox)
        context.saveGState()
        context.translateBy(x: margins.left, y: pageSize.height - margins.top - textBox.height)
        text.draw(with: .cropBox, to: context)
        context.restoreGState()
        context.endPage()
        context.closePDF()
        return StandalonePage.first(of: data as Data)
    }
}
