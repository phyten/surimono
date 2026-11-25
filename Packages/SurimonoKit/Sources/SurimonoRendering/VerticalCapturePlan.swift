import Foundation

/// Source bands index the intact DOM. Their rectangles can occupy several different slots on paper.
struct VerticalCapturePlan {
    typealias Band = FlowPageCuts.Band

    struct ClosingRule {
        let rect: CGRect
        let color: [CGFloat]
    }

    struct Slice {
        let rect: CGRect
        let index: Int
        let row: Int
        // From the row's top right to the capture's bottom left, in CSS pixels at the output scale.
        let offset: CGPoint
        let fit: CGFloat
        var header: CGRect?
        var bottomRule: ClosingRule?
    }

    private(set) var sources: [Band] = []
    private(set) var pages: [[Slice]] = []

    static func captureRect(_ band: Band, height: CGFloat) -> CGRect {
        let left = max(band.end, band.ink?.end ?? band.end)
        let right = min(band.start, band.ink?.start ?? band.start)
        let top = min(0, band.ink?.top ?? 0)
        let bottom = max(height, band.ink?.bottom ?? height)
        return CGRect(x: -left, y: top, width: left - right, height: bottom - top)
    }

    init(chapters: [[Band]], width: CGFloat, height: CGFloat, rows: Int) throws {
        var count = 0
        for groups in chapters {
            var page: [Slice] = []
            var row = 0
            var used: CGFloat = 0
            var previousEnd: CGFloat?
            var prose: Band?
            var proseInset: CGFloat = 0

            func append(
                _ rect: CGRect, index: Int, offset: CGPoint, fit: CGFloat, header: CGRect? = nil,
                rule: ClosingRule? = nil
            ) throws {
                count += 1
                guard count <= 250_000 else { throw WebPaginator.PaginationError.printFailed }
                page.append(
                    Slice(
                        rect: rect, index: index, row: row, offset: offset, fit: fit, header: header, bottomRule: rule))
            }

            // Contiguous prose on the same row needs only one WebKit capture, including ruby overhang.
            func flushProse() throws {
                guard let band = prose else { return }
                let ink = Self.captureRect(band, height: height)
                let fit = min(1, width / (band.end - band.start))
                let offset = CGPoint(x: (ink.minX + band.start) * fit - proseInset, y: ink.maxY * fit)
                try append(ink, index: sources.count, offset: offset, fit: fit)
                sources.append(band)
                prose = nil
            }

            func reserve(_ advance: CGFloat, gap: CGFloat) throws -> CGFloat {
                if used > 0 && used + gap + advance > width {
                    try flushProse()
                    row += 1
                    if row == rows {
                        pages.append(page)
                        page = []
                        row = 0
                    }
                    used = 0
                }
                let inset = used == 0 ? 0 : used + gap
                used = inset + advance
                return inset
            }

            for group in groups {
                var gap = previousEnd.map { max(0, group.start - $0) } ?? 0
                previousEnd = group.end
                if let continuation = group.continuation {
                    try flushProse()
                    let index = sources.count
                    sources.append(group)
                    let ink = Self.captureRect(group, height: height)
                    // The one-pixel side allowance protects ink and must not charge the row for extra layout width.
                    let fullWidth = ink.width <= width + 2
                    let leading = fullWidth ? min(1, group.start + ink.maxX) : 0
                    let trailing = fullWidth ? min(1, -ink.minX - group.end) : 0
                    try Self.tiles(in: ink, continuation: continuation, width: width, height: height) {
                        tile, header, rule in
                        let inset = try reserve(min(tile.width - leading - trailing, width), gap: gap)
                        var paint = tile
                        if tile.maxY >= ink.maxY { paint.size.height += continuation.bottomBleed }
                        try append(
                            paint, index: index,
                            offset: CGPoint(x: leading - inset - tile.width, y: paint.height + (header?.height ?? 0)),
                            fit: 1, header: header, rule: rule)
                        gap = continuation.gap
                    }
                } else {
                    let inset = try reserve(min(width, group.end - group.start), gap: gap)
                    if prose == nil {
                        prose = group
                        proseInset = inset
                    } else {
                        prose?.includeInk(of: group)
                        prose?.end = group.end
                    }
                }
            }
            try flushProse()
            if !page.isEmpty { pages.append(page) }
        }
    }

    /// Consecutive viewports share an edge even for a single cell taller or wider than the paper.
    private static func tiles(
        in ink: CGRect, continuation: FlowPageCuts.Continuation, width: CGFloat, height: CGFloat,
        place: (CGRect, CGRect?, ClosingRule?) throws -> Void
    ) throws {
        var top = ink.minY
        let breaks = continuation.breaks
        let tables = continuation.tables ?? []
        // Horizontal tiles keep the original column widths, including for a heading spanning several columns.
        func strip(_ table: FlowPageCuts.TableRegion, y: CGFloat, depth: CGFloat, within tile: CGRect) -> CGRect? {
            let left = max(tile.minX, ink.minX + table.leftInset)
            let right = min(tile.maxX, ink.minX + table.leftInset + table.width)
            guard right > left, depth > 0 else { return nil }
            return CGRect(x: left, y: y, width: right - left, height: depth)
        }
        var nextBreak = breaks.startIndex
        while top < ink.maxY {
            let repeated = tables.first { table in
                guard let y = table.headTop, let depth = table.headHeight else { return false }
                // An oversized header is already present in the original slices. Keep space for body ink.
                return top > ink.minY && top >= y + depth - 0.01 && top < table.bottom && depth > 0
                    && depth < height - 1
            }
            let limit = top + height - (repeated?.headHeight ?? 0)
            var bottom = min(ink.maxY, limit)
            if bottom < ink.maxY, let table = tables.first(where: { $0.top < bottom && bottom < $0.bottom }) {
                // Keep the closing stroke inside the slot without painting over the last row or a bisected cell.
                bottom -= min(table.ruleWidth, max(0, bottom - top - 1))
            }
            var lastBreak = top
            while nextBreak < breaks.count && breaks[nextBreak] <= bottom {
                lastBreak = breaks[nextBreak]
                nextBreak += 1
            }
            if bottom < ink.maxY && lastBreak > top { bottom = lastBreak }
            var left = ink.minX
            while left < ink.maxX {
                // The capture includes one extra CSS pixel of ink on each side.
                let right = ink.width <= width + 2 ? ink.maxX : min(ink.maxX, left + width)
                guard right > left, bottom > top else { throw WebPaginator.PaginationError.printFailed }
                let tile = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                let header = repeated.flatMap { table in
                    strip(table, y: table.headTop ?? 0, depth: table.headHeight ?? 0, within: tile)
                }
                // Stroke outside the body crop so a cell taller than the row keeps all its ink.
                let rule = tables.first { bottom > $0.top && bottom < $0.bottom - 0.01 }.flatMap { table in
                    strip(table, y: bottom, depth: min(table.ruleWidth, limit - bottom), within: tile).map {
                        ClosingRule(rect: $0, color: table.color)
                    }
                }
                try place(tile, header, rule)
                left = right
            }
            top = bottom
        }
    }
}
