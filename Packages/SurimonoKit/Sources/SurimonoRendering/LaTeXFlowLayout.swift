import Foundation
import SurimonoFormats

/// All measurements use the same top-down CSS pixel coordinates as the capture view.
struct LaTeXFlowLayout {
    struct Slice: Codable, Equatable {
        var strip: Int
        var start: CGFloat
        var end: CGFloat
        var width: CGFloat
        var noteDepth: CGFloat?
        var noteRuleOffset: CGFloat?
        var height: CGFloat { end - start }

        fileprivate var valid: Bool {
            strip >= 0 && start.isFinite && end.isFinite && height.isFinite && height > 0 && width.isFinite && width > 0
                && (noteRuleOffset ?? 0).isFinite && (noteDepth ?? 0) >= 0 && (noteDepth ?? 0) <= height
        }
    }

    struct Item: Decodable {
        var slice: Slice?
        var gap: CGFloat = 0
        var notes: [String] = []
        var fil: CGFloat?
        var filOrder: Int?
        var columnTopAdjustment: CGFloat?
        var repeatHead: Slice?
        var repeatFoot: Slice?
        var tableBreakDepth: CGFloat?
        var tablePreShrink: CGFloat?
        var placement: String?
        var floatKind: String?
        var wide: Bool = false
        var forced: String?
        var paragraph: Int?
        var heading: Bool?
        var keepBefore: Bool?
        var brokenAfter: Bool?
        var discardable: Bool?
        var leadingBeforeHere: CGFloat?
        var leadingAfterHere: CGFloat?
        var leadingAfterHeading: CGFloat?
        var bottomDepth: CGFloat?
        var stretchBefore: CGFloat?
        var shrinkBefore: CGFloat?
        var topInset: CGFloat?
        var topSkip: CGFloat?
        var extraAfter: CGFloat?
        var corrections: [Correction]?
        var followingHeight: CGFloat?
        var followingNotes: [String]?
    }

    struct Correction: Decodable {
        var position: CGFloat
        var extra: CGFloat
        var shrink: CGFloat = 0
        var stretch: CGFloat = 0
    }

    struct Segment: Decodable {
        var columns: Int
        var gap: CGFloat
        var rule: CGFloat
        var balance: Bool
        var pageNotes: Bool
        var titleNoteWidth: CGFloat?
        var items: [Item]
    }

    struct Probe: Decodable {
        let index: Int
        let strip: Int
        let position: CGFloat
    }

    struct FloatFractions: Decodable {
        var top, bottom, text, page: CGFloat
    }

    struct GlueComponents: Decodable {
        var note: CGFloat = 0
        var textFloat: CGFloat = 0
        var float: CGFloat = 0
        var inText: CGFloat = 0
        var valid: Bool { [note, textFloat, float, inText].allSatisfy { $0.isFinite && $0 >= 0 } }
    }

    struct Measurement: Decodable {
        var mathProof: Bool?
        var allowsSingleLineFragments: Bool?
        var comparesColumnBreakBadness: Bool?
        var glueShrink: GlueComponents?
        var glueStretch: GlueComponents?
        var columnNotice: Slice?
        var singleColumnNotice: Bool?
        var columnNoticeLast: Bool?
        var reviewBanner: String?
        var reviewCorner: String?
        var floatFractions: FloatFractions?
        var firstNotice: Slice?
        var firstPageExtension: CGFloat?
        var review: LaTeXResolvedStyle.Review?
        var reviewLines: [[CGFloat]]?
        var probes: [Probe]?
        var segments: [Segment]
        var notes: [String: Slice]
        var noteSkip: CGFloat
        var noteStrutDepth: CGFloat?
        var noteRuleWidth: CGFloat?
        var noteRuleThickness: CGFloat?
        var textFloatSep: CGFloat
        var floatSep: CGFloat
        var inTextSep: CGFloat
    }

    struct Piece: Encodable {
        var slice: Slice
        var x: CGFloat
        var y: CGFloat
        var scale: CGFloat
        var end: CGFloat { y + slice.height * scale }
        var plusBefore: CGFloat = 0
        var fill = Fill()
        private enum CodingKeys: String, CodingKey { case slice, x, y, scale }

    }

    struct CompressionTrial {
        var naturalNext: Int
        var fullNext: Int
        var fullShortfall: CGFloat?
        var naturalCost: CGFloat?
        var compressedCost: CGFloat?
    }

    // Keep the fit operands from the chosen layout, before the column glue is stretched.
    struct ColumnBreak {
        var column: Int
        var nextItem: Int
        var remaining: CGFloat
        var required: CGFloat
        var trial: CompressionTrial?
    }

    struct Page {
        var columnBreaks: [ColumnBreak] = []
        var isBlankVersoOrRecto = false
        var pieces: [Piece] = []
        var rules: [CGRect] = []
        fileprivate var stretches: [ColumnStretch] = []
        fileprivate var shrinkFraction: CGFloat = 0
        fileprivate var footers: [Lane: Footer] = [:]
        fileprivate var columnEnds: [Lane: Int] = [:]
        fileprivate var depths: [Lane: CGFloat] = [:]
        fileprivate var floats: [Lane: FloatUsage] = [:]

        fileprivate mutating func draw(
            _ slice: Slice, at y: CGFloat, lane: Lane, scale: CGFloat = 1, plus: CGFloat = 0, fill: Fill = Fill()
        ) {
            // Joining adjacent line groups makes capture cost proportional to columns rather than line count.
            if plus == 0, fill.weight == 0, let last = pieces.last, last.slice.strip == slice.strip, last.x == lane.x,
                last.scale == 1,
                scale == 1, abs(last.y + slice.start - last.slice.start - y) < 0.001
            {
                pieces[pieces.count - 1].slice.end = slice.end
            } else {
                pieces.append(Piece(slice: slice, x: lane.x, y: y, scale: scale, plusBefore: plus, fill: fill))
            }
            depths[lane] = max(depths[lane] ?? 0, y + slice.height * scale)
        }

        fileprivate func reserved(_ lane: Lane, full: Lane) -> CGFloat {
            let shared = footers[full]?.reservedHeight ?? 0
            return shared
                + (footers.lazy.filter { $0.key != full && $0.key.overlaps(lane) }.map(\.value.reservedHeight).max()
                    ?? 0)
        }

        private func stretchWeights(_ column: ColumnStretch, glue: GlueComponents) -> (Fill, CGFloat, CGFloat) {
            let footer = footers[column.lane]
            let footerPlus =
                (footer?.notes.isEmpty == false ? glue.note : 0) + CGFloat(footer?.floats.count ?? 0) * glue.textFloat
            let fill = pieces[column.range].reduce(column.trailingFill) { $0 + $1.fill }
            let total = fill.order > 0 ? fill.weight : pieces[column.range].reduce(footerPlus) { $0 + $1.plusBefore }
            return (fill, total, footerPlus)
        }

        fileprivate func noteBreakSpace(in lane: Lane, height: CGFloat, full: Lane) -> CGFloat? {
            guard let column = stretches.last, column.lane == lane, let end = column.noteBreakEnd else { return nil }
            return height - reserved(lane, full: full) - end
        }

        fileprivate func shrinkRatio(in lane: Lane, height: CGFloat, full: Lane, fullyShrunkSpace: CGFloat?) -> CGFloat
        {
            guard let fullyShrunkSpace, let space = noteBreakSpace(in: lane, height: height, full: full) else {
                return shrinkFraction
            }
            if fullyShrunkSpace < -0.001 { return .infinity }
            guard shrinkFraction < 1, fullyShrunkSpace > space else { return shrinkFraction }
            // Two replays of the same break give its finite shrink, including insertion skips.
            // Find the ratio at zero break space; keep the drawing at its original box height.
            let capacity = (fullyShrunkSpace - space) / (1 - shrinkFraction)
            return max(0, shrinkFraction - space / capacity)
        }

        fileprivate func stretchRatio(in lane: Lane, height: CGFloat, full: Lane, glue: GlueComponents) -> CGFloat {
            guard let column = stretches.last, column.lane == lane else { return .infinity }
            let (fill, total, _) = stretchWeights(column, glue: glue)
            if fill.order > 0 { return 0 }
            let extra = max(0, height - reserved(lane, full: full) - (column.noteBreakEnd ?? column.end))
            return total > 0 ? extra / total : (extra == 0 ? 0 : .infinity)
        }

        fileprivate mutating func flush(height: CGFloat, full: Lane, glue: GlueComponents, from start: Int = 0) {
            for column in stretches.dropFirst(start) {
                let lane = column.lane
                let footer = footers[lane]
                let reservedHeight = reserved(lane, full: full)
                let remaining = height - reservedHeight - column.end
                // TeX reports underfull finite glue but still sets the box to its requested height.
                // If infinite glue is present, only glue of the highest order participates.
                let (fill, total, footerPlus) = stretchWeights(column, glue: glue)
                guard total > 0, remaining > 0 else { continue }
                var shift: CGFloat = 0
                for i in column.range {
                    let weight = fill.order == 0 ? pieces[i].plusBefore : pieces[i].fill.weight(at: fill.order)
                    shift += remaining * (weight / total)
                    pieces[i].y += shift
                }
                if fill.order == 0, var f = footer {
                    for i in f.floats.indices { f.floats[i].1 += remaining * (glue.textFloat / total) }
                    if !f.notes.isEmpty { f.noteSkip += remaining * (glue.note / total) }
                    f.height += remaining * (footerPlus / total)
                    footers[lane] = f
                }
            }
        }

        fileprivate mutating func finish(height: CGFloat, full: Lane, ruleWidth: CGFloat?, ruleThickness: CGFloat) {
            // Reserve footers during layout, then splice them into the capture stream at their
            // column ends. Work backwards so earlier offsets remain valid. Page-wide notes read last.
            let bodyCount = pieces.count
            func insertion(_ lane: Lane) -> Int { columnEnds[lane] ?? bodyCount }
            let lanes = footers.keys.sorted { a, b in
                if insertion(a) != insertion(b) { return insertion(a) > insertion(b) }
                if a == full || b == full { return a == full && b != full }
                return a.x > b.x
            }
            for lane in lanes {
                guard let footer = footers[lane] else { continue }
                var blocks: [Piece] = []
                var y = height - reserved(lane, full: full)
                if lane == full { y = height - footer.reservedHeight }
                for (slice, space) in footer.floats {
                    y += space
                    blocks.append(Piece(slice: slice, x: lane.x, y: y, scale: 1))
                    y += slice.height
                }
                var notes = footer.notes
                if let last = footer.lastNotice, let i = notes.firstIndex(of: last) {
                    notes.append(notes.remove(at: i))
                }
                if let first = notes.first {
                    let skip = footer.noteSkip
                    y += skip
                    rules.append(
                        CGRect(
                            x: lane.x, y: y + (first.noteRuleOffset ?? -min(3, skip / 2)),
                            width: min(ruleWidth ?? 0.4 * lane.width, lane.width), height: ruleThickness))
                }
                for slice in notes {
                    blocks.append(Piece(slice: slice, x: lane.x, y: y, scale: 1))
                    y += slice.height
                }
                pieces.insert(contentsOf: blocks, at: insertion(lane))
            }
            if !stretches.isEmpty || pieces.contains(where: { $0.plusBefore > 0 }) {
                // Last and forced columns retain their natural pitch.
                // Rejoin their contiguous slices before asking WebKit to capture each one.
                var merged: [Piece] = []
                for piece in pieces {
                    if let last = merged.last, last.slice.strip == piece.slice.strip,
                        last.x == piece.x, last.scale == 1, piece.scale == 1,
                        last.slice.end <= piece.slice.start + 0.001,
                        abs(last.y + piece.slice.start - last.slice.start - piece.y) < 0.001
                    {
                        merged[merged.count - 1].slice.end = piece.slice.end
                    } else {
                        merged.append(piece)
                    }
                }
                pieces = merged
            }
            stretches.removeAll()
            columnEnds.removeAll()
            footers.removeAll()
        }
    }

    fileprivate struct Lane: Hashable {
        var x: CGFloat
        var width: CGFloat
        func overlaps(_ other: Lane) -> Bool { min(x + width, other.x + other.width) - max(x, other.x) > 0.001 }
    }

    fileprivate struct FloatUsage {
        var top = 0
        var bottom = 0
        var total = 0
        var topHeight: CGFloat = 0
        var occupied: CGFloat = 0
    }

    struct Fill {
        var order: Int = 0
        var weight: CGFloat = 0

        func weight(at order: Int) -> CGFloat { self.order == order ? weight : 0 }

        static func + (lhs: Self, rhs: Self) -> Self {
            let order = max(lhs.order, rhs.order)
            return Self(order: order, weight: lhs.weight(at: order) + rhs.weight(at: order))
        }
    }

    fileprivate struct ColumnStretch {
        let lane: Lane
        let range: Range<Int>
        let end: CGFloat
        let noteBreakEnd: CGFloat?
        let trailingFill: Fill
    }

    fileprivate struct Footer {
        var noteSkip: CGFloat = 0
        var lastNotice: Slice?
        var notes: [Slice] = []
        var floats: [(Slice, CGFloat)] = []
        var kinds: Set<String> = []
        var height: CGFloat = 0
        var finalDepth: CGFloat { (lastNotice ?? notes.last)?.noteDepth ?? 0 }
        var reservedHeight: CGFloat { height - finalDepth }

        mutating func append(_ additions: [Slice], skip: CGFloat) {
            if additions.isEmpty { return }
            if notes.isEmpty {
                noteSkip = skip
                height += skip
            }
            notes += additions
            height += additions.reduce(0) { $0 + $1.height }
        }
    }

    struct CannotFit: Error {}

    /// Text already accepted into this column can move down while its reference still fits.
    /// Keep the insertion point in PDF reading order as well as its vertical position.
    private struct ColumnTop {
        var index: Int
        var textStart: CGFloat
        var hasFloats: Bool
    }

    private struct Waiting {
        let item: Item
        let page: Int
    }

    private struct Cursor {
        var item = 0
        var waiting: ArraySlice<Waiting> = []
        var floatAfterMovedHeading: Int?
    }

    private var input: Measurement
    private let full: Lane
    private let recordsBreaks: Bool
    private let normalHeight: CGFloat
    private var textFloatSep: CGFloat {
        max(0, input.textFloatSep - page.shrinkFraction * (input.glueShrink?.textFloat ?? 0))
    }
    private var floatSep: CGFloat {
        max(0, input.floatSep - page.shrinkFraction * (input.glueShrink?.float ?? 0))
    }
    private var inTextSep: CGFloat {
        max(0, input.inTextSep - page.shrinkFraction * (input.glueShrink?.inText ?? 0))
    }
    private var noteSkip: CGFloat {
        max(0, input.noteSkip - page.shrinkFraction * (input.glueShrink?.note ?? 0))
    }
    private var height: CGFloat {
        guard pages.isEmpty, let notice = input.firstNotice else { return normalHeight }
        return max(1, normalHeight + (input.firstPageExtension ?? 0) - notice.height - textFloatSep)
    }
    private let deadline: ContinuousClock.Instant?
    private var pages: [Page] = []
    private var page = Page()
    private var top: CGFloat = 0

    static func pages(
        _ input: Measurement, width: CGFloat, height: CGFloat, recordsBreaks: Bool = false,
        until deadline: ContinuousClock.Instant? = nil
    ) throws -> [Page] {
        let spacing = [
            input.noteSkip, input.noteStrutDepth ?? 0, input.noteRuleWidth ?? 180, input.noteRuleThickness ?? 0.5,
            input.textFloatSep, input.floatSep,
            input.inTextSep,
        ]
        guard width.isFinite, width > 0, height.isFinite, height > 0,
            spacing.allSatisfy({ $0.isFinite && $0 >= 0 }), input.notes.values.allSatisfy(\.valid),
            input.glueStretch?.valid != false, input.glueShrink?.valid != false,
            input.columnNotice?.valid != false, input.firstNotice?.valid != false
        else { throw CannotFit() }
        var layout = Self(
            input: input, full: Lane(x: 0, width: width), recordsBreaks: recordsBreaks, normalHeight: height,
            deadline: deadline)
        let finalSegment = input.segments.lastIndex { !$0.items.isEmpty }
        for (index, source) in input.segments.enumerated() where !source.items.isEmpty {
            var segment = source
            try layout.checkBudget()
            guard segment.rule.isFinite, segment.gap.isFinite,
                segment.titleNoteWidth.map({ $0.isFinite && $0 > 0 && $0 <= width }) ?? true,
                segment.items.allSatisfy({
                    $0.gap.isFinite && ($0.leadingBeforeHere ?? 0).isFinite && ($0.extraAfter ?? 0).isFinite
                        && ($0.leadingAfterHere ?? 0).isFinite && ($0.leadingAfterHere ?? 0) >= 0
                        && ($0.leadingAfterHeading ?? 0).isFinite && ($0.leadingAfterHeading ?? 0) >= 0
                        && ($0.bottomDepth ?? 0).isFinite && ($0.bottomDepth ?? 0) >= 0
                        && ($0.stretchBefore ?? 0).isFinite && ($0.stretchBefore ?? 0) >= 0
                        && ($0.shrinkBefore ?? 0).isFinite && ($0.shrinkBefore ?? 0) >= 0
                        && ($0.extraAfter ?? 0) > -1 && ($0.topSkip ?? 0).isFinite && ($0.topSkip ?? 0) >= 0
                        && ($0.tableBreakDepth ?? 0).isFinite && ($0.tableBreakDepth ?? 0) >= 0
                        && ($0.tablePreShrink ?? 0).isFinite && ($0.tablePreShrink ?? 0) >= 0
                        && ($0.repeatHead?.valid ?? true) && ($0.repeatFoot?.valid ?? true)
                        && ($0.columnTopAdjustment ?? 0).isFinite
                        && ($0.fil ?? 0).isFinite && ($0.fil ?? 0) >= 0 && (1...3).contains($0.filOrder ?? 1)
                        && ($0.slice?.valid ?? ($0.forced != nil || $0.fil != nil))
                })
            else { throw CannotFit() }
            if input.glueShrink != nil {
                // JS has separated these lines despite a fractional overlap of their font
                // boxes. A common cut preserves their pitch and prevents an internal widow
                // penalty from propagating through the following paragraph during grouping.
                for i in segment.items.indices.dropFirst() {
                    guard let previous = segment.items[i - 1].slice, let next = segment.items[i].slice,
                        previous.strip == next.strip, previous.start < next.start, previous.end < next.end
                    else { continue }
                    let overlap = previous.end - next.start
                    if overlap > 0 && overlap <= 0.1 {
                        let cut = next.start + overlap / 2
                        segment.items[i - 1].slice?.end = cut
                        segment.items[i].slice?.start = cut
                    }
                }
            }
            segment.items = keptItems(
                segment.items, capacity: height, inTextSep: input.inTextSep,
                allowsSingleLineFragments: input.allowsSingleLineFragments == true)
            // A clear page drains the old queue before text after the command can enter the new one.
            var start = 0
            for i in segment.items.indices {
                guard let boundary = segment.items[i].forced, ["clear", "page", "right", "left"].contains(boundary)
                else { continue }
                var part = segment
                part.items = Array(segment.items[start..<i])
                try layout.place(part, canFinishRagged: true)
                if !layout.page.pieces.isEmpty || !layout.page.footers.isEmpty { layout.endPage() }
                if boundary == "right" && !layout.pages.count.isMultiple(of: 2)
                    || boundary == "left" && layout.pages.count.isMultiple(of: 2)
                {
                    layout.page.isBlankVersoOrRecto = true
                    layout.endPage()
                }
                start = i + 1
            }
            if start > 0 { segment.items = Array(segment.items[start...]) }
            try layout.place(segment, canFinishRagged: index == finalSegment)
        }
        if !layout.page.pieces.isEmpty || !layout.page.footers.isEmpty || layout.pages.isEmpty { layout.endPage() }
        return layout.pages
    }

    static func keptItems(
        _ items: [Item], capacity: CGFloat, inTextSep: CGFloat = 0, allowsSingleLineFragments: Bool = false
    ) -> [Item] {
        var result: [Item] = []
        var first = 0
        while first < items.count {
            guard let strip = items[first].slice?.strip, items[first].placement == nil else {
                result.append(items[first])
                first += 1
                continue
            }
            var end = first + 1
            while end < items.count && items[end].slice?.strip == strip { end += 1 }
            let followsHeading =
                result.last(where: { $0.placement == nil || $0.placement?.contains("H") == true })?.heading == true
            let bands = (first..<end).compactMap { i -> FlowPageCuts.Band? in
                guard let s = items[i].slice else { return nil }
                let p = items[i].paragraph ?? 0
                let sameNext = p != 0 && i + 1 < end && items[i + 1].paragraph == p
                let firstPair = i == first || items[i - 1].paragraph != p
                let lastPair = i + 2 >= end || items[i + 2].paragraph != p
                // A three-line opening may leave its third line on the next page.
                // A soft widow penalty must not chain an entire section to its heading.
                let afterFirstTwo =
                    i > first && items[i - 1].paragraph == p
                    && (i == first + 1 ? followsHeading : items[i - 2].heading == true)
                return .init(
                    start: s.start, end: s.end,
                    keepNext: items[i].heading == true || (i + 1 < end && items[i + 1].keepBefore == true)
                        || !allowsSingleLineFragments && sameNext && (firstPair || lastPair && !afterFirstTwo)
                )
            }
            var i = first
            for band in FlowPageCuts.groups(for: bands, capacity: capacity) {
                var item = items[i]
                item.slice?.start = band.start
                item.slice?.end = band.end
                let start = i
                repeat {
                    if i != start {
                        item.notes.append(contentsOf: items[i].notes)
                        let shrink = items[i].shrinkBefore ?? 0
                        let stretch = items[i].stretchBefore ?? 0
                        if shrink > 0 || stretch > 0, let slice = items[i].slice {
                            if item.corrections == nil { item.corrections = [] }
                            item.corrections?.append(
                                Correction(
                                    position: slice.start, extra: 0, shrink: min(items[i].gap, shrink), stretch: stretch
                                ))
                        }
                    }
                    if let extra = items[i].extraAfter, extra != 0, let slice = items[i].slice {
                        if item.corrections == nil { item.corrections = [] }
                        item.corrections?.append(Correction(position: slice.end, extra: extra))
                    }
                    i += 1
                } while i < end && (items[i].slice?.end ?? .infinity) <= band.end
                item.bottomDepth = items[i - 1].bottomDepth
                item.brokenAfter = items[i - 1].brokenAfter
                item.heading = items[i - 1].heading
                result.append(item)
            }
            first = end
        }
        // Floats are measured in separate strips. Keep the heading with the first
        // body group across that boundary; an intervening float may consume only the surplus.
        var heading: Int?
        for i in result.indices {
            let current = result[i]
            if current.forced != nil {
                heading = nil
                continue
            }
            if current.placement != nil && current.placement?.contains("H") != true { continue }
            // A display can have its own capture strip while still belonging to the preceding paragraph.
            let previousLine =
                current.keepBefore == true && i > 0 && result[i - 1].slice != nil && result[i - 1].placement == nil
                ? i - 1 : nil
            if let start = heading ?? previousLine, let slice = current.slice {
                let pinned = current.placement?.contains("H") == true
                let required =
                    slice.height
                    + (pinned
                        ? max(0, inTextSep - (current.leadingBeforeHere ?? 0))
                        : max(0, current.gap) + (current.leadingAfterHeading ?? 0))
                if required + (result[start].slice?.height ?? 0) <= capacity {
                    for index in start..<i {
                        result[index].followingHeight = required
                        result[index].followingNotes = current.notes
                    }
                }
            }
            heading = current.heading == true ? i : nil
        }
        return result
    }

    private func checkBudget() throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw CannotFit() }
    }

    private mutating func endPage(flush: Bool = false) {
        if flush, let glue = input.glueStretch { page.flush(height: height, full: full, glue: glue) }
        page.finish(
            height: height, full: full, ruleWidth: input.noteRuleWidth,
            ruleThickness: input.noteRuleThickness ?? 0.5)
        if pages.isEmpty, let notice = input.firstNotice {
            page.pieces.append(Piece(slice: notice, x: 0, y: height + textFloatSep, scale: 1))
        }
        pages.append(page)
        page = Page()
        top = 0
    }

    private mutating func place(_ segment: Segment, canFinishRagged: Bool) throws {
        guard (1...2).contains(segment.columns), segment.gap >= 0,
            full.width > CGFloat(segment.columns - 1) * segment.gap
        else { throw CannotFit() }
        var cursor = Cursor()
        while cursor.item < segment.items.count || !cursor.waiting.isEmpty {
            try checkBudget()
            let initial = cursor
            let initialPage = page
            let initialTop = top
            // If both natural columns finish the document (or reach its explicit
            // break), preserve their source boundary. If text remains,
            // replay with finite shrink so a nearly fitting group can still stay.
            let checkNaturalEnd =
                canFinishRagged && segment.columns == 2 && !segment.balance
                && input.comparesColumnBreakBadness != true
                && input.glueStretch != nil && input.glueShrink != nil
            var depth = try fill(segment, cursor: &cursor, limit: height, shrinkColumns: !checkNaturalEnd)
            if checkNaturalEnd && (cursor.item < segment.items.count || !cursor.waiting.isEmpty) {
                page = initialPage
                cursor = initial
                depth = try fill(segment, cursor: &cursor, limit: height)
            }
            if input.glueShrink != nil && segment.columns == 1 && cursor.item < segment.items.count {
                depth = try replayShrink(from: initialPage, initial: initial, cursor: &cursor, natural: depth) {
                    layout, trial, fraction in
                    if initialPage.pieces.isEmpty && initialPage.footers.isEmpty {
                        layout.page.shrinkFraction = fraction
                    }
                    return try layout.fill(segment, cursor: &trial, limit: layout.height, shrinkFraction: fraction)
                }
            }
            let finished = cursor.item == segment.items.count && cursor.waiting.isEmpty
            if finished && segment.balance && segment.columns > 1 && depth > initialTop {
                // Replay only the last page. Trials use identical notes, float queues and legal line groups.
                var low = initialTop
                var high = depth
                var best = page
                while high - low > 1 {
                    try checkBudget()
                    let mid = low + (high - low) / 2
                    guard mid > low && mid < high else { break }
                    page = initialPage
                    top = initialTop
                    var trial = initial
                    let used = try fill(segment, cursor: &trial, limit: mid)
                    if trial.item == segment.items.count && trial.waiting.isEmpty {
                        best = page
                        high = mid
                        depth = used
                    } else {
                        low = mid
                    }
                }
                page = best
            }
            if finished {
                if canFinishRagged, segment.columns == 2, !segment.balance, let glue = input.glueStretch {
                    // Only a natural overflow records a stretch. The final column and a
                    // forced break remain ragged; earlier segments can have a different height.
                    page.flush(height: height, full: full, glue: glue, from: initialPage.stretches.count)
                }
                top = max(initialTop, depth)
                return
            }
            if page.pieces.isEmpty && page.footers.isEmpty {
                guard cursor.item != initial.item else { throw CannotFit() }
                if cursor.waiting.first?.item.wide != true { continue }
            }
            endPage(flush: true)
        }
    }

    // Retry the same insertions and legal breaks. Only use shrink when it gains
    // another item; then find the smallest shared glue ratio that retains that break.
    private mutating func replayShrink(
        from initialPage: Page, initial: Cursor, cursor: inout Cursor, natural: CGFloat,
        trial: (inout Self, inout Cursor, CGFloat) throws -> CGFloat
    ) throws -> CGFloat {
        var best = (page, cursor, natural)
        var low: CGFloat = 0
        var high: CGFloat = 1
        for iteration in 0..<9 {
            let fraction = iteration == 0 ? 1 : (low + high) / 2
            page = initialPage
            var candidate = initial
            let used = try trial(&self, &candidate, fraction)
            if iteration == 0 && candidate.item <= best.1.item { break }
            if candidate.item >= best.1.item {
                best = (page, candidate, used)
                high = fraction
            } else {
                low = fraction
            }
        }
        (page, cursor) = (best.0, best.1)
        return best.2
    }

    private mutating func fill(
        _ segment: Segment, cursor: inout Cursor, limit: CGFloat, shrinkFraction: CGFloat = 0,
        shrinkColumns: Bool = true
    ) throws -> CGFloat {
        let width = (full.width - CGFloat(segment.columns - 1) * segment.gap) / CGFloat(segment.columns)
        var base = top
        // In two-column mode LaTeX's @tryfcolumn builds a float column, not a float page, for a column-wide float.
        if let first = cursor.waiting.first, isFloatPage(first.item), page.pieces.isEmpty, page.footers.isEmpty,
            first.item.wide ? first.page < pages.count : segment.columns == 1
        {
            return try placeFloatPage(segment, cursor: &cursor, width: width, limit: limit)
        }
        // Starred floats wait for a fresh physical page, even if its second column is empty.
        if top == 0 && page.pieces.isEmpty && page.footers.isEmpty {
            var band = ColumnTop(index: page.pieces.count, textStart: base, hasFloats: false)
            try placeTops(segment, cursor: &cursor, lane: full, wide: true, band: &band, y: &base, limit: limit)
        }
        var deepest = base
        for index in 0..<segment.columns {
            let lane = Lane(x: CGFloat(index) * (width + segment.gap), width: width)
            if segment.columns > 1, let first = cursor.waiting.first, !first.item.wide, isFloatPage(first.item),
                (page.depths[lane] ?? base) <= base + 0.001,
                let depth = try placeFloatColumn(segment, lane: lane, base: base, cursor: &cursor, limit: limit)
            {
                deepest = max(deepest, depth)
                continue
            }
            let column: (depth: CGFloat, endPage: Bool)
            if shrinkColumns, segment.columns == 2, input.comparesColumnBreakBadness == true {
                column = try fillJournalColumn(
                    segment, lane: lane, index: index, base: base, cursor: &cursor, limit: limit)
            } else {
                column = try chooseColumn(
                    segment, lane: lane, index: index, base: base, cursor: &cursor, limit: limit,
                    shrinkFraction: shrinkFraction, shrinkColumns: shrinkColumns)
            }
            if column.endPage { return height }
            deepest = max(deepest, column.depth)
        }
        if segment.rule > 0 && deepest > base {
            for i in 1..<segment.columns {
                let center = CGFloat(i) * (width + segment.gap) - segment.gap / 2
                page.rules.append(
                    CGRect(x: center - segment.rule / 2, y: base, width: segment.rule, height: deepest - base))
            }
        }
        return deepest
    }

    // LaTeX's @flupdates subtracts the natural sizes of edge floats and their skips
    // from the text column goal. Their glue participates only when @cflt or @cflb
    // assembles the chosen column. In-text floats and footnotes belong to the body.
    private mutating func fillJournalColumn(
        _ segment: Segment, lane: Lane, index: Int, base: CGFloat, cursor: inout Cursor, limit: CGFloat
    ) throws -> (depth: CGFloat, endPage: Bool) {
        var builder = self
        builder.input.glueStretch?.textFloat = 0
        builder.input.glueStretch?.float = 0
        builder.input.glueShrink?.textFloat = 0
        builder.input.glueShrink?.float = 0
        var chosen = cursor
        let cut = try builder.chooseColumn(
            segment, lane: lane, index: index, base: base, cursor: &chosen, limit: limit,
            shrinkFraction: 0, shrinkColumns: true)
        let usage = builder.page.floats[lane]
        if (usage?.top ?? 0) + (usage?.bottom ?? 0) == 0, base == top, !pages.isEmpty || input.firstNotice == nil {
            page = builder.page
            cursor = chosen
            return cut
        }

        let initial = cursor
        let initialPage = page
        let natural = try fillColumn(
            segment, lane: lane, index: index, base: base, cursor: &cursor, limit: limit,
            shrinkFraction: 0, before: chosen.item)
        var depth = natural.depth
        if cursor.item < chosen.item {
            depth = try replayShrink(from: initialPage, initial: initial, cursor: &cursor, natural: depth) {
                layout, trial, fraction in
                layout.page.shrinkFraction = fraction
                return try layout.fillColumn(
                    segment, lane: lane, index: index, base: base, cursor: &trial, limit: limit,
                    shrinkFraction: fraction, before: chosen.item
                ).depth
            }
        }
        if cursor.item != chosen.item || cursor.waiting.count != chosen.waiting.count {
            // Replay must retain the cut and its deferred floats. Once a float is queued,
            // subsequent movable floats join it in source order until the next column.
            page = builder.page
            cursor = chosen
            return cut
        }
        cursor.floatAfterMovedHeading = chosen.floatAfterMovedHeading
        if recordsBreaks { page.columnBreaks = builder.page.columnBreaks }
        page.shrinkFraction = 0
        return (depth, cut.endPage)
    }

    private mutating func chooseColumn(
        _ segment: Segment, lane: Lane, index: Int, base: CGFloat, cursor: inout Cursor, limit: CGFloat,
        shrinkFraction: CGFloat, shrinkColumns: Bool
    ) throws -> (depth: CGFloat, endPage: Bool) {
        let initial = cursor
        let initialPage = page
        let natural = try fillColumn(
            segment, lane: lane, index: index, base: base, cursor: &cursor, limit: limit,
            shrinkFraction: shrinkFraction)
        if natural.endPage { return natural }
        var y = natural.depth
        // Each column has its own insertions and finite glue. Retrying both columns
        // together could shrink the left even when only the right gains a line.
        if shrinkColumns, segment.columns == 2, input.glueShrink != nil, !segment.pageNotes,
            cursor.item < segment.items.count, cursor.item == 0 || segment.items[cursor.item - 1].forced == nil
        {
            let naturalCursor = cursor
            let naturalPage = page
            var trialFit: CompressionTrial?
            var fullCompression: (item: Int, space: CGFloat)?
            y = try replayShrink(from: initialPage, initial: initial, cursor: &cursor, natural: y) {
                layout, trial, fraction in
                layout.page.shrinkFraction = fraction
                let result = try layout.fillColumn(
                    segment, lane: lane, index: index, base: base, cursor: &trial,
                    limit: limit, shrinkFraction: fraction
                )
                if fraction == 1, layout.recordsBreaks {
                    let cut = layout.page.columnBreaks.dropFirst(initialPage.columnBreaks.count).last
                    trialFit = CompressionTrial(
                        naturalNext: naturalCursor.item, fullNext: trial.item,
                        fullShortfall: cut.map { $0.required - $0.remaining })
                }
                if fraction == 1,
                    let space = layout.page.noteBreakSpace(in: lane, height: layout.height, full: layout.full)
                {
                    fullCompression = (trial.item, space)
                }
                return result.depth
            }
            if cursor.item > naturalCursor.item, cursor.item < segment.items.count,
                naturalCursor.item > initial.item, let glue = input.glueStretch,
                input.comparesColumnBreakBadness == true
                    || segment.items[cursor.item - 1].brokenAfter == true
                        && segment.items[naturalCursor.item - 1].brokenAfter != true
            {
                // TeX adds brokenpenalty (100) when a column ends mid-word.
                // Badness is 100 times the cube of the glue adjustment ratio.
                let stretch = naturalPage.stretchRatio(in: lane, height: height, full: full, glue: glue)
                let shrink = page.shrinkRatio(
                    in: lane, height: height, full: full,
                    fullyShrunkSpace: fullCompression?.item == cursor.item ? fullCompression?.space : nil)
                let naturalPenalty: CGFloat = segment.items[naturalCursor.item - 1].brokenAfter == true ? 1 : 0
                let compressedPenalty: CGFloat = segment.items[cursor.item - 1].brokenAfter == true ? 1 : 0
                let naturalCost = naturalPenalty + stretch * stretch * stretch
                let compressedCost = compressedPenalty + shrink * shrink * shrink
                trialFit?.naturalCost = naturalCost
                trialFit?.compressedCost = compressedCost
                if !shrink.isFinite || naturalCost < compressedCost {
                    page = naturalPage
                    cursor = naturalCursor
                    y = natural.depth
                }
            }
            if let trialFit, page.columnBreaks.count > initialPage.columnBreaks.count {
                page.columnBreaks[page.columnBreaks.count - 1].trial = trialFit
            }
            page.shrinkFraction = 0
        }
        return (y, false)
    }

    private mutating func fillColumn(
        _ segment: Segment, lane: Lane, index: Int, base: CGFloat,
        cursor: inout Cursor, limit: CGFloat, shrinkFraction: CGFloat, before itemLimit: Int = .max
    ) throws
        -> (depth: CGFloat, endPage: Bool)
    {
        defer {
            if lane != full && page.footers[lane] != nil { page.columnEnds[lane] = page.pieces.count }
        }
        if pages.isEmpty, segment.columns == 2 || input.singleColumnNotice == true, index == 0,
            let notice = input.columnNotice,
            !page.footers.values.contains(where: { $0.notes.contains(notice) })
        {
            guard notice.valid, base + notice.height - (notice.noteDepth ?? 0) + noteSkip <= height else {
                throw CannotFit()
            }
            page.footers[lane, default: Footer()].notes.insert(notice, at: 0)
            page.footers[lane, default: Footer()].noteSkip = noteSkip
            page.footers[lane, default: Footer()].height += notice.height + noteSkip
            if input.columnNoticeLast == true { page.footers[lane]?.lastNotice = notice }
        }
        let start = page.pieces.count
        var forcedColumn = false
        var lastDepth: CGFloat = 0
        var lastTextDepth: CGFloat?
        var pendingFill = Fill()
        var y = base
        var band = ColumnTop(index: page.pieces.count, textStart: base, hasFloats: base > top)
        try placeTops(segment, cursor: &cursor, lane: lane, wide: false, band: &band, y: &y, limit: limit)
        var tableFoot: Slice?
        var tableStart = 0
        var tableShrink: CGFloat = 0
        var atColumnTop = true
        var afterFloatPlus: CGFloat = base > top ? input.glueStretch?.textFloat ?? 0 : 0
        var followsHere = false
        var followsHeading = false
        var inTextKinds = Set<String>()
        while let first = cursor.waiting.first, !first.item.wide, !isFloatPage(first.item),
            let s = first.item.slice, let spec = first.item.placement, spec.contains("b"),
            try placeBottom(first.item, slice: s, spec: spec, segment: segment, lane: lane, y: y, limit: limit)
        {
            cursor.waiting.removeFirst()
        }
        while cursor.item < min(itemLimit, segment.items.count) {
            if cursor.item.isMultiple(of: 128) { try checkBudget() }
            let item = segment.items[cursor.item]
            if let forced = item.forced {
                cursor.item += 1
                if forced == "column" {
                    if y > base || index > 0 {
                        forcedColumn = true
                        break
                    }
                    continue
                }
                if y > 0 || !page.pieces.isEmpty || !cursor.waiting.isEmpty { return (height, true) }
                continue
            }
            if let weight = item.fil {
                // Discard ordinary vertical glue at a fresh column top, like a TeX page builder.
                if !atColumnTop || item.discardable == false {
                    y += item.gap
                    pendingFill = pendingFill + Fill(order: item.filOrder ?? 1, weight: weight)
                }
                cursor.item += 1
                continue
            }
            guard var s = item.slice, s.height > 0 else { throw CannotFit() }
            if let spec = item.placement {
                let pinned = spec.contains("H") && !item.wide
                // Two in-text floats each own their upper and lower intextsep.
                let hereSkip = max(0, inTextSep - (atColumnTop ? 0 : item.leadingBeforeHere ?? 0))
                let above =
                    atColumnTop && band.hasFloats
                    ? floatSep - textFloatSep : (y == 0 ? 0 : hereSkip)
                let scale = pinned ? min(1, height / s.height) : 1
                let below = min(inTextSep, max(0, height - s.height * scale))
                let cost = above + s.height * scale + below
                let queueClear =
                    cursor.waiting.isEmpty && page.footers[lane]?.kinds.contains(item.floatKind ?? "") != true
                // A float called by a heading carried over from the previous column
                // is already eligible for this column's top float list.
                if cursor.floatAfterMovedHeading == cursor.item && !pinned && !item.wide && queueClear
                    && spec.contains("t") && !inTextKinds.contains(item.floatKind ?? ""),
                    try insertTop(
                        item, slice: s, lane: lane, footLane: segment.pageNotes ? full : lane,
                        band: &band, y: &y, limit: limit)
                {
                    cursor.item += 1
                    continue
                }
                if pinned
                    || !item.wide && queueClear && spec.contains("h")
                        && allowsFloat(item, cost: cost, lane: lane, footLane: segment.pageNotes ? full : lane),
                    try reserve(
                        item, in: lane, footLane: segment.pageNotes ? full : lane,
                        end: y + cost - (pinned ? below : 0), limit: limit)
                {
                    page.draw(
                        s, at: y + above, lane: lane, scale: scale,
                        plus: atColumnTop && band.hasFloats
                            ? input.glueStretch?.float ?? 0
                            : afterFloatPlus + (above > 0 ? input.glueStretch?.inText ?? 0 : 0), fill: pendingFill)
                    pendingFill = Fill()
                    afterFloatPlus = input.glueStretch?.inText ?? 0
                    lastDepth = 0
                    lastTextDepth = nil
                    // The lower intextsep of an H box is discardable glue at a column break.
                    y = min(y + cost, limit, height - page.reserved(lane, full: full))
                    atColumnTop = false
                    followsHere = !pinned
                    followsHeading = false
                    inTextKinds.insert(item.floatKind ?? "")
                    if !pinned {
                        page.floats[lane, default: FloatUsage()].total += 1
                        page.floats[lane, default: FloatUsage()].occupied += cost
                    }
                } else if pinned {
                    // A frame figure travels with the source sequence, including when it needs a fresh column.
                    break
                } else if !item.wide && queueClear && spec.contains("t") && !spec.contains("h")
                    && !inTextKinds.contains(item.floatKind ?? ""),
                    try insertTop(
                        item, slice: s, lane: lane, footLane: segment.pageNotes ? full : lane,
                        band: &band, y: &y, limit: limit)
                {
                    cursor.item += 1
                    continue
                } else {
                    let wantsBottom = !item.wide && cursor.waiting.isEmpty && spec.contains("b")
                    let placed =
                        wantsBottom
                        ? try placeBottom(
                            item, slice: s, spec: spec, segment: segment, lane: lane, y: y, limit: limit)
                        : false
                    if !placed { cursor.waiting.append(Waiting(item: item, page: pages.count)) }
                }
                cursor.item += 1
                continue
            }
            if item.discardable == true && atColumnTop {
                cursor.item += 1
                continue
            }
            if atColumnTop && !band.hasFloats, let inset = item.topInset, inset > 0, inset < s.height {
                s.start += inset
            }
            let groupHeight = s.height + (item.corrections?.reduce(0) { $0 + $1.extra } ?? 0)
            guard groupHeight.isFinite, groupHeight > 0 else { throw CannotFit() }
            // The Japanese sectioning command starts with a null box at topskip.
            // An oversized group still has to make progress on an empty page.
            var gap = atColumnTop ? min(item.topSkip ?? 0, max(0, height - groupHeight)) : item.gap
            if atColumnTop, let adjustment = item.columnTopAdjustment { gap += adjustment }
            if followsHeading { gap += item.leadingAfterHeading ?? 0 }
            if followsHere { gap += item.leadingAfterHere ?? 0 }
            let scale = min(1, height / groupHeight)
            if !atColumnTop, let shrink = item.shrinkBefore {
                // Use only the glue needed to keep the following group on this page.
                let available = min(limit, height - page.reserved(lane, full: full))
                gap -=
                    input.glueShrink != nil
                    ? min(gap, shrink) * shrinkFraction
                    : min(gap, shrink, max(0, y + gap + groupHeight * scale - available))
            }
            let tableHead = atColumnTop ? item.repeatHead : nil
            gap += tableHead?.height ?? 0
            let naturalEnd = y + gap + groupHeight * scale
            let room = min(limit, height - page.reserved(lane, full: full))
            let internalShrink = (item.corrections?.reduce(0) { $0 + $1.shrink } ?? 0) * scale
            var shrink =
                input.glueShrink != nil
                ? internalShrink * shrinkFraction
                : min(max(0, naturalEnd - room), internalShrink)
            if let before = item.tablePreShrink {
                tableStart = page.pieces.count
                tableShrink = min(gap, before)
            }
            let footHeight = item.repeatFoot?.height ?? 0
            let depth =
                footHeight > 0 && item.notes.isEmpty && page.reserved(lane, full: full) == 0
                ? min(item.tableBreakDepth ?? 0, footHeight + groupHeight) : 0
            // A TeX column ends on the final baseline. The descent still paints
            // below it; every subsequent item must fit its own complete baseline.
            let textDepth = item.bottomDepth.map { min(groupHeight, $0) * scale }
            let bodyDepth =
                item.followingHeight == nil && item.notes.isEmpty && page.reserved(lane, full: full) == 0
                    && footHeight == 0
                ? textDepth ?? 0 : 0
            let required = naturalEnd - shrink + footHeight - depth - bodyDepth
            let take = footHeight > 0 ? min(tableShrink, max(0, required - room)) : 0
            let end = naturalEnd - shrink - take
            guard
                try reserve(
                    item, in: lane,
                    footLane: segment.titleNoteWidth.map { Lane(x: 0, width: $0) } ?? (segment.pageNotes ? full : lane),
                    end: end + footHeight - depth - bodyDepth, limit: limit)
            else {
                if recordsBreaks {
                    page.columnBreaks.append(
                        ColumnBreak(
                            column: index, nextItem: cursor.item, remaining: room - y,
                            required: end + footHeight - depth - bodyDepth - y))
                }
                if item.heading == true && end <= min(limit, height - page.reserved(lane, full: full)) {
                    cursor.floatAfterMovedHeading = cursor.item + 1
                }
                break
            }
            if take > 0 {
                // LTpre is shared by all the rows already placed in this lane. Consume
                // its finite shrink once, and only after accepting the new row.
                for i in tableStart..<page.pieces.count { page.pieces[i].y -= take }
                y -= take
                tableShrink -= take
            }
            if item.repeatFoot == nil { tableShrink = 0 }
            if let tableHead { page.draw(tableHead, at: y + gap - tableHead.height, lane: lane) }
            tableFoot = item.repeatFoot
            var plus = (atColumnTop ? 0 : item.stretchBefore ?? 0) + afterFloatPlus
            // A top float inserted before any text still owns its trailing textfloatsep.
            if atColumnTop && band.hasFloats { plus = input.glueStretch?.textFloat ?? 0 }
            afterFloatPlus = 0
            var part = s
            var target = y + gap
            for correction in item.corrections ?? [] {
                let take = min(
                    shrink, correction.shrink * scale * (input.glueShrink != nil ? shrinkFraction : 1))
                if correction.extra == 0 && take == 0 && correction.stretch == 0 { continue }
                part.end = correction.position
                if part.height > 0 {
                    page.draw(part, at: target, lane: lane, scale: scale, plus: plus, fill: pendingFill)
                    pendingFill = Fill()
                    plus = 0
                }
                plus += correction.stretch
                target += (part.height + correction.extra) * scale - take
                shrink -= take
                part.start = part.end
            }
            part.end = s.end
            if part.height > 0 {
                page.draw(part, at: target, lane: lane, scale: scale, plus: plus, fill: pendingFill)
                pendingFill = Fill()
            }
            y = end
            lastDepth = bodyDepth
            lastTextDepth = textDepth
            followsHere = false
            followsHeading = item.heading == true
            atColumnTop = false
            cursor.item += 1
        }
        if let tableFoot {
            page.draw(tableFoot, at: y, lane: lane)
            y += tableFoot.height
        }
        if !forcedColumn, input.glueStretch != nil, cursor.item < segment.items.count || !cursor.waiting.isEmpty,
            page.pieces.count > start
        {
            // At a break TeX carries the text line's depth separately and reserves the
            // whole footnote insertion. At shipout LaTeX aligns the final note baseline.
            var noteBreakEnd: CGFloat?
            if let strut = input.noteStrutDepth, strut > 0, let footer = page.footers[lane], footer.finalDepth > 0,
                tableFoot == nil, let lastTextDepth
            {
                noteBreakEnd = y - lastTextDepth + max(footer.finalDepth, strut)
            }
            page.stretches.append(
                ColumnStretch(
                    lane: lane, range: start..<page.pieces.count, end: y - lastDepth, noteBreakEnd: noteBreakEnd,
                    trailingFill: pendingFill))
        }
        return (y, false)
    }

    /// A note changes the capacity of every text column it spans. Commit the reservation only after
    /// both the new reference and the text already placed in those columns have passed the fit test.
    private mutating func reserve(_ item: Item, in lane: Lane, footLane: Lane, end: CGFloat, limit: CGFloat) throws
        -> Bool
    {
        let room = height - page.reserved(lane, full: full)
        if item.notes.isEmpty && item.followingHeight == nil { return end <= min(limit, room) + 0.001 }
        let following = item.followingHeight ?? 0
        let notes = try item.notes.map { id in
            guard let note = input.notes[id] else { throw CannotFit() }
            return note
        }
        let original = page.footers[footLane] ?? Footer()
        var footer = original
        footer.append(notes, skip: noteSkip)
        let extra = footer.reservedHeight - original.reservedHeight
        var followingFooter = footer
        followingFooter.append((item.followingNotes ?? []).compactMap { input.notes[$0] }, skip: noteSkip)
        let nextExtra = followingFooter.reservedHeight - footer.reservedHeight
        // If an oversized group and its notes cannot share even an empty page, allow
        // the normal oversized-block policy to advance instead of retrying forever.
        let keep = (item.slice?.height ?? 0) + following + extra + nextExtra <= height ? following : 0
        guard end + keep <= limit + 0.001, end + extra + keep + (keep > 0 ? nextExtra : 0) <= room + 0.001 else {
            return false
        }
        guard !notes.isEmpty else { return true }
        if footLane == full && page.reserved(full, full: full) + extra > height { return false }
        if footLane != full
            && page.footers.keys.contains(where: {
                $0 != full && $0 != footLane && $0.overlaps(footLane)
            })
        {
            return false
        }
        if page.depths.contains(where: {
            $0.key.overlaps(footLane) && $0.value + page.reserved($0.key, full: full) + extra > height + 0.001
        }) {
            return false
        }
        page.footers[footLane] = footer
        return true
    }

    private func allowsFloat(_ item: Item, cost: CGFloat, lane: Lane, footLane: Lane) -> Bool {
        let usage = page.floats[lane] ?? FloatUsage()
        let spanning = lane == full ? FloatUsage() : page.floats[full] ?? FloatUsage()
        // Bottom floats are already in the footer reservation. Only add the height of their
        // neighbouring notes here; each float (and its separation) is counted exactly once.
        let notes = page.footers.filter { $0.key.overlaps(lane) }.values.map {
            $0.notes.reduce(CGFloat.zero) { $0 + $1.height } + $0.noteSkip - $0.finalDepth
        }.reduce(0, +)
        var footer = page.footers[footLane] ?? Footer()
        let original = footer.reservedHeight
        footer.append(item.notes.compactMap { input.notes[$0] }, skip: noteSkip)
        let newNotes = footer.reservedHeight - original
        return usage.total + spanning.total < 3
            && (item.placement?.contains("!") == true
                || usage.occupied + spanning.occupied + cost + notes + newNotes <= height
                    * (1 - (input.floatFractions?.text ?? 0.2)))
    }

    private mutating func placeTops(
        _ segment: Segment, cursor: inout Cursor, lane: Lane, wide: Bool, band: inout ColumnTop,
        y: inout CGFloat, limit: CGFloat
    ) throws {
        while let first = cursor.waiting.first, first.item.wide == wide, !isFloatPage(first.item),
            let s = first.item.slice, let spec = first.item.placement,
            !wide || first.page < pages.count, wide || spec.contains("t") || spec.contains("h"),
            try insertTop(
                first.item, slice: s, lane: lane, footLane: segment.pageNotes ? full : lane,
                band: &band, y: &y, limit: limit)
        {
            cursor.waiting.removeFirst()
        }
    }

    private mutating func insertTop(
        _ item: Item, slice: Slice, lane: Lane, footLane: Lane, band: inout ColumnTop, y: inout CGFloat, limit: CGFloat
    ) throws -> Bool {
        var slice = slice
        if let inset = item.topInset, inset > 0, inset < slice.height { slice.start += inset }
        let use = page.floats[lane] ?? FloatUsage()
        let spanning = lane == full ? FloatUsage() : page.floats[full] ?? FloatUsage()
        let separation = band.hasFloats ? floatSep : 0
        let cost = slice.height + (band.hasFloats ? separation : textFloatSep)
        guard use.top + spanning.top < 2,
            item.placement?.contains("!") == true
                || use.topHeight + spanning.topHeight + separation + slice.height <= height
                    * (input.floatFractions?.top ?? 0.7),
            allowsFloat(item, cost: cost, lane: lane, footLane: footLane),
            page.footers[lane]?.kinds.contains(item.floatKind ?? "") != true,
            try reserve(item, in: lane, footLane: footLane, end: y + cost, limit: limit)
        else { return false }
        let floatY = band.textStart + (band.hasFloats ? separation - textFloatSep : 0)
        if !band.hasFloats, band.index < page.pieces.count {
            page.pieces[band.index].plusBefore += input.glueStretch?.textFloat ?? 0
        }
        for i in band.index..<page.pieces.count { page.pieces[i].y += cost }
        page.pieces.insert(
            Piece(
                slice: slice, x: lane.x, y: floatY, scale: 1,
                plusBefore: band.hasFloats ? input.glueStretch?.float ?? 0 : 0), at: band.index)
        band.index += 1
        band.textStart += cost
        band.hasFloats = true
        y += cost
        page.depths[lane] = max(page.depths[lane] ?? 0, y)
        page.floats[lane, default: FloatUsage()].top += 1
        page.floats[lane, default: FloatUsage()].total += 1
        page.floats[lane, default: FloatUsage()].topHeight += separation + slice.height
        page.floats[lane, default: FloatUsage()].occupied += cost
        return true
    }

    private mutating func placeBottom(
        _ item: Item, slice: Slice, spec: String, segment: Segment, lane: Lane, y: CGFloat, limit: CGFloat
    ) throws -> Bool {
        let cost = slice.height + textFloatSep
        guard page.floats[lane, default: FloatUsage()].bottom < 1,
            spec.contains("!") || slice.height <= height * (input.floatFractions?.bottom ?? 0.3),
            allowsFloat(item, cost: cost, lane: lane, footLane: segment.pageNotes ? full : lane),
            try reserve(item, in: lane, footLane: segment.pageNotes ? full : lane, end: y + cost, limit: limit)
        else { return false }
        page.footers[lane, default: Footer()].floats.append((slice, textFloatSep))
        page.footers[lane, default: Footer()].height += cost
        page.footers[lane, default: Footer()].kinds.insert(item.floatKind ?? "")
        page.floats[lane, default: FloatUsage()].bottom += 1
        page.floats[lane, default: FloatUsage()].total += 1
        page.floats[lane, default: FloatUsage()].occupied += cost
        return true
    }

    private mutating func placeFloatPage(
        _ segment: Segment, cursor: inout Cursor, width: CGFloat, limit: CGFloat
    ) throws -> CGFloat {
        var used: CGFloat = 0
        while let first = cursor.waiting.first, isFloatPage(first.item), let s = first.item.slice,
            !first.item.wide || first.page < pages.count
        {
            let lane = first.item.wide ? full : Lane(x: 0, width: width)
            let scale = min(1, height / s.height)
            let y = used + (page.pieces.isEmpty ? 0 : floatSep)
            guard
                try reserve(
                    first.item, in: lane, footLane: segment.pageNotes ? full : lane,
                    end: y + s.height * scale, limit: limit)
            else { break }
            page.draw(s, at: y, lane: lane, scale: scale)
            used = y + s.height * scale
            cursor.waiting.removeFirst()
        }
        // Equal stretch above and below the float group (LaTeX's fptop and fpbot glue).
        let offset = max(0, height - page.reserved(full, full: full) - used) / 2
        for i in page.pieces.indices { page.pieces[i].y += offset }
        return height
    }

    /// LaTeX's @startcolumn tries a float column first. Its floats are centred in the column by fptop and fpbot.
    private mutating func placeFloatColumn(
        _ segment: Segment, lane: Lane, base: CGFloat, cursor: inout Cursor, limit: CGFloat
    ) throws -> CGFloat? {
        let first = page.pieces.count
        var used = base
        while let next = cursor.waiting.first, !next.item.wide, isFloatPage(next.item), let s = next.item.slice {
            let scale = min(1, (height - base) / s.height)
            let y = used + (page.pieces.count > first ? floatSep : 0)
            guard
                try reserve(
                    next.item, in: lane, footLane: segment.pageNotes ? full : lane, end: y + s.height * scale,
                    limit: limit)
            else { break }
            page.draw(s, at: y, lane: lane, scale: scale)
            used = y + s.height * scale
            cursor.waiting.removeFirst()
        }
        guard page.pieces.count > first else { return nil }
        let bottom = height - page.reserved(lane, full: full)
        let offset = max(0, bottom - used) / 2
        for i in page.pieces.indices.dropFirst(first) { page.pieces[i].y += offset }
        page.depths[lane] = used + offset
        return used + offset
    }

    private func isFloatPage(_ item: Item) -> Bool {
        guard let spec = item.placement, let s = item.slice else { return false }
        let bottomOnly = spec.contains("b") && !spec.contains("t") && !spec.contains("h") && !item.wide
        return !spec.contains(where: { "htbH".contains($0) }) || s.height + textFloatSep > height
            || !spec.contains("!")
                && (s.height > height * (input.floatFractions?.page ?? 0.5)
                    || bottomOnly && s.height > height * (input.floatFractions?.bottom ?? 0.3))
    }
}
