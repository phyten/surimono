import CoreGraphics
import Foundation
import PDFKit

/// Lays a theme's paper under pages laid out without it, so the paper covers the margins too (see `PaperBackground`).
enum PaperComposer {
    /// Each page of `document` drawn over `paper`, as vectors. The paper is stretched to each page, which it matches
    /// unless the page kept the paginator's allowance. Links and other annotations move along with their page.
    static func compose(_ document: PDFDocument, paper: PDFPage) -> PDFDocument? {
        let paperBox = paper.bounds(for: .cropBox).intersection(paper.bounds(for: .mediaBox))
        guard paperBox.width > 0, paperBox.height > 0 else { return nil }
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
            context.saveGState()
            context.scaleBy(x: box.width / paperBox.width, y: box.height / paperBox.height)
            paper.draw(with: .cropBox, to: context)
            context.restoreGState()
            page.draw(with: .cropBox, to: context)
            context.endPage()
        }
        context.closePDF()
        guard let composed = PDFDocument(data: data as Data), composed.pageCount == boxes.count else { return nil }
        // A link into the document points at a page of the old one; it is pointed at the same place in the new one.
        func moved(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let page = destination.page else { return nil }
            let index = document.index(for: page)
            guard index >= 0, index < boxes.count, let target = composed.page(at: index) else { return nil }
            let box = boxes[index]
            let point = destination.point
            // PDFKit marks an unspecified coordinate with a huge value, which must stay as it is.
            let x = point.x == kPDFDestinationUnspecifiedValue ? point.x : point.x - box.minX
            let y = point.y == kPDFDestinationUnspecifiedValue ? point.y : point.y - box.minY
            return PDFDestination(page: target, at: CGPoint(x: x, y: y))
        }
        for (index, box) in boxes.enumerated() {
            guard let source = document.page(at: index), let target = composed.page(at: index) else { continue }
            for annotation in source.annotations {
                guard let copy = annotation.copy() as? PDFAnnotation else { continue }
                copy.bounds = annotation.bounds.offsetBy(dx: -box.minX, dy: -box.minY)
                if let destination = moved(annotation.destination) { copy.destination = destination }
                if let action = annotation.action as? PDFActionGoTo, let destination = moved(action.destination) {
                    copy.action = PDFActionGoTo(destination: destination)
                }
                target.addAnnotation(copy)
            }
        }
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
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}
