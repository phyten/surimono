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
    private static var contentBottomCacheKey: UInt8 = 0

    var viewPageOrigin: ViewPageOrigin? {
        get { objc_getAssociatedObject(self, &Self.viewPageOriginKey) as? ViewPageOrigin }
        set { objc_setAssociatedObject(self, &Self.viewPageOriginKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    final class ContentBottomCache {
        struct Entry {
            weak var page: PDFPage?
            let cropBox: CGRect
            let rotation: Int
            let bottom: CGFloat?
        }
        var margin: CGFloat = -1
        var entries: [Int: Entry] = [:]
    }

    var contentBottomCache: ContentBottomCache {
        if let existing = objc_getAssociatedObject(self, &Self.contentBottomCacheKey) as? ContentBottomCache {
            return existing
        }
        let cache = ContentBottomCache()
        objc_setAssociatedObject(self, &Self.contentBottomCacheKey, cache, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return cache
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
                guard !annotations.isEmpty || StandalonePage.hasStoredAnnotations(original) else {
                    // PDFPage.copy() shares its page dictionary with the source: a crop box set on the copy is
                    // written whenever the source is saved, the reading PDF among others. A page the view cuts is
                    // cut in a private page tree.
                    if visibleBox(of: original, at: viewIndex, plan: plan, margin: margin)
                        != original.bounds(for: .cropBox)
                    {
                        needsPrivatePages = true
                    }
                    continue
                }
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
                    // Only an undecorated, uncut page without live or stored annotations uses a native copy, which is
                    // never edited: its bounds would be the source's too.
                    guard let copy = StandalonePage.copy(of: original) else { return nil }
                    result.insert(copy, at: viewIndex)
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

    /// Measures the distance from the bottom of each requested page's crop box to its lowest drawn content (in points).
    ///
    /// Conservative by design: blank pages, rotated pages, oversized pages, pages without a verifiable margin band
    /// (`margin < 4` pt), and pages whose background varies vertically (grids, dot grids, gradients) are omitted so they
    /// keep their normal margin crop. A `ChangeMark` can only extend the protected area downward; it never causes an
    /// unmeasured page to be trimmed.
    ///
    /// Results for the underlying PDF pages are cached on `source` under the contract that `source` is a read-only
    /// snapshot (`PreparedRender.viewDocument`, `ReadingPreview.document`, `ThemeTrial.document`), while each entry also
    /// verifies page object identity, crop box, and rotation.
    public static func contentBottoms(
        of source: PDFDocument, pages: [Int], margin: CGFloat, changeMarks: [ChangeMark] = []
    ) -> [Int: CGFloat] {
        guard !pages.isEmpty, margin.isFinite, margin >= 4 else { return [:] }
        let cache = source.contentBottomCache
        if cache.margin != margin {
            cache.margin = margin
            cache.entries.removeAll(keepingCapacity: true)
        }
        let marksByPage = Dictionary(grouping: changeMarks, by: \.pageIndex)
        var scratchPixels: [UInt8] = []
        var result: [Int: CGFloat] = [:]
        for index in pages {
            guard let page = source.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            let rotation = page.rotation
            let measured: CGFloat?
            if let entry = cache.entries[index], entry.page === page, entry.cropBox == box, entry.rotation == rotation {
                measured = entry.bottom
            } else {
                let value = measureContentBottom(of: page, margin: margin, scratchPixels: &scratchPixels)
                cache.entries[index] = .init(page: page, cropBox: box, rotation: rotation, bottom: value)
                measured = value
            }
            // When measurement declined to trim (blank, rotated, patterned, or oversized), never fabricate a trim from
            // a change mark alone.
            guard var bottom = measured else { continue }
            if let marks = marksByPage[index] {
                for mark in marks {
                    let rect = mark.highlight(in: box)
                    guard !rect.isNull, !rect.isEmpty else { continue }
                    let markBottom = rect.minY - box.minY
                    if markBottom >= 0 { bottom = min(bottom, markBottom) }
                }
            }
            result[index] = bottom
        }
        return result
    }

    /// Renders `page` at 1 pt resolution to find the lowest row above the bottom margin that differs at all from a
    /// verified vertically-uniform paper background.
    private static func measureContentBottom(
        of page: PDFPage, margin: CGFloat, scratchPixels: inout [UInt8]
    ) -> CGFloat? {
        guard page.rotation == 0, let pageRef = page.pageRef else { return nil }
        let box = page.bounds(for: .cropBox)
        let maxDimension: CGFloat = 8192
        let maxPixels = 16_000_000
        guard box.width.isFinite, box.height.isFinite, box.minX.isFinite, box.minY.isFinite,
            box.width >= 1, box.height >= 1, box.width <= maxDimension, box.height <= maxDimension,
            margin.isFinite, margin >= 4, margin < box.height, margin < box.width,
            let width = Int(exactly: box.width.rounded(.up)),
            let height = Int(exactly: box.height.rounded(.up)),
            let scanWidth = Int(exactly: box.width.rounded(.down)),
            let scanHeight = Int(exactly: box.height.rounded(.down)),
            let marginPoints = Int(exactly: margin.rounded(.down)),
            width > 0, height > 0, scanWidth > 0, scanHeight > 0,
            width * height <= maxPixels,
            marginPoints >= 4, marginPoints * 2 < scanHeight, marginPoints * 2 < scanWidth
        else { return nil }
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        if scratchPixels.count < byteCount {
            scratchPixels = [UInt8](repeating: 255, count: byteCount)
        }
        let drawn = scratchPixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(pageRef)
            return true
        }
        guard drawn else { return nil }
        return scratchPixels.withUnsafeBufferPointer { pixels -> CGFloat? in
            guard let base = pixels.baseAddress else { return nil }
            // Memory row 0 is the top of the bitmap; `y` counts upward in points from `box.minY`.
            @inline(__always) func rowOffset(_ y: Int) -> Int { (height - 1 - y) * bytesPerRow }
            let reference = base + rowOffset(0)
            // The canvas is filled with opaque white before drawing, so alpha stays 255 on every pixel and memcmp
            // compares exact RGB equality across a span in one pass.
            @inline(__always) func matches(_ row: Int, startColumn: Int, columnCount: Int) -> Bool {
                let offset = startColumn * 4
                return memcmp(base + row + offset, reference + offset, columnCount * 4) == 0
            }
            // Verify vertical paper uniformity across the bottom margin, the top margin, and narrow outer strips along
            // the full height of both side margins. Any 2D grid, dot grid, gradient, or margin ink fails here and leaves
            // the page untrimmed.
            for y in 1..<(marginPoints - 1) {
                if !matches(rowOffset(y), startColumn: 0, columnCount: scanWidth) { return nil }
            }
            for y in (scanHeight - marginPoints + 1)..<scanHeight {
                if !matches(rowOffset(y), startColumn: 0, columnCount: scanWidth) { return nil }
            }
            let edgeWidth = min(marginPoints - 1, 8)
            let rightStart = scanWidth - edgeWidth
            for y in (marginPoints - 1)...(scanHeight - marginPoints) {
                let row = rowOffset(y)
                if !matches(row, startColumn: 0, columnCount: edgeWidth)
                    || !matches(row, startColumn: rightStart, columnCount: edgeWidth)
                {
                    return nil
                }
            }
            // Any pixel that differs from the verified paper reference counts as drawn, preserving faint boxes and rules.
            for y in marginPoints..<scanHeight {
                if !matches(rowOffset(y), startColumn: 0, columnCount: scanWidth) { return CGFloat(y) }
            }
            return nil
        }
    }

    /// The part of a page the copy shows: its crop box, less the margins and unused seam paper cut where pages join.
    private static func visibleBox(of original: PDFPage, at viewIndex: Int, plan: ViewPageLayout, margin: CGFloat)
        -> CGRect
    {
        var box = original.bounds(for: .cropBox)
        let insets = plan.cropInsets(at: viewIndex, pageHeight: box.height, margin: margin)
        if insets.top + insets.bottom > 0, insets.top + insets.bottom < box.height {
            box.origin.y += insets.bottom
            box.size.height -= insets.top + insets.bottom
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
