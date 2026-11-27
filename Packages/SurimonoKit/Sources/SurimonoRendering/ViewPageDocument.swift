import ObjectiveC
import PDFKit
import SurimonoCore

@MainActor
extension PDFDocument {
    enum ViewPageOrigin {
        case file(Data)
        case typeset(Data?)
    }

    private static var viewPageOriginKey: UInt8 = 0

    var viewPageOrigin: ViewPageOrigin? {
        get { objc_getAssociatedObject(self, &Self.viewPageOriginKey) as? ViewPageOrigin }
        set { objc_setAssociatedObject(self, &Self.viewPageOriginKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// Builds ordinary PDF pages, retaining vector text and separate annotations without editing the render result.
/// Numbers and the printed header and footer are baked into the view copy on the main actor, so PDFKit's tile workers
/// need no application callbacks.
@MainActor
public enum ViewPageDocument {
    /// - Parameter furniture: The header and footer the sheets draw on a logical page, by its index. They are drawn as
    ///   shapes, so that a page's text, which selection, copying and find read, stays the page's own.
    /// - Parameter sharesResources: Draws the decorated pages into one PDF, whose pages share their fonts and other
    ///   resources, instead of one PDF a page. Tests compare the two.
    public static func make(
        _ source: PDFDocument, plan: ViewPageLayout, margin: CGFloat, changeMarks: [ChangeMark] = [],
        furniture: [Int: FurniturePlacement] = [:], sharesResources: Bool = true, furnitureAsText: Bool = false
    ) -> PDFDocument? {
        // What each decorated page draws, by its index in the copy.
        var decorations: [Int: Decoration] = [:]
        let origin = source.viewPageOrigin
        var needsPrivatePages = false
        let sourcePages = SourcePaperText.pageIndices(in: source)
        for (viewIndex, logicalIndex) in plan.logicalIndices.enumerated() {
            guard let logicalIndex else { continue }
            guard let original = source.page(at: logicalIndex) else { return nil }
            let scale = plan.scale(at: viewIndex)
            let marks = changeMarks.filter { $0.pageIndex == logicalIndex }
            let placement = furniture[logicalIndex]
            // The printed footer takes the place of the screen's own page number.
            let number = placement?.lines.bottom.contains { !$0.isEmpty } == true ? nil : plan.number(at: viewIndex)
            if scale == 1, number == nil, marks.isEmpty, placement == nil {
                let annotations = original.annotations
                guard !annotations.isEmpty || StandalonePage.hasStoredAnnotations(original) else { continue }
                // Reuse immutable page content when available. Only a typeset page without
                // those bytes needs drawing to isolate its local links from the view copy.
                guard original.pageRef != nil, case .typeset(nil) = origin,
                    annotations.contains(where: { link in
                        link.type == "Link"
                            && ((link.action as? PDFActionGoTo)?.destination ?? link.destination)?.page != nil
                    })
                else {
                    needsPrivatePages = true
                    continue
                }
            }
            decorations[viewIndex] = Decoration(
                original: original, number: number, outlinesNumber: sourcePages.contains(logicalIndex),
                furniture: placement, furnitureAsText: furnitureAsText,
                marks: marks,
                visibleBox: visibleBox(of: original, at: viewIndex, plan: plan, margin: margin), scale: scale)
        }
        guard let decorated = decoratedPages(decorations, margin: margin, sharesResources: sharesResources) else {
            return nil
        }
        // Editing the annotations of PDFPage.copy() can edit the source /Annots. Work on an
        // independent page tree. For an opened file its original bytes also retain the structure tree.
        let native: PDFDocument?
        var serializedLivePages = false
        switch origin {
        case .file(let bytes): native = PDFDocument(data: bytes)
        case .typeset(let bytes?) where needsPrivatePages: native = PDFDocument(data: bytes)
        default:
            serializedLivePages = needsPrivatePages
            native = needsPrivatePages ? source.dataRepresentation().flatMap(PDFDocument.init(data:)) : nil
        }
        if needsPrivatePages || native != nil {
            guard native?.pageCount == source.pageCount else { return nil }
        }
        let result = native ?? PDFDocument()
        // A copied link resolves page references against whichever document owns it.
        // Read its destination on the source before attaching the copy to a different PDF.
        var internalLinks: [(PDFAnnotation, PDFDestination, Int, Bool)] = []
        func rememberLink(_ original: PDFAnnotation, on copy: PDFAnnotation, onlyReplacedTargets: Bool = false) {
            let action = original.action as? PDFActionGoTo
            guard let destination = action?.destination ?? original.destination, let page = destination.page,
                let index = plan.viewIndex(for: source.index(for: page)),
                !onlyReplacedTargets || decorated[index] != nil
            else { return }
            internalLinks.append((copy, destination, index, action != nil))
        }
        var offsets: [Int: CGPoint] = [:]
        for (viewIndex, logicalIndex) in plan.logicalIndices.enumerated() {
            let scale = plan.scale(at: viewIndex)
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            if let logicalIndex {
                guard let original = source.page(at: logicalIndex) else { return nil }
                let box = visibleBox(of: original, at: viewIndex, plan: plan, margin: margin)
                let annotations = original.annotations
                let page: PDFPage
                if let decoratedPage = decorated[viewIndex] {
                    page = decoratedPage
                    StandalonePage.retainSources(of: original, on: page)
                    if native != nil { result.removePage(at: viewIndex) }
                    result.insert(page, at: viewIndex)
                } else if let native {
                    guard let existing = native.page(at: viewIndex) else { return nil }
                    page = existing
                    if case .file = origin {
                        // Native references follow inserted blanks. Only targets replaced by a
                        // decorated page need to be redirected in the private document.
                        if !decorated.isEmpty {
                            let copies = page.annotations
                            guard copies.count == annotations.count else { return nil }
                            for (original, copy) in zip(annotations, copies) {
                                rememberLink(original, on: copy, onlyReplacedTargets: true)
                            }
                        }
                        if page.bounds(for: .cropBox) != box { page.setBounds(box, for: .cropBox) }
                        continue
                    }
                    StandalonePage.retainSources(of: original, on: page)
                    if serializedLivePages {
                        // PDFKit can translate each page of an assembled binder independently on write.
                        let before = original.bounds(for: .mediaBox).origin
                        let after = page.bounds(for: .mediaBox).origin
                        if before != after {
                            offsets[viewIndex] = CGPoint(x: after.x - before.x, y: after.y - before.y)
                        }
                    }
                } else {
                    // Only an undecorated page without live or stored annotations uses a native copy.
                    guard let copy = StandalonePage.copy(of: original) else { return nil }
                    result.insert(copy, at: viewIndex)
                    copy.setBounds(box, for: .cropBox)
                    continue
                }
                // Some PDFKit versions reload a copied page's annotations on insertion.
                // Install the independent copies on the page in its final document.
                for annotation in page.annotations { page.removeAnnotation(annotation) }
                for annotation in annotations {
                    guard let copy = annotationCopy(annotation, scale: scale) else { return nil }
                    if let offset = offsets[viewIndex] {
                        copy.bounds = copy.bounds.offsetBy(dx: offset.x, dy: offset.y)
                    }
                    rememberLink(annotation, on: copy)
                    page.addAnnotation(copy)
                }
                let offset = offsets[viewIndex] ?? .zero
                page.setBounds(box.applying(transform).offsetBy(dx: offset.x, dy: offset.y), for: .cropBox)
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
        while result.pageCount > plan.logicalIndices.count { result.removePage(at: result.pageCount - 1) }
        func moved(_ destination: PDFDestination, to index: Int) -> PDFDestination? {
            guard let target = result.page(at: index) else { return nil }
            let scale = plan.scale(at: index)
            // Unspecified coordinates and zoom mean "keep the current value", not a position to scale.
            func scaled(_ value: CGFloat, by factor: CGFloat, offset: CGFloat = 0) -> CGFloat {
                value == kPDFDestinationUnspecifiedValue ? value : value * factor + offset
            }
            let offset = offsets[index] ?? .zero
            let point = CGPoint(
                x: scaled(destination.point.x, by: scale, offset: offset.x),
                y: scaled(destination.point.y, by: scale, offset: offset.y))
            let copy = result.destination(on: target, at: point)
            copy.zoom = scaled(destination.zoom, by: 1 / scale)
            return copy
        }
        for (annotation, original, index, usesAction) in internalLinks {
            guard let target = moved(original, to: index) else { return nil }
            if usesAction {
                annotation.action = PDFActionGoTo(destination: target)
            } else {
                annotation.destination = target
            }
        }
        result.inheritDisplayFallback(from: source)
        return sourcePages.isEmpty ? result : StandalonePage.selectableDocument(result)
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

    /// The part of a page the copy shows: its crop box, less the margins cut where pages are joined.
    private static func visibleBox(of original: PDFPage, at viewIndex: Int, plan: ViewPageLayout, margin: CGFloat)
        -> CGRect
    {
        let crop = plan.crops(at: viewIndex)
        var box = original.bounds(for: .cropBox)
        let top = crop.top ? margin : 0
        let bottom = crop.bottom ? margin : 0
        if margin.isFinite, margin >= 0, top + bottom < box.height {
            box.origin.y += bottom
            box.size.height -= top + bottom
        }
        return box
    }

    private struct Decoration {
        let original: PDFPage
        let number: Int?
        let outlinesNumber: Bool
        let furniture: FurniturePlacement?
        let furnitureAsText: Bool
        let marks: [ChangeMark]
        let visibleBox: CGRect
        let scale: CGFloat
    }

    /// A typeset page whose annotations will be placed again in its original coordinate system.
    static func contentPage(of original: PDFPage) -> PDFPage? {
        let decoration = Decoration(
            original: original, number: nil, outlinesNumber: false, furniture: nil, furnitureAsText: false,
            marks: [], visibleBox: original.bounds(for: .cropBox), scale: 1)
        return decoratedPages([0: decoration], margin: 0, sharesResources: false)?[0]
    }

    /// Draws the decorated pages and reads them back, by their index in the copy. In one PDF, the pages that draw the
    /// same fonts share them; a PDF a page embeds them again on every page.
    private static func decoratedPages(
        _ decorations: [Int: Decoration], margin: CGFloat, sharesResources: Bool
    ) -> [Int: PDFPage]? {
        let order = decorations.keys.sorted()
        var pages: [Int: PDFPage] = [:]
        if sharesResources {
            guard !order.isEmpty else { return [:] }
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                let context = CGContext(consumer: consumer, mediaBox: nil, nil)
            else { return nil }
            for viewIndex in order {
                guard let decoration = decorations[viewIndex], draw(decoration, margin: margin, in: context) else {
                    return nil
                }
            }
            context.closePDF()
            guard let document = PDFDocument(data: data as Data), document.pageCount == order.count else { return nil }
            // The pages leave this document, which is not kept; each keeps the CoreGraphics document behind it.
            for (offset, viewIndex) in order.enumerated() {
                guard let page = document.page(at: offset), let decoration = decorations[viewIndex] else { return nil }
                StandalonePage.retainSources(of: page, on: page)
                finish(page, as: decoration)
                pages[viewIndex] = page
            }
            return withExtendedLifetime(document) { pages }
        }
        for viewIndex in order {
            guard let decoration = decorations[viewIndex] else { return nil }
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                let context = CGContext(consumer: consumer, mediaBox: nil, nil),
                draw(decoration, margin: margin, in: context)
            else { return nil }
            context.closePDF()
            guard let page = StandalonePage.first(of: data as Data) else { return nil }
            finish(page, as: decoration)
            pages[viewIndex] = page
        }
        return pages
    }

    /// The decorated page's boxes and rotation, which the drawing leaves out.
    private static func finish(_ page: PDFPage, as decoration: Decoration) {
        let original = decoration.original
        let scaling = CGAffineTransform(scaleX: decoration.scale, y: decoration.scale)
        let crop = original.bounds(for: .cropBox)
        page.setBounds(original.bounds(for: .mediaBox).applying(scaling), for: .mediaBox)
        page.setBounds(crop.applying(scaling), for: .cropBox)
        // Absent production boxes follow the crop, including a later crop at a page seam.
        for (box, key): (PDFDisplayBox, String) in [
            (.bleedBox, "BleedBox"), (.trimBox, "TrimBox"), (.artBox, "ArtBox"),
        ] {
            let bounds = original.bounds(for: box)
            if bounds != crop || original.pageRef?.dictionary.map({ CGPDFDictionaryGetArray($0, key, nil) }) == true {
                page.setBounds(bounds.applying(scaling), for: box)
            }
        }
        page.rotation = original.rotation
    }

    /// Draws one decorated page as a page of `context`.
    private static func draw(_ decoration: Decoration, margin: CGFloat, in context: CGContext) -> Bool {
        let original = decoration.original
        let number = decoration.number
        let furniture = decoration.furniture
        let marks = decoration.marks
        let visibleBox = decoration.visibleBox
        guard let source = original.pageRef else { return false }
        let media = original.bounds(for: .mediaBox)
        let crop = original.bounds(for: .cropBox)
        guard media.width > 0, media.height > 0, crop.width > 0, crop.height > 0 else { return false }
        let scaling = CGAffineTransform(scaleX: decoration.scale, y: decoration.scale)
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
        if let number {
            PageNumberDrawing.draw(
                number, in: displayed, margin: margin, asOutlines: decoration.outlinesNumber, context: context)
        }
        if let furniture {
            PDFComposer.draw(furniture, in: displayed, asOutlines: !decoration.furnitureAsText, context: context)
        }
        context.restoreGState()
        if let hex = marks.first?.backgroundHex, let color = CodeColor.components(hex) {
            context.setBlendMode(.multiply)
            context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
            for mark in marks {
                let rect = mark.highlight(in: visibleBox)
                if !rect.isNull, !rect.isEmpty { context.addRect(rect) }
            }
            // A single fill leaves overlapping block highlights the same shade.
            context.fillPath()
        }
        context.setBlendMode(.normal)
        for mark in marks {
            mark.textDrawing?.paint(mark, clippedTo: visibleBox, in: context)
            if mark.emphasizesEdge {
                let rect = mark.highlight(in: visibleBox)
                guard !rect.isNull, !rect.isEmpty else { continue }
                // A rule outside the changed block is visible even on a very pale tint and leaves its glyphs intact.
                let edge = CGRect(x: rect.minX - 2, y: rect.minY, width: 2, height: rect.height)
                context.setFillColor(CGColor(gray: 0.2, alpha: 1))
                let visibleEdge = edge.intersection(visibleBox)
                if !visibleEdge.isEmpty { context.fill(visibleEdge) }
            }
        }
        context.endPage()
        return true
    }

}
