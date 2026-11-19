import Foundation

/// All measurements use the same top-down CSS pixel coordinates as the capture view.
struct LaTeXFlowLayout {
    struct Slice: Codable, Equatable {
        var strip: Int
        var start: CGFloat
        var end: CGFloat
        var width: CGFloat
        var height: CGFloat { end - start }

        fileprivate var valid: Bool {
            strip >= 0 && start.isFinite && end.isFinite && height.isFinite && height > 0 && width.isFinite && width > 0
        }
    }

    struct Item: Decodable {
        var slice: Slice?
        var gap: CGFloat = 0
        var notes: [String] = []
        var placement: String?
        var floatKind: String?
        var wide: Bool = false
        var forced: String?
        var paragraph: Int?
        var heading: Bool?
        var discardable: Bool?
        var leadingBeforeHere: CGFloat?
        var extraAfter: CGFloat?
        var corrections: [Correction]?
    }

    struct Correction: Decodable {
        var position: CGFloat
        var extra: CGFloat
    }

    struct Segment: Decodable {
        var columns: Int
        var gap: CGFloat
        var rule: CGFloat
        var balance: Bool
        var pageNotes: Bool
        var items: [Item]
    }

    struct Probe: Decodable {
        let index: Int
        let strip: Int
        let position: CGFloat
    }

    struct Measurement: Decodable {
        var probes: [Probe]?
        var segments: [Segment]
        var notes: [String: Slice]
        var noteSkip: CGFloat
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
    }

    struct Page {
        var pieces: [Piece] = []
        var rules: [CGRect] = []
        fileprivate var footers: [Lane: Footer] = [:]
        fileprivate var columnEnds: [Lane: Int] = [:]
        fileprivate var depths: [Lane: CGFloat] = [:]
        fileprivate var floats: [Lane: FloatUsage] = [:]

        fileprivate mutating func draw(_ slice: Slice, at y: CGFloat, lane: Lane, scale: CGFloat = 1) {
            // Joining adjacent line groups makes capture cost proportional to columns rather than line count.
            if let last = pieces.last, last.slice.strip == slice.strip, last.x == lane.x, last.scale == 1,
                scale == 1, abs(last.y + slice.start - last.slice.start - y) < 0.001
            {
                pieces[pieces.count - 1].slice.end = slice.end
            } else {
                pieces.append(Piece(slice: slice, x: lane.x, y: y, scale: scale))
            }
            depths[lane] = max(depths[lane] ?? 0, y + slice.height * scale)
        }

        fileprivate func reserved(_ lane: Lane, full: Lane) -> CGFloat {
            let shared = footers[full]?.height ?? 0
            return shared
                + (footers.lazy.filter { $0.key != full && $0.key.overlaps(lane) }.map(\.value.height).max() ?? 0)
        }

        fileprivate mutating func finish(height: CGFloat, full: Lane, skip: CGFloat) {
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
                if lane == full { y = height - footer.height }
                for (slice, space) in footer.floats {
                    y += space
                    blocks.append(Piece(slice: slice, x: lane.x, y: y, scale: 1))
                    y += slice.height
                }
                if !footer.notes.isEmpty {
                    y += skip
                    rules.append(CGRect(x: lane.x, y: y - min(3, skip / 2), width: min(180, lane.width), height: 0.5))
                }
                for slice in footer.notes {
                    blocks.append(Piece(slice: slice, x: lane.x, y: y, scale: 1))
                    y += slice.height
                }
                pieces.insert(contentsOf: blocks, at: insertion(lane))
            }
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

    fileprivate struct Footer {
        var notes: [Slice] = []
        var floats: [(Slice, CGFloat)] = []
        var kinds: Set<String> = []
        var height: CGFloat = 0
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
    }

    private let input: Measurement
    private let full: Lane
    private let height: CGFloat
    private let deadline: ContinuousClock.Instant?
    private var pages: [Page] = []
    private var page = Page()
    private var top: CGFloat = 0

    static func pages(
        _ input: Measurement, width: CGFloat, height: CGFloat, until deadline: ContinuousClock.Instant? = nil
    ) throws -> [Page] {
        let spacing = [input.noteSkip, input.textFloatSep, input.floatSep, input.inTextSep]
        guard width.isFinite, width > 0, height.isFinite, height > 0,
            spacing.allSatisfy({ $0.isFinite && $0 >= 0 }), input.notes.values.allSatisfy(\.valid)
        else { throw CannotFit() }
        var layout = Self(input: input, full: Lane(x: 0, width: width), height: height, deadline: deadline)
        for var segment in input.segments where !segment.items.isEmpty {
            try layout.checkBudget()
            guard segment.rule.isFinite, segment.gap.isFinite,
                segment.items.allSatisfy({
                    $0.gap.isFinite && ($0.leadingBeforeHere ?? 0).isFinite && ($0.extraAfter ?? 0).isFinite
                        && ($0.extraAfter ?? 0) > -1
                        && ($0.slice?.valid ?? ($0.forced != nil))
                })
            else { throw CannotFit() }
            segment.items = keptItems(segment.items, capacity: height)
            // A clear page drains the old queue before text after the command can enter the new one.
            var start = 0
            for i in segment.items.indices where segment.items[i].forced == "clear" || segment.items[i].forced == "page"
            {
                var part = segment
                part.items = Array(segment.items[start..<i])
                try layout.place(part)
                if !layout.page.pieces.isEmpty || !layout.page.footers.isEmpty { layout.endPage() }
                start = i + 1
            }
            if start > 0 { segment.items = Array(segment.items[start...]) }
            try layout.place(segment)
        }
        if !layout.page.pieces.isEmpty || !layout.page.footers.isEmpty || layout.pages.isEmpty { layout.endPage() }
        return layout.pages
    }

    static func keptItems(_ items: [Item], capacity: CGFloat) -> [Item] {
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
            let bands = (first..<end).compactMap { i -> FlowPageCuts.Band? in
                guard let s = items[i].slice else { return nil }
                let p = items[i].paragraph ?? 0
                let sameNext = p != 0 && i + 1 < end && items[i + 1].paragraph == p
                let firstPair = i == first || items[i - 1].paragraph != p
                let lastPair = i + 2 >= end || items[i + 2].paragraph != p
                return .init(
                    start: s.start, end: s.end,
                    keepNext: items[i].heading == true || sameNext && (firstPair || lastPair))
            }
            var i = first
            for band in FlowPageCuts.groups(for: bands, capacity: capacity) {
                var item = items[i]
                item.slice?.start = band.start
                item.slice?.end = band.end
                let start = i
                repeat {
                    if i != start { item.notes.append(contentsOf: items[i].notes) }
                    if let extra = items[i].extraAfter, extra != 0, let slice = items[i].slice {
                        if item.corrections == nil { item.corrections = [] }
                        item.corrections?.append(Correction(position: slice.end, extra: extra))
                    }
                    i += 1
                } while i < end && (items[i].slice?.end ?? .infinity) <= band.end
                result.append(item)
            }
            first = end
        }
        return result
    }

    private func checkBudget() throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw CannotFit() }
    }

    private mutating func endPage() {
        page.finish(height: height, full: full, skip: input.noteSkip)
        pages.append(page)
        page = Page()
        top = 0
    }

    private mutating func place(_ segment: Segment) throws {
        guard (1...2).contains(segment.columns), segment.gap >= 0,
            full.width > CGFloat(segment.columns - 1) * segment.gap
        else { throw CannotFit() }
        var cursor = Cursor()
        while cursor.item < segment.items.count || !cursor.waiting.isEmpty {
            try checkBudget()
            let initial = cursor
            let initialPage = page
            let initialTop = top
            var depth = try fill(segment, cursor: &cursor, limit: height)
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
                top = max(initialTop, depth)
                return
            }
            if page.pieces.isEmpty && page.footers.isEmpty {
                guard cursor.item != initial.item else { throw CannotFit() }
                if cursor.waiting.first?.item.wide != true { continue }
            }
            endPage()
        }
    }

    private mutating func fill(_ segment: Segment, cursor: inout Cursor, limit: CGFloat) throws -> CGFloat {
        let width = (full.width - CGFloat(segment.columns - 1) * segment.gap) / CGFloat(segment.columns)
        var base = top
        if let first = cursor.waiting.first, isFloatPage(first.item), page.pieces.isEmpty, page.footers.isEmpty,
            !first.item.wide || first.page < pages.count
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
            defer {
                if lane != full && page.footers[lane] != nil { page.columnEnds[lane] = page.pieces.count }
            }
            var y = base
            var band = ColumnTop(index: page.pieces.count, textStart: base, hasFloats: base > top)
            try placeTops(segment, cursor: &cursor, lane: lane, wide: false, band: &band, y: &y, limit: limit)
            var atColumnTop = true
            var inTextKinds = Set<String>()
            while let first = cursor.waiting.first, !first.item.wide, !isFloatPage(first.item),
                let s = first.item.slice, let spec = first.item.placement, spec.contains("b"),
                try placeBottom(first.item, slice: s, spec: spec, segment: segment, lane: lane, y: y, limit: limit)
            {
                cursor.waiting.removeFirst()
            }
            while cursor.item < segment.items.count {
                if cursor.item.isMultiple(of: 128) { try checkBudget() }
                let item = segment.items[cursor.item]
                if let forced = item.forced {
                    cursor.item += 1
                    if forced == "column" {
                        if y > base || index > 0 { break }
                        continue
                    }
                    if y > 0 || !page.pieces.isEmpty || !cursor.waiting.isEmpty { return height }
                    continue
                }
                guard let s = item.slice, s.height > 0 else { throw CannotFit() }
                if let spec = item.placement {
                    let pinned = spec.contains("H") && !item.wide
                    // Two in-text floats each own their upper and lower intextsep.
                    let hereSkip = max(0, input.inTextSep - (atColumnTop ? 0 : item.leadingBeforeHere ?? 0))
                    let above =
                        atColumnTop && band.hasFloats
                        ? input.floatSep - input.textFloatSep : (y == 0 ? 0 : hereSkip)
                    let scale = pinned ? min(1, height / s.height) : 1
                    let below = min(input.inTextSep, max(0, height - s.height * scale))
                    let cost = above + s.height * scale + below
                    let queueClear =
                        cursor.waiting.isEmpty && page.footers[lane]?.kinds.contains(item.floatKind ?? "") != true
                    if pinned
                        || !item.wide && queueClear && spec.contains("h")
                            && allowsFloat(item, cost: cost, lane: lane, footLane: segment.pageNotes ? full : lane),
                        try reserve(
                            item, in: lane, footLane: segment.pageNotes ? full : lane, end: y + cost, limit: limit)
                    {
                        page.draw(s, at: y + above, lane: lane, scale: scale)
                        y += cost
                        atColumnTop = false
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
                let gap = atColumnTop ? 0 : item.gap
                let groupHeight = s.height + (item.corrections?.reduce(0) { $0 + $1.extra } ?? 0)
                guard groupHeight.isFinite, groupHeight > 0 else { throw CannotFit() }
                let scale = min(1, height / groupHeight)
                let end = y + gap + groupHeight * scale
                guard try reserve(item, in: lane, footLane: segment.pageNotes ? full : lane, end: end, limit: limit)
                else { break }
                var part = s
                var target = y + gap
                for correction in item.corrections ?? [] {
                    part.end = correction.position
                    page.draw(part, at: target, lane: lane, scale: scale)
                    target += (part.height + correction.extra) * scale
                    part.start = part.end
                }
                part.end = s.end
                if part.height > 0 { page.draw(part, at: target, lane: lane, scale: scale) }
                y = end
                atColumnTop = false
                cursor.item += 1
            }
            deepest = max(deepest, y)
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

    /// A note changes the capacity of every text column it spans. Commit the reservation only after
    /// both the new reference and the text already placed in those columns have passed the fit test.
    private mutating func reserve(_ item: Item, in lane: Lane, footLane: Lane, end: CGFloat, limit: CGFloat) throws
        -> Bool
    {
        guard end <= limit + 0.001 else { return false }
        let room = height - page.reserved(lane, full: full)
        guard !item.notes.isEmpty else { return end <= room + 0.001 }
        let notes = try item.notes.map { id in
            guard let note = input.notes[id] else { throw CannotFit() }
            return note
        }
        let extra =
            notes.reduce(0) { $0 + $1.height } + (page.footers[footLane]?.notes.isEmpty != false ? input.noteSkip : 0)
        guard end + extra <= room + 0.001 else { return false }
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
        page.footers[footLane, default: Footer()].notes += notes
        page.footers[footLane, default: Footer()].height += extra
        return true
    }

    private func allowsFloat(_ item: Item, cost: CGFloat, lane: Lane, footLane: Lane) -> Bool {
        let usage = page.floats[lane] ?? FloatUsage()
        let spanning = lane == full ? FloatUsage() : page.floats[full] ?? FloatUsage()
        // Bottom floats are already in the footer reservation. Only add the height of their
        // neighbouring notes here; each float (and its separation) is counted exactly once.
        let notes = page.footers.filter { $0.key.overlaps(lane) }.values.map {
            $0.notes.reduce(CGFloat.zero) { $0 + $1.height } + ($0.notes.isEmpty ? 0 : input.noteSkip)
        }.reduce(0, +)
        let newNotes = item.notes.reduce(CGFloat.zero) { $0 + (input.notes[$1]?.height ?? 0) }
        let skip = !item.notes.isEmpty && page.footers[footLane]?.notes.isEmpty != false ? input.noteSkip : 0
        return usage.total + spanning.total < 3
            && (item.placement?.contains("!") == true
                || usage.occupied + spanning.occupied + cost + notes + newNotes + skip <= height * 0.8)
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
        let use = page.floats[lane] ?? FloatUsage()
        let spanning = lane == full ? FloatUsage() : page.floats[full] ?? FloatUsage()
        let separation = band.hasFloats ? input.floatSep : 0
        let cost = slice.height + (band.hasFloats ? separation : input.textFloatSep)
        guard use.top + spanning.top < 2,
            item.placement?.contains("!") == true
                || use.topHeight + spanning.topHeight + separation + slice.height <= height * 0.7,
            allowsFloat(item, cost: cost, lane: lane, footLane: footLane),
            page.footers[lane]?.kinds.contains(item.floatKind ?? "") != true,
            try reserve(item, in: lane, footLane: footLane, end: y + cost, limit: limit)
        else { return false }
        let floatY = band.textStart + (band.hasFloats ? separation - input.textFloatSep : 0)
        for i in band.index..<page.pieces.count { page.pieces[i].y += cost }
        page.pieces.insert(Piece(slice: slice, x: lane.x, y: floatY, scale: 1), at: band.index)
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
        let cost = slice.height + input.textFloatSep
        guard page.floats[lane, default: FloatUsage()].bottom < 1,
            spec.contains("!") || slice.height <= height * 0.3,
            allowsFloat(item, cost: cost, lane: lane, footLane: segment.pageNotes ? full : lane),
            try reserve(item, in: lane, footLane: segment.pageNotes ? full : lane, end: y + cost, limit: limit)
        else { return false }
        page.footers[lane, default: Footer()].floats.append((slice, input.textFloatSep))
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
            let y = used + (page.pieces.isEmpty ? 0 : input.floatSep)
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

    private func isFloatPage(_ item: Item) -> Bool {
        guard let spec = item.placement, let s = item.slice else { return false }
        let bottomOnly = spec.contains("b") && !spec.contains("t") && !spec.contains("h") && !item.wide
        return !spec.contains(where: { "htbH".contains($0) }) || s.height + input.textFloatSep > height
            || !spec.contains("!") && (s.height > height * 0.5 || bottomOnly && s.height > height * 0.3)
    }
}
