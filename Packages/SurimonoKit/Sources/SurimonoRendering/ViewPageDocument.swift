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
            let scale = plan.scale(at: viewIndex)
            let transform = CGAffineTransform(scaleX: scale, y: scale)
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
                if scale != 1 || plan.number(at: viewIndex) != nil || !marks.isEmpty {
                    guard
                        let decorated = decoratedCopy(
                            original, number: plan.number(at: viewIndex), margin: margin, marks: marks, visibleBox: box,
                            scale: scale)
                    else { return nil }
                    page = decorated
                } else {
                    guard let copy = original.copy() as? PDFPage else { return nil }
                    page = copy
                }
                // Explicit annotation copies keep destination rewrites off the original page.
                for annotation in page.annotations { page.removeAnnotation(annotation) }
                for annotation in original.annotations {
                    guard let copy = annotationCopy(annotation, scale: scale) else { return nil }
                    page.addAnnotation(copy)
                }
                page.setBounds(box.applying(transform), for: .cropBox)
                result.insert(page, at: viewIndex)
            } else {
                guard let neighbor = plan.readingIndex(at: viewIndex), let page = source.page(at: neighbor) else {
                    return nil
                }
                let blank = PDFPage()
                blank.setBounds(page.bounds(for: .mediaBox).applying(transform), for: .mediaBox)
                blank.setBounds(page.bounds(for: .cropBox).applying(transform), for: .cropBox)
                blank.rotation = page.rotation
                result.insert(blank, at: viewIndex)
            }
        }
        func moved(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let page = destination.page,
                let index = plan.viewIndex(for: source.index(for: page)), let target = result.page(at: index)
            else { return nil }
            let scale = plan.scale(at: index)
            // Unspecified coordinates and zoom mean "keep the current value", not a position to scale.
            func scaled(_ value: CGFloat, by factor: CGFloat) -> CGFloat {
                value == kPDFDestinationUnspecifiedValue ? value : value * factor
            }
            let point = CGPoint(x: scaled(destination.point.x, by: scale), y: scaled(destination.point.y, by: scale))
            let copy = PDFDestination(page: target, at: point)
            copy.zoom = scaled(destination.zoom, by: 1 / scale)
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

    private static func annotationCopy(_ original: PDFAnnotation, scale: CGFloat) -> PDFAnnotation? {
        guard let copy = original.copy() as? PDFAnnotation else { return nil }
        guard scale != 1 else { return copy }
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        copy.bounds = original.bounds.applying(transform)
        if let points = original.quadrilateralPoints {
            copy.quadrilateralPoints = points.map { NSValue(point: $0.pointValue.applying(transform)) }
        }
        if original.type == "Line" {
            copy.startPoint = original.startPoint.applying(transform)
            copy.endPoint = original.endPoint.applying(transform)
        }
        // PDFAnnotation.copy can share mutable paths and drawing attributes with the source.
        if original.type == "Ink", let paths = original.paths {
            let affine = AffineTransform(scale: scale)
            for path in copy.paths ?? [] { copy.remove(path) }
            for path in paths {
                guard let scaled = path.copy() as? NSBezierPath else { return nil }
                scaled.transform(using: affine)
                scaled.lineWidth = path.lineWidth * scale
                scaled.flatness = path.flatness * scale
                var count = 0
                var phase: CGFloat = 0
                path.getLineDash(nil, count: &count, phase: &phase)
                if count > 0 {
                    var pattern = [CGFloat](repeating: 0, count: count)
                    path.getLineDash(&pattern, count: &count, phase: &phase)
                    scaled.setLineDash(pattern.map { $0 * scale }, count: count, phase: phase * scale)
                }
                copy.add(scaled)
            }
        }
        if let originalBorder = original.border {
            guard let border = originalBorder.copy() as? PDFBorder else { return nil }
            border.lineWidth = originalBorder.lineWidth * scale
            if let pattern = originalBorder.dashPattern as? [NSNumber] {
                border.dashPattern = pattern.map { NSNumber(value: $0.doubleValue * Double(scale)) }
            }
            copy.border = border
        }
        if let font = original.font {
            guard let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) else { return nil }
            copy.font = scaled
        }
        return copy
    }

    private static func decoratedCopy(
        _ original: PDFPage, number: Int?, margin: CGFloat, marks: [ChangeMark], visibleBox: CGRect, scale: CGFloat
    ) -> PDFPage? {
        guard let source = original.pageRef else { return nil }
        let media = original.bounds(for: .mediaBox)
        let crop = original.bounds(for: .cropBox)
        guard media.width > 0, media.height > 0, crop.width > 0, crop.height > 0 else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { return nil }
        let scaling = CGAffineTransform(scaleX: scale, y: scale)
        var box = media.applying(scaling)
        context.beginPage(mediaBox: &box)
        context.concatenate(scaling)
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
        page.setBounds(media.applying(scaling), for: .mediaBox)
        page.setBounds(crop.applying(scaling), for: .cropBox)
        page.rotation = original.rotation
        return page
    }

}
