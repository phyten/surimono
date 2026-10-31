import PDFKit
import SurimonoCore

/// Builds ordinary PDF pages, retaining vector text and separate annotations without editing the render result.
/// Numbers are baked into the view copy on the main actor, so PDFKit's tile workers need no application callbacks.
@MainActor
public enum ViewPageDocument {
    public static func make(
        _ source: PDFDocument, plan: ViewPageLayout, margin: CGFloat, changeMarks: [ChangeMark] = []
    ) -> PDFDocument? {
        let result = PDFDocument()
        for (viewIndex, logicalIndex) in plan.logicalIndices.enumerated() {
            if let logicalIndex {
                guard let original = source.page(at: logicalIndex) else { return nil }
                let crop = plan.crops(at: viewIndex)
                var box = original.bounds(for: .cropBox)
                let top = crop.top ? margin : 0
                let bottom = crop.bottom ? margin : 0
                let left = crop.left ? margin : 0
                let right = crop.right ? margin : 0
                if margin.isFinite, margin >= 0, top + bottom < box.height, left + right < box.width {
                    box.origin.x += left
                    box.origin.y += bottom
                    box.size.width -= left + right
                    box.size.height -= top + bottom
                }
                let page: PDFPage
                let marks = changeMarks.filter { $0.pageIndex == logicalIndex }
                if plan.number(at: viewIndex) != nil || !marks.isEmpty {
                    guard
                        let decorated = decoratedCopy(
                            original, number: plan.number(at: viewIndex), margin: margin, marks: marks, visibleBox: box)
                    else { return nil }
                    page = decorated
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
                page.setBounds(box, for: .cropBox)
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

    private static func decoratedCopy(
        _ original: PDFPage, number: Int?, margin: CGFloat, marks: [ChangeMark], visibleBox: CGRect
    ) -> PDFPage? {
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
        if let number { PageNumberDrawing.draw(number, in: displayed, margin: margin, context: context) }
        context.restoreGState()
        context.setFillColor(CGColor(srgbRed: 229.0 / 255, green: 83.0 / 255, blue: 61.0 / 255, alpha: 0.7))
        let textLeft = margin.isFinite && margin > 0 ? media.minX + margin : nil
        for mark in marks {
            let bar = mark.bar(in: visibleBox, textLeft: textLeft)
            if !bar.isNull, !bar.isEmpty { context.fill(bar) }
        }
        context.endPage()
        context.closePDF()
        guard let page = StandalonePage.first(of: data as Data) else { return nil }
        page.setBounds(media, for: .mediaBox)
        page.setBounds(crop, for: .cropBox)
        page.rotation = original.rotation
        return page
    }

}
