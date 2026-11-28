import PDFKit
import SurimonoCore
import WebKit

/// Reads the heading groups of a prepared page and finds them in a printed PDF (`HeadingKeep`).
///
/// The DOM side reads text as `PrintedFragmentLinks` does, and `PrintedTextAlignment` finds it in the printed text, so
/// that a heading is placed by its printed glyphs and never by a predicted page break.
enum HeadingKeepProbe {
    /// Printed text read for the headings: more than the link repair reads, so that a 300-page document is still
    /// measured. A longer document is left as WebKit printed it and counted as unmeasured.
    static let textLimit = 1_048_576

    struct Collected: Decodable, Sendable {
        struct Group: Decodable, Sendable {
            /// The source offsets of the group's first character and the end of its last.
            let h: [Int]
            let k: String
            /// What has to share the page: its first character and the end of what was read of it.
            let f: [Int]?
            let n: Int?
        }
        let text: String?
        let groups: [Group]?
        let unmeasured: String?
    }

    /// One printed pass as the headings saw it.
    struct Observation: Sendable {
        var placements: [Int: HeadingKeep.Placement] = [:]
        /// What was read for each group that is not together (tests only read it).
        var facts: [Int: HeadingKeep.Facts] = [:]
        /// Set when nothing could be measured; the placements are empty.
        var unmeasured: HeadingKeep.Unmeasured?
    }

    static let collectScript = Bundle.module.url(forResource: "heading-keep", withExtension: "js").flatMap {
        try? String(contentsOf: $0, encoding: .utf8)
    }

    static let applyScript = """
        let style = document.getElementById('surimono-heading-keep');
        if (!style) {
            style = document.createElement('style');
            style.id = 'surimono-heading-keep';
            style.textContent = '[data-surimono-keep]{break-before:page!important;page-break-before:always!important}';
            (document.head ?? document.documentElement).append(style);
        }
        for (const element of document.querySelectorAll('[data-surimono-keep]')) element.removeAttribute('data-surimono-keep');
        const groups = globalThis.surimonoKeepGroups ?? [];
        let count = 0;
        for (const id of breaks) if (groups[id]) { groups[id].setAttribute('data-surimono-keep', ''); count++; }
        return count === breaks.length ? 'applied' : 'missing';
        """

    @MainActor static func collect(in view: WKWebView, until deadline: ContinuousClock.Instant) async throws
        -> Collected?
    {
        guard let collectScript else { return nil }
        let milliseconds = max(1, Int(ContinuousClock.now.duration(to: deadline) / .milliseconds(1)))
        let media = view.mediaType
        view.mediaType = "print"
        defer { view.mediaType = media }
        guard
            let json = try await view.evaluateForPrinting(
                collectScript, arguments: ["limit": textLimit, "milliseconds": milliseconds], until: deadline)
                as? String
        else { return nil }
        return try? JSONDecoder().decode(Collected.self, from: Data(json.utf8))
    }

    @MainActor static func apply(_ breaks: Set<Int>, in view: WKWebView, until deadline: ContinuousClock.Instant)
        async throws -> Bool
    {
        let reply = try await view.evaluateForPrinting(
            applyScript, arguments: ["breaks": breaks.sorted()], until: deadline)
        return reply as? String == "applied"
    }

    /// Where the collected groups landed in the printed bytes.
    /// - Parameter textArea: The text area of a logical page, in PDF points with the origin at the bottom left.
    @concurrent static func observe(
        _ data: Data, collected: Collected, textArea: CGRect, budget: Duration
    ) async throws -> Observation {
        let observed = try await PrintedFragmentLinks.bounded(until: .now + budget) {
            try await measure(data, collected: collected, textArea: textArea)
        }
        return observed ?? Observation(unmeasured: .budget)
    }

    @concurrent private static func measure(_ data: Data, collected: Collected, textArea: CGRect) async throws
        -> Observation
    {
        if let reason = collected.unmeasured {
            return Observation(unmeasured: reason == "budget" ? .budget : .ambiguous)
        }
        guard let text = collected.text, let groups = collected.groups else {
            return Observation(unmeasured: .ambiguous)
        }
        guard !groups.isEmpty else { return Observation() }
        guard let pdf = PDFDocument(data: data) else { return Observation(unmeasured: .ambiguous) }
        guard let index = try await PrintedTextAlignment(document: pdf, data: data, text: text, limit: textLimit) else {
            return Observation(unmeasured: .budget)
        }
        let reader = PageReader(index: index, textArea: textArea)
        var observation = Observation()
        for (id, group) in groups.enumerated() {
            if id.isMultiple(of: 32) {
                await Task.yield()
                try Task.checkCancellation()
            }
            let (placement, facts) = try reader.placement(of: group)
            observation.placements[id] = placement
            if case .together = placement {} else { observation.facts[id] = facts }
        }
        return observation
    }

    /// Reads one printed PDF for the groups. Only placed glyphs give a page or a position.
    private struct PageReader {
        let index: PrintedTextAlignment
        let textArea: CGRect
        var document: PDFDocument { index.document }

        func placement(of group: Collected.Group) throws -> (HeadingKeep.Placement, HeadingKeep.Facts) {
            guard group.h.count == 2, group.h[0] < group.h[1] else {
                return (
                    .unmeasured(.ambiguous),
                    .init(headingFirstPage: nil, headingLastPage: nil, previousPage: nil, follow: .none)
                )
            }
            let start = group.h[0]
            let end = group.h[1]
            let follow: HeadingKeep.Follow =
                switch group.k {
                case "text": .text(requiredLines: group.n ?? 2)
                case "block": .block
                case "graphic": .graphic
                default: .none
                }
            // Pages are read from the first and the last placed characters: a heading's tags, an Org planning line
            // or a drawer can be printed out of the source order, and their characters are then not placed.
            var facts = HeadingKeep.Facts(
                headingFirstPage: firstPage(in: start..<end), headingLastPage: lastPage(in: start..<end),
                previousPage: start > 0 ? lastPage(in: max(0, start - 64)..<start) : nil, hasPreviousText: start > 0,
                follow: follow)
            if let range = group.f, range.count == 2, range[0] < range[1] {
                facts.followFirstPage = firstPage(in: range[0]..<min(range[1], range[0] + 64))
                facts.followLastPage = lastPage(in: max(range[0], range[1] - 64)..<range[1])
            }
            guard let headingPage = facts.headingLastPage else { return (HeadingKeep.placement(of: facts), facts) }
            if case .graphic = follow, facts.headingFirstPage == headingPage {
                facts.drawnBelow = drawn(below: start..<end, on: headingPage)
            }
            if case .text = follow, facts.followFirstPage == headingPage, let range = group.f,
                let last = facts.followLastPage, last > headingPage
            {
                facts.linesOnHeadingPage = try lines(from: range[0], to: range[1], on: headingPage)
            }
            var placement = HeadingKeep.placement(of: facts)
            switch placement {
            case .separated(_, let startsPage, _):
                let room = facts.headingFirstPage.flatMap { moved(from: start, on: $0) }
                facts.move = room?.move
                facts.vacated = room?.vacated
                placement = .separated(move: facts.move, startsPage: startsPage, vacated: facts.vacated)
            case .together where facts.startsPageForSpace:
                if let previous = facts.previousPage {
                    placement = .together(precedingSpace: room(atFootOf: previous))
                }
            default: break
            }
            return (placement, facts)
        }

        func firstPage(in range: Range<Int>) -> Int? {
            range.lazy.compactMap { index.page(of: $0) }.first
        }

        func lastPage(in range: Range<Int>) -> Int? {
            range.reversed().lazy.compactMap { index.page(of: $0) }.first
        }

        /// Whether anything is drawn below the group's lowest placed glyph on its page, within the text area.
        func drawn(below range: Range<Int>, on page: Int) -> Bool? {
            guard let pdfPage = document.page(at: page),
                let last = range.reversed().lazy.compactMap({ index.glyph(of: $0) }).first(where: { $0.page == page }),
                let box = pdfPage.selection(for: NSRange(location: last.offset, length: 1))?.bounds(for: pdfPage),
                !box.isEmpty
            else { return nil }
            // Below the line's descent, so that the heading's own underline or border is not taken for the graphic.
            return PageInk.marks(on: pdfPage, from: textArea.minY, to: box.minY - box.height * 0.6, inside: textArea)
        }

        /// The lines that the text from `start` puts on `page`, from the proved glyphs read there.
        func lines(from start: Int, to end: Int, on page: Int) throws -> Int? {
            var low = Int.max
            var high = -1
            var i = start
            while i < end {
                let known = index.page(of: i)
                if let known, known > page { break }
                if known == page, let glyph = index.glyph(of: i), glyph.page == page {
                    low = min(low, glyph.offset)
                    high = max(high, glyph.offset)
                }
                i += 1
            }
            guard high >= low, let pdfPage = document.page(at: page),
                let selection = pdfPage.selection(for: NSRange(location: low, length: high - low + 1))
            else { return nil }
            // A superscript or a footnote mark can come back as a line of its own: count lines by overlapping height.
            var bands: [ClosedRange<CGFloat>] = []
            for line in selection.selectionsByLine() {
                try Task.checkCancellation()
                let box = line.bounds(for: pdfPage)
                guard !box.isEmpty, !box.isInfinite, box.height > 0 else { continue }
                if let match = bands.firstIndex(where: { band in
                    let overlap = min(band.upperBound, box.maxY) - max(band.lowerBound, box.minY)
                    return overlap > min(band.upperBound - band.lowerBound, box.height) / 2
                }) {
                    bands[match] = min(bands[match].lowerBound, box.minY)...max(bands[match].upperBound, box.maxY)
                } else {
                    bands.append(box.minY...box.maxY)
                }
            }
            return bands.count
        }

        /// The height from the top of the group to the lowest text of its first page, as a fraction of the text
        /// area: what goes to the next page if the group does; and the room above the foot of the text area that the
        /// page keeps then.
        func moved(from start: Int, on page: Int) -> (move: Double, vacated: Double)? {
            guard textArea.height > 0, let pdfPage = document.page(at: page), let text = pdfPage.string else {
                return nil
            }
            var i = start
            var glyph: (page: Int, offset: Int)?
            while glyph == nil, i < start + 64, i < index.count {
                glyph = index.glyph(of: i).flatMap { $0.page == page ? $0 : nil }
                i += 1
            }
            let length = (text as NSString).length
            guard let glyph, glyph.offset < length,
                let top = pdfPage.selection(for: NSRange(location: glyph.offset, length: 1))?.bounds(for: pdfPage),
                let rest = pdfPage.selection(
                    for: NSRange(location: glyph.offset, length: length - glyph.offset))?.bounds(for: pdfPage),
                !top.isEmpty, !rest.isEmpty
            else { return nil }
            return (
                max(0, Double((top.maxY - rest.minY) / textArea.height)),
                max(0, Double((top.maxY - textArea.minY) / textArea.height))
            )
        }

        /// The empty height at the foot of a page, above the bottom of the text area, as a fraction of it. The
        /// lowest mark is found in the drawn page, so that a picture below the last line counts as well; a page whose
        /// bottom margin is painted (a theme's paper) falls back to its lowest text.
        func room(atFootOf page: Int) -> Double? {
            guard textArea.height > 0, let pdfPage = document.page(at: page) else { return nil }
            let lowest: CGFloat
            switch PageInk.lowestMark(on: pdfPage, above: textArea.minY) {
            case .empty: return 1
            case .mark(let y): lowest = y
            case .painted, .unknown:
                guard let bottom = textBottom(of: pdfPage) else { return nil }
                lowest = bottom
            }
            return max(0, min(1, Double((lowest - textArea.minY) / textArea.height)))
        }

        private func textBottom(of page: PDFPage) -> CGFloat? {
            guard let length = (page.string as NSString?)?.length, length > 0,
                let bounds = page.selection(for: NSRange(location: 0, length: length))?.bounds(for: page),
                !bounds.isEmpty
            else { return nil }
            return bounds.minY
        }
    }
}

extension HeadingKeep.Facts {
    fileprivate var startsPageForSpace: Bool {
        guard let headingFirstPage, let previousPage else { return false }
        return previousPage < headingFirstPage
    }
}

/// Marks drawn on a page, read from a small grayscale rendering of it.
enum PageInk {
    enum Mark: Equatable {
        /// The PDF y of the lowest mark at or above the floor.
        case mark(CGFloat)
        /// Nothing is drawn above the floor.
        case empty
        /// The band below the floor is drawn too, so the page's background cannot be told from its content.
        case painted
        case unknown
    }

    /// Half a point a pixel: a line of text or a rule is still at least a pixel high.
    private static let scale: CGFloat = 0.5

    /// The page drawn on white, with the PDF y of each bitmap row's lower edge.
    private struct Raster {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let box: CGRect

        init?(_ page: PDFPage) {
            let box = page.bounds(for: .cropBox)
            let width = max(1, Int((box.width * PageInk.scale).rounded(.up)))
            let height = max(1, Int((box.height * PageInk.scale).rounded(.up)))
            guard width * height <= 4_000_000,
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: PageInk.scale, y: PageInk.scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .cropBox, to: context)
            guard let data = context.data else { return nil }
            pixels = Array(
                UnsafeBufferPointer(
                    start: data.bindMemory(to: UInt8.self, capacity: width * height),
                    count: width * height))
            self.width = width
            self.height = height
            self.box = box
        }

        /// The bitmap row (from the top) that holds the PDF y.
        func row(_ y: CGFloat) -> Int { min(height - 1, max(0, Int(((box.maxY - y) * PageInk.scale).rounded(.down)))) }

        func inked(row: Int, columns: Range<Int>? = nil) -> Bool {
            let base = row * width
            for x in columns ?? 0..<width where pixels[base + x] < 245 { return true }
            return false
        }
    }

    static func lowestMark(on page: PDFPage, above floor: CGFloat) -> Mark {
        guard let raster = Raster(page) else { return .unknown }
        let floorRow = raster.row(floor)
        for row in stride(from: raster.height - 1, to: floorRow, by: -1) where raster.inked(row: row) {
            return .painted
        }
        for row in stride(from: floorRow, through: 0, by: -1) where raster.inked(row: row) {
            return .mark(raster.box.maxY - CGFloat(row + 1) / scale)
        }
        return .empty
    }

    /// Whether anything is drawn between two PDF heights within `area`; nil when the page's background is painted
    /// below the area too, so that a mark cannot be told from the paper.
    static func marks(on page: PDFPage, from low: CGFloat, to high: CGFloat, inside area: CGRect) -> Bool? {
        guard high > low, let raster = Raster(page) else { return high > low ? nil : false }
        if raster.inked(row: raster.height - 1) { return nil }
        let left = max(0, Int(((area.minX - raster.box.minX) * scale).rounded(.down)))
        let right = min(raster.width, Int(((area.maxX - raster.box.minX) * scale).rounded(.up)))
        guard left < right else { return nil }
        for row in raster.row(high)...raster.row(low) where raster.inked(row: row, columns: left..<right) {
            return true
        }
        return false
    }
}
