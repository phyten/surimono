import PDFKit
import SurimonoCore

/// Builds ordinary PDF pages, retaining vector text and separate annotations without editing the render result.
/// Numbers are baked into the view copy on the main actor, so PDFKit's tile workers need no application callbacks.
@MainActor
public enum ViewPageDocument {
    public static func make(_ source: PDFDocument, plan: ViewPageLayout, margin: CGFloat) -> PDFDocument? {
        let result = PDFDocument()
        for (viewIndex, logicalIndex) in plan.logicalIndices.enumerated() {
            if let logicalIndex {
                guard let original = source.page(at: logicalIndex) else { return nil }
                let page: PDFPage
                if let number = plan.number(at: viewIndex) {
                    guard let numbered = numberedCopy(original, number: number, margin: margin) else { return nil }
                    page = numbered
                } else {
                    guard let copy = original.copy() as? PDFPage else { return nil }
                    page = copy
                }
                // Explicit annotation copies keep destination rewrites off the original page.
                for annotation in page.annotations { page.removeAnnotation(annotation) }
                for annotation in original.annotations {
                    guard let copy = annotation.copy() as? PDFAnnotation else { return nil }
                    page.addAnnotation(copy)
                }
                let crop = plan.crops(at: viewIndex)
                var box = page.bounds(for: .cropBox)
                let top = crop.top ? margin : 0
                let bottom = crop.bottom ? margin : 0
                let left = crop.left ? margin : 0
                let right = crop.right ? margin : 0
                if margin.isFinite, margin >= 0, top + bottom < box.height, left + right < box.width {
                    box.origin.x += left
                    box.origin.y += bottom
                    box.size.width -= left + right
                    box.size.height -= top + bottom
                    page.setBounds(box, for: .cropBox)
                }
                result.insert(page, at: viewIndex)
            } else {
                guard let neighbor = plan.readingIndex(at: viewIndex), let page = source.page(at: neighbor) else {
                    return nil
                }
                let blank = PDFPage()
                blank.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
                blank.setBounds(page.bounds(for: .cropBox), for: .cropBox)
                blank.rotation = page.rotation
                result.insert(blank, at: viewIndex)
            }
        }
        func moved(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let page = destination.page,
                let index = plan.viewIndex(for: source.index(for: page)), let target = result.page(at: index)
            else { return nil }
            let copy = PDFDestination(page: target, at: destination.point)
            copy.zoom = destination.zoom
            return copy
        }
        for index in 0..<result.pageCount {
            guard let page = result.page(at: index) else { continue }
            for annotation in page.annotations {
                if let action = annotation.action as? PDFActionGoTo, let target = moved(action.destination) {
                    annotation.action = PDFActionGoTo(destination: target)
                } else if let target = moved(annotation.destination) {
                    annotation.destination = target
                }
            }
        }
        return result
    }

    private static func numberedCopy(_ original: PDFPage, number: Int, margin: CGFloat) -> PDFPage? {
        guard let source = original.pageRef else { return nil }
        let media = original.bounds(for: .mediaBox)
        let crop = original.bounds(for: .cropBox)
        guard media.width > 0, media.height > 0, crop.width > 0, crop.height > 0 else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { return nil }
        var box = media
        context.beginPage(mediaBox: &box)
        // Draw the raw content stream, not PDFPage.draw, which would also paint annotations and apply rotation.
        // Keeping the original coordinate system preserves selection, annotation bounds and link destinations.
        context.drawPDFPage(source)
        let size = original.rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        let displayed = CGRect(origin: .zero, size: size)
        // Use PDFPage's current boxes and rotation, which may differ from its underlying CGPDFPage.
        let transform: CGAffineTransform
        switch (original.rotation % 360 + 360) % 360 {
        case 90:
            transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -crop.minY, ty: crop.maxX)
        case 180:
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: crop.maxX, ty: crop.maxY)
        case 270:
            transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: crop.maxY, ty: -crop.minX)
        default:
            transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        }
        context.saveGState()
        context.concatenate(transform.inverted())
        PageNumberDrawing.draw(number, in: displayed, margin: margin, context: context)
        context.restoreGState()
        context.endPage()
        context.closePDF()
        guard let page = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        page.setBounds(media, for: .mediaBox)
        page.setBounds(crop, for: .cropBox)
        page.rotation = original.rotation
        return page
    }

}
