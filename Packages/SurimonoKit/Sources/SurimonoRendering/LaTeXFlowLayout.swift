import Foundation

/// All measurements use the same top-down CSS pixel coordinates as the capture view.
struct LaTeXFlowLayout {
    struct Slice: Codable, Equatable {
        var strip: Int
        var start: CGFloat
        var end: CGFloat
        var width: CGFloat
        var height: CGFloat { end - start }
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
        fileprivate var depths: [Lane: CGFloat] = [:]
        fileprivate var floatCount = 0

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
            for (lane, footer) in footers.sorted(by: {
                $0.key.x < $1.key.x || ($0.key.x == $1.key.x && $0.key.width < $1.key.width)
            }) {
                var y = height - reserved(lane, full: full)
                if lane == full { y = height - footer.height }
                for (slice, space) in footer.floats {
                    y += space
                    pieces.append(Piece(slice: slice, x: lane.x, y: y, scale: 1))
                    y += slice.height
                }
                if !footer.notes.isEmpty {
                    y += skip
                    rules.append(CGRect(x: lane.x, y: y - min(3, skip / 2), width: min(180, lane.width), height: 0.5))
                }
                for slice in footer.notes {
                    pieces.append(Piece(slice: slice, x: lane.x, y: y, scale: 1))
                    y += slice.height
                }
            }
            footers.removeAll()
        }
    }

    fileprivate struct Lane: Hashable {
        var x: CGFloat
        var width: CGFloat
        func overlaps(_ other: Lane) -> Bool { min(x + width, other.x + other.width) - max(x, other.x) > 0.001 }
    }

    fileprivate struct Footer {
        var notes: [Slice] = []
        var floats: [(Slice, CGFloat)] = []
        var kinds: Set<String> = []
        var height: CGFloat = 0
    }

    struct CannotFit: Error {}

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
    private var pages: [Page] = []
    private var page = Page()
    private var top: CGFloat = 0

    static func pages(_ input: Measurement, width: CGFloat, height: CGFloat) throws -> [Page] {
        var layout = Self(input: input, full: Lane(x: 0, width: width), height: height)
        for var segment in input.segments where !segment.items.isEmpty {
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
                i += 1
                while i < end, let s = items[i].slice, s.end <= band.end {
                    item.notes.append(contentsOf: items[i].notes)
                    i += 1
                }
                result.append(item)
            }
            first = end
        }
        return result
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
            try Task.checkCancellation()
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
                    let mid = (low + high) / 2
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
        // Starred floats wait for a fresh physical page, even if its second column is empty.
        while let first = cursor.waiting.first, let s = first.item.slice,
            first.item.wide || isFloatPage(first.item), page.pieces.isEmpty || base > 0,
            first.page < pages.count || !first.item.wide, top == 0
        {
            let dedicated = isFloatPage(first.item)
            let scale = min(1, height / s.height)
            let lane = first.item.wide ? full : Lane(x: 0, width: width)
            guard !dedicated || page.pieces.isEmpty,
                try reserve(
                    first.item, in: lane, footLane: segment.pageNotes ? full : lane,
                    end: base + s.height * scale, limit: limit)
            else { break }
            page.draw(s, at: base, lane: lane, scale: scale)
            cursor.waiting.removeFirst()
            page.floatCount += 1
            base += s.height * scale + input.textFloatSep
            if dedicated { return height }
            if page.floatCount >= 2 { break }
        }
        var deepest = base
        for index in 0..<segment.columns {
            let lane = Lane(x: CGFloat(index) * (width + segment.gap), width: width)
            var y = base
            while let first = cursor.waiting.first, !first.item.wide, !isFloatPage(first.item),
                let s = first.item.slice, page.floatCount < 2
            {
                let spec = first.item.placement ?? ""
                if spec.contains("b") && !spec.contains("t") && !spec.contains("h") && !spec.contains("H"),
                    try reserve(
                        first.item, in: lane, footLane: segment.pageNotes ? full : lane,
                        end: y + s.height + input.textFloatSep, limit: limit)
                {
                    addBottomFloat(s, kind: first.item.floatKind, lane: lane)
                    cursor.waiting.removeFirst()
                    continue
                }
                if page.footers[lane]?.kinds.contains(first.item.floatKind ?? "") == true { break }
                let bang = spec.contains("!")
                let scale = min(1, height / s.height)
                guard bang || y + s.height <= height * 0.8 || page.pieces.isEmpty,
                    try reserve(
                        first.item, in: lane, footLane: segment.pageNotes ? full : lane,
                        end: y + s.height * scale, limit: limit)
                else { break }
                page.draw(s, at: y, lane: lane, scale: scale)
                cursor.waiting.removeFirst()
                page.floatCount += 1
                y += s.height * scale + (cursor.waiting.isEmpty ? input.textFloatSep : input.floatSep)
            }
            while cursor.item < segment.items.count {
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
                    let footLane = segment.pageNotes ? full : lane
                    let earlierAtBottom = page.footers[lane]?.kinds.contains(item.floatKind ?? "") == true
                    if !item.wide && !earlierAtBottom && cursor.waiting.isEmpty
                        && (spec.contains("h") || spec.contains("H")),
                        try reserve(
                            item, in: lane, footLane: footLane, end: y + s.height + input.inTextSep, limit: limit)
                    {
                        page.draw(s, at: y + input.inTextSep / 2, lane: lane)
                        y += s.height + input.inTextSep
                    } else if !item.wide && cursor.waiting.isEmpty && spec.contains("b") && !spec.contains("t"),
                        page.floatCount < 2,
                        try reserve(
                            item, in: lane, footLane: footLane, end: y + s.height + input.textFloatSep, limit: limit)
                    {
                        addBottomFloat(s, kind: item.floatKind, lane: lane)
                    } else {
                        cursor.waiting.append(Waiting(item: item, page: pages.count))
                    }
                    cursor.item += 1
                    continue
                }
                let gap = y == base ? 0 : item.gap
                let scale = min(1, height / s.height)
                let end = y + gap + s.height * scale
                guard try reserve(item, in: lane, footLane: segment.pageNotes ? full : lane, end: end, limit: limit)
                else { break }
                page.draw(s, at: y + gap, lane: lane, scale: scale)
                y = end
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

    private mutating func addBottomFloat(_ slice: Slice, kind: String?, lane: Lane) {
        page.footers[lane, default: Footer()].floats.append((slice, input.textFloatSep))
        page.footers[lane, default: Footer()].height += slice.height + input.textFloatSep
        page.footers[lane, default: Footer()].kinds.insert(kind ?? "")
        page.floatCount += 1
    }

    private func isFloatPage(_ item: Item) -> Bool {
        guard let spec = item.placement, spec.contains("p"), let slice = item.slice else { return false }
        return !spec.contains(where: { "htbH".contains($0) }) || slice.height > height * 0.7
    }
}
