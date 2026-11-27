import CoreGraphics
import Foundation
import PDFKit
import SurimonoCore

/// Measures actual print rectangles, then removes only the space reserved beside reference lines.
@MainActor
enum FootnotePlacer {
    enum PlacementError: Error {
        case ambiguousMarkers, invalidGeometry, cannotDraw
        /// Something is drawn in the room of the line whose first reference this is; its notes cannot move.
        case inkInBand(firstReference: Int)
    }

    struct Stock {
        let number: Int
        let page: Int
        let rect: CGRect
    }

    struct Location {
        let page: Int
        let rect: CGRect
    }

    struct Measurement {
        let stock: [Stock]
        let references: [Int: Location]
        /// How far a destination lies above the box it names. The paginator trims a strip off each page after
        /// WebKit wrote the destinations, so they sit that strip higher than the annotations' own bounds.
        var destinationLift: CGFloat = 0
        var firstStockPage: Int { stock.map(\.page).min() ?? 0 }
    }

    /// Recover a Quartz stock link even if its /Dest object was never written. The
    /// two original corner marks, reserve and references all name the same object.
    nonisolated static func recoverStock(in data: Data, expected: [WebPaginator.FootnotePass.Note]) throws -> Data? {
        typealias Writer = ReadingPDFNavigationWriter
        typealias Mark = Writer.AnnotationLocation
        guard !expected.isEmpty else { return nil }
        return try Writer.restoringMissingDestinations(in: data) { marksByDestination in
            // Stock follows the body. Each note is unbroken, with its two square marks on
            // the same left edge. Its optional reservation mark and every reference precede stock.
            let groups = marksByDestination.compactMap {
                id, marks -> (id: Writer.Ref, top: Mark, bottom: Mark, body: [Mark])? in
                guard let last = marks.last?.page else { return nil }
                let stock = marks.filter { $0.page == last }.sorted { $0.bounds.maxY > $1.bounds.maxY }
                guard stock.count == 2, stock.allSatisfy({ isSquare($0.bounds) }),
                    abs(stock[0].bounds.minX - stock[1].bounds.minX) < 0.25,
                    abs(stock[0].bounds.width - stock[1].bounds.width) < 0.25,
                    stock[0].bounds.minY >= stock[1].bounds.maxY
                else { return nil }
                return (id, stock[0], stock[1], marks.filter { $0.page < last })
            }.sorted { a, b in
                a.top.page == b.top.page ? a.top.bounds.maxY > b.top.bounds.maxY : a.top.page < b.top.page
            }
            guard groups.count == expected.count, let first = groups.first?.top.page else { return [:] }
            var destinations: [Writer.Ref: Writer.Destination] = [:]
            for (i, group) in groups.enumerated() {
                let note = expected[i]
                let reserves = group.body.filter { isSquare($0.bounds) }.count
                guard group.body.allSatisfy({ $0.page < first }), note.references > 0,
                    group.body.count - reserves == note.references, reserves == (note.reservesRoom ? 1 : 0)
                else { return [:] }
                if i > 0, groups[i - 1].top.page == group.top.page,
                    groups[i - 1].bottom.bounds.minY < group.top.bounds.maxY
                {
                    return [:]
                }
                let top = group.top
                destinations[group.id] = .init(
                    page: top.page, mode: "XYZ", arguments: [top.bounds.minX, top.bounds.maxY, nil])
            }
            return destinations
        }
    }

    static func measure(_ document: PDFDocument, plan: PageFootnotes.Plan, placing: Set<Int>) throws -> Measurement {
        var marks: [(page: Int, annotation: PDFAnnotation)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw PlacementError.ambiguousMarkers }
            for annotation in page.annotations where isSquare(annotation) {
                guard let target = destination(annotation), target.page === page else { continue }
                marks.append((index, annotation))
            }
        }
        marks.sort {
            precedes(
                Location(page: $0.page, rect: $0.annotation.bounds), Location(page: $1.page, rect: $1.annotation.bounds)
            )
        }
        let numbers = plan.stockNumbers(placing: placing)
        guard !numbers.isEmpty, marks.count == numbers.count * 2 else { throw PlacementError.ambiguousMarkers }
        var stock: [Stock] = []
        guard let firstMark = marks.first, let firstTarget = destination(firstMark.annotation) else {
            throw PlacementError.ambiguousMarkers
        }
        let lift = firstTarget.point.y - firstMark.annotation.bounds.maxY
        guard abs(lift) <= 6 else { throw PlacementError.ambiguousMarkers }
        for (index, number) in numbers.enumerated() {
            let top = marks[index * 2]
            let bottom = marks[index * 2 + 1]
            guard top.page == bottom.page,
                let first = destination(top.annotation), let last = destination(bottom.annotation),
                abs(first.point.y - last.point.y) < 1,
                let page = document.page(at: top.page)
            else { throw PlacementError.ambiguousMarkers }
            let box = page.bounds(for: .mediaBox)
            let rect = CGRect(
                x: box.minX, y: bottom.annotation.bounds.minY,
                width: box.width, height: top.annotation.bounds.maxY - bottom.annotation.bounds.minY)
            guard rect.height > 0, rect.minY >= box.minY, rect.maxY <= box.maxY,
                first.point.y - lift >= rect.minY - 1, first.point.y - lift <= rect.maxY + 1
            else {
                throw PlacementError.ambiguousMarkers
            }
            stock.append(Stock(number: number, page: top.page, rect: rect))
        }
        guard let start = stock.first?.page, start > 0 else { throw PlacementError.ambiguousMarkers }
        var found: [Int: [Location]] = [:]
        for index in 0..<start {
            guard let page = document.page(at: index) else { throw PlacementError.ambiguousMarkers }
            for annotation in page.annotations where !isSquare(annotation) {
                guard let note = stockTarget(annotation, in: document, stock: stock, lift: lift) else { continue }
                found[note.number, default: []].append(Location(page: index, rect: annotation.bounds))
            }
        }
        var references: [Int: Location] = [:]
        for number in numbers {
            let expected = plan.references.filter { $0.note == number }
            let locations = (found[number] ?? []).sorted(by: precedes)
            // An unexpected link to a note, a hidden reference, or a split annotation makes positional matching unsafe.
            guard locations.count == expected.count else { throw PlacementError.ambiguousMarkers }
            for (reference, location) in zip(expected, locations) { references[reference.index] = location }
        }
        return Measurement(stock: stock, references: references, destinationLift: lift)
    }

    static func groups(
        for measured: Measurement, plan: PageFootnotes.Plan, contentHeight: CGFloat, textScale: Double
    ) throws -> [PageFootnotes.Group] {
        guard contentHeight > 0, textScale.isFinite, textScale > 0 else { throw PlacementError.invalidGeometry }
        var seen: Set<Int> = []
        var lines: [(first: Int, location: Location, notes: [Int])] = []
        for reference in plan.references where reference.eligible {
            guard seen.insert(reference.note).inserted else { continue }
            guard let location = measured.references[reference.index] else { throw PlacementError.ambiguousMarkers }
            if let index = lines.firstIndex(where: { sameLine($0.location, location) }) {
                lines[index].notes.append(reference.note)
            } else {
                lines.append((reference.index, location, [reference.note]))
            }
        }
        let heights = Dictionary(uniqueKeysWithValues: measured.stock.map { ($0.number, $0.rect.height) })
        return lines.compactMap { line in
            let height = line.notes.reduce(CGFloat.zero) { $0 + (heights[$1] ?? 0) }
            guard height <= contentHeight * 0.45 else { return nil }
            return PageFootnotes.Group(
                firstReference: line.first, notes: line.notes,
                heightPixels: FootnoteGeometry.reservePixels(
                    height: height + FootnoteGeometry.groupRoom,
                    pixelsPerPoint: WebPaginator.printPixelsPerPoint, textScale: textScale))
        }
    }

    private struct PageLayout {
        let geometry: FootnoteGeometry
        let notes: [Stock]
        let bottoms: [CGFloat]
        let reserved: CGFloat
    }

    struct Composition {
        let document: PDFDocument
        let geometry: [Int: FootnoteGeometry]

        func bodyLocation(_ target: PrintedFragmentLinks.Region) -> PrintedFragmentLinks.Region? {
            guard target.page < document.pageCount else { return nil }
            guard let layout = geometry[target.page] else { return target }
            guard let shift = layout.shift(at: target.bounds.midY) else { return nil }
            return .init(page: target.page, bounds: target.bounds.offsetBy(dx: 0, dy: shift))
        }
    }

    static func compose(
        _ document: PDFDocument, plan: PageFootnotes.Plan, groups: [PageFootnotes.Group], margins: WebPaginator.Margins
    ) throws -> PDFDocument {
        try composition(document, plan: plan, groups: groups, margins: margins).document
    }

    static func composition(
        _ document: PDFDocument, annotationSource: PDFDocument? = nil, plan: PageFootnotes.Plan,
        groups: [PageFootnotes.Group], margins: WebPaginator.Margins
    ) throws -> Composition {
        let measured = try measure(document, plan: plan, placing: Set(groups.flatMap(\.notes)))
        let layouts = try layouts(document, measured: measured, plan: plan, groups: groups, margins: margins)
        let output = PDFDocument()
        let links = annotationSource ?? document
        for index in 0..<measured.firstStockPage {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw PlacementError.cannotDraw }
            let copy: PDFPage
            if let layout = layouts[index] {
                copy = try redraw(page, layout: layout, document: document, margins: margins)
            } else if StandalonePage.hasStoredAnnotations(page) || !page.annotations.isEmpty
                || links.page(at: index)?.annotations.isEmpty == false
            {
                guard let content = ViewPageDocument.contentPage(of: page) else { throw PlacementError.cannotDraw }
                copy = content
            } else {
                guard let duplicated = StandalonePage.copy(of: page) else { throw PlacementError.cannotDraw }
                copy = duplicated
            }
            output.insert(copy, at: output.pageCount)
        }
        // The raw print determines all placement. Only copy the reader's annotations
        // after the reserved bands have been measured, checked for ink and drawn.
        for index in 0..<output.pageCount {
            guard let source = links.page(at: index), let target = output.page(at: index) else {
                throw PlacementError.cannotDraw
            }
            try carryAnnotations(
                from: source, to: target, clip: source.bounds(for: .mediaBox),
                shift: nil, geometry: layouts[index]?.geometry, original: links, output: output, layouts: layouts,
                lift: measured.destinationLift)
            if let layout = layouts[index] {
                for (note, bottom) in zip(layout.notes, layout.bottoms) {
                    guard let stockPage = links.page(at: note.page) else { throw PlacementError.cannotDraw }
                    try carryAnnotations(
                        from: stockPage, to: target, clip: note.rect,
                        shift: bottom - note.rect.minY, geometry: nil, original: links, output: output,
                        layouts: layouts, lift: measured.destinationLift)
                }
            }
        }
        return Composition(document: output, geometry: layouts.mapValues(\.geometry))
    }

    private static func layouts(
        _ document: PDFDocument, measured: Measurement, plan: PageFootnotes.Plan,
        groups: [PageFootnotes.Group], margins: WebPaginator.Margins
    ) throws -> [Int: PageLayout] {
        var bands: [Int: [FootnoteGeometry.Band]] = [:]
        var notes: [Int: [Stock]] = [:]
        // What bare paper looks like is read where no text of the document can be: the row under the last note of
        // the stock, on a page the reader never sees. Sampling the page of the text itself could take a picture's
        // colour for the paper's.
        guard let last = measured.stock.max(by: { ($0.page, -$0.rect.minY) < ($1.page, -$1.rect.minY) }),
            let stockPage = document.page(at: last.page),
            last.rect.minY - 3 > stockPage.bounds(for: .mediaBox).minY + margins.bottom,
            let paper = raster(of: stockPage, bottom: last.rect.minY - 3, height: 1)
        else { throw PlacementError.invalidGeometry }
        for group in groups {
            guard let location = measured.references[group.firstReference], let firstNote = group.notes.first,
                let page = document.page(at: location.page)
            else { throw PlacementError.ambiguousMarkers }
            for number in group.notes {
                guard let reference = plan.references.first(where: { $0.note == number && $0.eligible }),
                    let other = measured.references[reference.index], sameLine(location, other),
                    let stock = measured.stock.first(where: { $0.number == number })
                else {
                    throw PlacementError.ambiguousMarkers
                }
                notes[location.page, default: []].append(stock)
            }
            let marks = page.annotations.filter {
                isSquare($0)
                    && stockTarget($0, in: document, stock: measured.stock, lift: measured.destinationLift)?.number
                        == firstNote
            }
            guard marks.count == 1, let mark = marks.first else { throw PlacementError.ambiguousMarkers }
            // The marker also measures effective CSS zoom and any print scaling in this pass.
            let height = CGFloat(group.heightPixels) * mark.bounds.height / 4
            // The band that is cut out is the one that is checked for ink: whole points, a little inside the room so
            // that a descender of the line above or the top of the line below stays on the page.
            let band = FootnoteGeometry.Band(
                bottom: mark.bounds.minY + FootnoteGeometry.bandInset,
                height: (height - FootnoteGeometry.bandInset * 2).rounded(.down))
            guard band.height >= 1 else { throw PlacementError.invalidGeometry }
            guard band.bottom < location.rect.minY, band.bottom + height <= location.rect.minY + 2 else {
                throw PlacementError.invalidGeometry
            }
            // Something beside the line (a float, a drop cap) may reach into the room; cutting it out would lose it.
            guard isBlank(band, of: page, paper: paper) else {
                throw PlacementError.inkInBand(firstReference: group.firstReference)
            }
            bands[location.page, default: []].append(band)
        }
        var result: [Int: PageLayout] = [:]
        for (index, pageBands) in bands {
            guard let page = document.page(at: index) else { throw PlacementError.invalidGeometry }
            let box = page.bounds(for: .mediaBox)
            let reserved = pageBands.reduce(CGFloat.zero) { $0 + $1.height }
            let pageNotes = notes[index] ?? []
            guard pageBands.allSatisfy({ $0.bottom >= box.minY + margins.bottom }),
                let geometry = FootnoteGeometry(lower: box.minY, upper: box.maxY, bands: pageBands),
                let bottoms = FootnoteGeometry.noteBottoms(
                    heights: pageNotes.map { $0.rect.height },
                    bottom: box.minY + margins.bottom, reserved: reserved)
            else { throw PlacementError.invalidGeometry }
            result[index] = PageLayout(geometry: geometry, notes: pageNotes, bottoms: bottoms, reserved: reserved)
        }
        return result
    }

    private static func redraw(
        _ page: PDFPage, layout: PageLayout, document: PDFDocument, margins: WebPaginator.Margins
    ) throws -> PDFPage {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil), let original = page.pageRef
        else {
            throw PlacementError.cannotDraw
        }
        var box = page.bounds(for: .mediaBox)
        context.beginPage(mediaBox: &box)
        // Clipped redraws repeat PDF text extraction on these beta pages. Vector appearance and page membership stay.
        for segment in layout.geometry.segments {
            context.saveGState()
            context.clip(
                to: CGRect(
                    x: box.minX, y: segment.lower + segment.shift,
                    width: box.width, height: segment.upper - segment.lower))
            context.translateBy(x: 0, y: segment.shift)
            context.drawPDFPage(original)
            context.restoreGState()
        }
        let ruleY =
            box.minY + margins.bottom + layout.notes.reduce(CGFloat.zero) { $0 + $1.rect.height }
            + FootnoteGeometry.ruleRoom / 2
        context.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: box.minX + margins.left, y: ruleY))
        context.addLine(
            to: CGPoint(x: box.minX + margins.left + (box.width - margins.left - margins.right) / 3, y: ruleY))
        context.strokePath()
        for (note, bottom) in zip(layout.notes, layout.bottoms) {
            guard let source = document.page(at: note.page), let reference = source.pageRef else {
                throw PlacementError.cannotDraw
            }
            context.saveGState()
            let dx = box.minX - note.rect.minX
            context.clip(to: CGRect(x: box.minX, y: bottom, width: box.width, height: note.rect.height))
            context.translateBy(x: dx, y: bottom - note.rect.minY)
            context.drawPDFPage(reference)
            context.restoreGState()
        }
        context.endPage()
        context.closePDF()
        guard let result = StandalonePage.first(of: data as Data) else { throw PlacementError.cannotDraw }
        result.setBounds(box, for: .mediaBox)
        result.setBounds(page.bounds(for: .cropBox), for: .cropBox)
        StandalonePage.retainSources(of: page, on: result)
        for note in layout.notes {
            if let source = document.page(at: note.page) { StandalonePage.retainSources(of: source, on: result) }
        }
        return result
    }

    private static func carryAnnotations(
        from source: PDFPage, to target: PDFPage, clip: CGRect, shift: CGFloat?, geometry: FootnoteGeometry?,
        original: PDFDocument, output: PDFDocument, layouts: [Int: PageLayout], lift: CGFloat
    ) throws {
        for annotation in source.annotations {
            let visible = annotation.bounds.intersection(clip)
            guard !visible.isEmpty, !visible.isNull else { continue }
            // All private markers and references to stock pages disappear, including later references.
            if let destination = destination(annotation), let page = destination.page,
                original.index(for: page) >= output.pageCount
            {
                continue
            }
            let pieces: [(CGRect, CGFloat)]
            if let geometry {
                pieces = geometry.segments.compactMap { segment in
                    let piece = visible.intersection(
                        CGRect(
                            x: clip.minX, y: segment.lower,
                            width: clip.width, height: segment.upper - segment.lower))
                    return piece.isNull || piece.isEmpty ? nil : (piece, segment.shift)
                }
            } else {
                pieces = [(visible, shift ?? 0)]
            }
            for (rect, dy) in pieces {
                guard let copy = annotation.copy() as? PDFAnnotation else { throw PlacementError.cannotDraw }
                let dx = target.bounds(for: .mediaBox).minX - source.bounds(for: .mediaBox).minX
                copy.bounds = rect.offsetBy(dx: dx, dy: dy)
                if let old = destination(annotation), let oldPage = old.page {
                    let index = original.index(for: oldPage)
                    guard let newPage = output.page(at: index) else { continue }
                    var point = old.point
                    if point.y != kPDFDestinationUnspecifiedValue {
                        // The shift is looked up where the target is drawn, which lies `lift` below its destination.
                        point.y += layouts[index]?.geometry.shift(at: point.y - lift) ?? 0
                    }
                    let moved = output.destination(on: newPage, at: point)
                    if annotation.action is PDFActionGoTo {
                        copy.action = PDFActionGoTo(destination: moved)
                    } else {
                        copy.destination = moved
                    }
                }
                target.addAnnotation(copy)
            }
        }
        StandalonePage.retainSources(of: source, on: target)
    }

    /// Whether cutting the band out of the page loses nothing: all of it is bare paper. A tinted box or a picture
    /// counts as drawn even where every row of it looks the same, since a shorter bar is a different bar.
    static func isBlank(_ band: FootnoteGeometry.Band, of page: PDFPage, paper: [UInt8]) -> Bool {
        guard let pixels = raster(of: page, bottom: band.bottom, height: Int(band.height.rounded(.up))),
            !paper.isEmpty, pixels.count % paper.count == 0
        else { return false }
        // Column by column the band must look like the bare row: the margin, the paper a theme may paint inside
        // the text area, and the blend where the two meet.
        for index in pixels.indices where abs(Int(pixels[index]) - Int(paper[index % paper.count])) > 12 {
            return false
        }
        return true
    }

    /// The page's full width between `bottom` and `bottom + height`, one pixel to a point, as premultiplied RGBA.
    private static func raster(of page: PDFPage, bottom: CGFloat, height: Int) -> [UInt8]? {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width.rounded(.up))
        guard width > 0, height > 0, let reference = page.pageRef else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.translateBy(x: -box.minX, y: -bottom)
            context.drawPDFPage(reference)
            return true
        }
        return drawn ? pixels : nil
    }

    private static func destination(_ annotation: PDFAnnotation) -> PDFDestination? {
        annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
    }

    private static func isSquare(_ annotation: PDFAnnotation) -> Bool {
        annotation.type == "Link" && isSquare(annotation.bounds)
    }

    private nonisolated static func isSquare(_ box: CGRect) -> Bool {
        box.width > 0 && box.height > 0 && box.width <= 12 && abs(box.width - box.height) < 0.25
    }

    private static func stockTarget(
        _ annotation: PDFAnnotation, in document: PDFDocument, stock: [Stock], lift: CGFloat
    ) -> Stock? {
        guard let target = destination(annotation), let page = target.page else { return nil }
        let index = document.index(for: page)
        let y = target.point.y - lift
        return stock.filter { $0.page == index && y >= $0.rect.minY - 1 && y <= $0.rect.maxY + 1 }
            .min { abs($0.rect.maxY - y) < abs($1.rect.maxY - y) }
    }

    private static func precedes(_ lhs: Location, _ rhs: Location) -> Bool {
        if lhs.page != rhs.page { return lhs.page < rhs.page }
        if abs(lhs.rect.midY - rhs.rect.midY) > 2 { return lhs.rect.midY > rhs.rect.midY }
        return lhs.rect.minX < rhs.rect.minX
    }

    private static func sameLine(_ lhs: Location, _ rhs: Location) -> Bool {
        lhs.page == rhs.page && abs(lhs.rect.midY - rhs.rect.midY) <= 2
    }
}
