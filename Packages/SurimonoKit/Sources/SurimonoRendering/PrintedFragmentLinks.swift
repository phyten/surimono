import PDFKit
import WebKit

/// Identify a DOM text fragment in the actual printed glyphs, without assuming that a
/// screen CSS pixel, a forced page break, or the origin of a cropped page maps to a fixed offset.
struct PrintedFragmentLinks: Decodable, Sendable {
    struct Box: Decodable, Sendable {
        let slice: Int
        let x, y, width, height: CGFloat
    }
    struct Span: Decodable, Sendable {
        let start: Int
        let end: Int
        var boxes: [Box]?
    }
    struct Anchor: Decodable, Sendable {
        let id: String
        let start: Int
        let end: Int
        var box: Box?
        var glyph: String?
    }
    struct Link: Decodable, Sendable {
        let id: String
        let url: String
        let start: Int
        let end: Int
        let top: Bool
        var boxes: [Box]?
    }
    struct Region: Sendable {
        let page: Int
        let bounds: CGRect
    }
    /// Open and validate the new bytes within the repair budget. Once transferred,
    /// only the renderer's actor can touch this PDFKit page tree.
    @MainActor final class Reopened {
        let document: PDFDocument
        init(_ document: sending PDFDocument) { self.document = document }
    }
    struct Output: Sendable {
        var bytes: Data?
        var reopened: Reopened?
        var anchors: [String: Region] = [:]
        var rows: [[Region]] = []
    }
    let text: String
    let links: [Link]
    let anchors: [Anchor]
    let rows: [Span]

    static let script = Bundle.module.url(forResource: "printed-fragments", withExtension: "js").flatMap {
        try? String(contentsOf: $0, encoding: .utf8)
    }

    @MainActor static func measure(
        in view: WKWebView, source: WebPaginator.Source, vertical: Bool, headingIDs: [String]
    ) async throws -> Self? {
        try Task.checkCancellation()
        guard let script, headingIDs.count <= 4096 else { return nil }
        var headingBytes = 0
        for id in headingIDs {
            headingBytes += id.utf8.count
            guard headingBytes <= 384_000 else { return nil }
        }
        let base: URL?
        switch source {
        case .html(_, let directory): base = directory
        case .snapshot: base = SnapshotSchemeHandler.rootURL
        case .sandboxed(_, let access, false):
            base = LocalResourceSchemeHandler.url(for: access.documentURL.deletingLastPathComponent())
        default: base = nil
        }
        return try await read { deadline in
            try await view.evaluateForPrinting(
                script,
                arguments: [
                    "resourceBase": base?.absoluteString ?? "", "vertical": vertical, "headingIDs": headingIDs,
                ], until: deadline
            ) as? String
        }
    }

    @MainActor static func read(
        budget: Duration = .milliseconds(500), using evaluate: (ContinuousClock.Instant) async throws -> String?
    ) async throws -> Self? {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now + budget
        do {
            guard let json = try await evaluate(deadline) else { return nil }
            return try await bounded(until: deadline) { try await decode(json) }
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    @concurrent private static func decode(_ json: String) async throws -> Self? {
        guard json.utf8.count <= 4_000_000 else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    /// The original bytes already contain the complete paper and no private annotations.
    /// Do not join a stalled PDFKit call on the main actor, even when its task ignores cancellation.
    static func bounded<Value: Sendable>(
        until deadline: ContinuousClock.Instant, work: @escaping @Sendable () async throws -> Value?
    ) async throws -> Value? {
        try Task.checkCancellation()
        guard .now < deadline else { return nil }
        let (stream, reply) = AsyncStream<Value>.makeStream()
        let worker = Task {
            if let output = try? await work(), ContinuousClock.now < deadline { reply.yield(output) }
            reply.finish()
        }
        let timer = Task {
            try await Task.sleep(until: deadline, clock: .continuous)
            reply.finish()
        }
        defer {
            timer.cancel()
            worker.cancel()
            reply.finish()
        }
        var iterator = stream.makeAsyncIterator()
        let answer = await iterator.next()
        try Task.checkCancellation()
        return answer
    }

    static let repairBudget: Duration = .seconds(1)

    func resolve(
        in data: Data, bindsLinks: Bool = true, verticalLayout: VerticalLayout? = nil,
        budget: Duration = Self.repairBudget
    ) async throws -> Output {
        try await Self.bounded(until: .now + budget) {
            try await match(data, bindsLinks: bindsLinks, verticalLayout: verticalLayout)
        } ?? Output()
    }

    @concurrent private func match(_ data: Data, bindsLinks: Bool, verticalLayout: VerticalLayout?) async throws
        -> Output
    {
        try Task.checkCancellation()
        guard data.count <= 64_000_000, let pdf = PDFDocument(data: data), pdf.pageCount <= 2048 else {
            return Output()
        }
        let index: PrintedTextIndex?
        if verticalLayout == nil {
            guard let ordered = try await PrintedTextIndex(document: pdf, text: text) else { return Output() }
            index = ordered
        } else {
            index = nil
        }
        func regions(start: Int, end: Int, boxes: [Box]?) throws -> [Region] {
            if let verticalLayout { return try verticalLayout.regions(boxes ?? []) }
            return try index?.regions(start: start, end: end) ?? []
        }
        var output = Output()
        var visited = 0
        func checkpoint() async throws {
            visited += 1
            if visited.isMultiple(of: 64) { await Task.yield() }
            try Task.checkCancellation()
        }
        for anchor in anchors {
            try await checkpoint()
            if let verticalLayout {
                output.anchors[anchor.id] = try verticalLayout.first(anchor, in: pdf)
            } else {
                output.anchors[anchor.id] = index?.first(start: anchor.start, end: anchor.end)
            }
        }
        for row in rows {
            try await checkpoint()
            output.rows.append(try regions(start: row.start, end: row.end, boxes: row.boxes))
        }
        guard bindsLinks else { return output }
        typealias Writer = ReadingPDFNavigationWriter
        var replace: [Writer.Link] = []
        var add: [Writer.NewLink] = []
        var remove: [Int: Set<Int>] = [:]
        var annotations: [Int: PrintedAnnotations] = [:]
        var used: [Int: Set<Int>] = [:]
        var remainingAnnotations = 32768
        // Only inspect pages containing a source link. Cache them for repeated references.
        for link in links {
            try await checkpoint()
            let destination: Writer.Destination?
            if link.top, let paper = pdf.page(at: 0)?.bounds(for: .cropBox) {
                destination = .init(page: 0, mode: "XYZ", arguments: [paper.minX, paper.maxY, nil])
            } else {
                destination = output.anchors[link.id].map {
                    .init(page: $0.page, mode: "XYZ", arguments: [$0.bounds.minX, $0.bounds.maxY, nil])
                }
            }
            let exact = try regions(start: link.start, end: link.end, boxes: link.boxes)
            // Generated list numbers can repeat a superscript. At an ambiguous position,
            // only a matching URL identifies the original link.
            let pieces =
                exact.isEmpty ? try index?.regions(start: link.start, end: link.end, allowAmbiguous: true) ?? [] : exact
            for piece in pieces {
                if annotations[piece.page] == nil {
                    let originals = pdf.page(at: piece.page)?.annotations ?? []
                    guard originals.count <= remainingAnnotations else { return Output() }
                    remainingAnnotations -= originals.count
                    annotations[piece.page] = try await PrintedAnnotations(originals)
                }
                guard let pageLinks = annotations[piece.page] else { continue }
                var matched = false
                for item in pageLinks.overlapping(piece.bounds) {
                    try await checkpoint()
                    let bounds = item.bounds
                    guard bounds.intersects(piece.bounds),
                        bounds.contains(CGPoint(x: piece.bounds.midX, y: piece.bounds.midY))
                            || piece.bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY))
                    else { continue }
                    if exact.isEmpty && item.url == nil { continue }
                    if let url = item.url, url != link.url {
                        guard let decoded = url.removingPercentEncoding, decoded == link.url.removingPercentEncoding
                        else { continue }
                    }
                    matched = true
                    let i = item.index
                    guard used[piece.page, default: []].insert(i).inserted else { continue }
                    if let destination {
                        replace.append(.init(page: piece.page, annotation: i, destination: destination))
                    } else {
                        remove[piece.page, default: []].insert(i)
                    }
                }
                if !matched, !exact.isEmpty, let destination {
                    add.append(.init(page: piece.page, bounds: piece.bounds, destination: destination))
                }
            }
        }
        if !replace.isEmpty || !add.isEmpty || !remove.isEmpty {
            let bytes = try Writer.repair(
                data, links: replace, bookmarks: nil, removingAnnotations: remove, adding: add)
            guard let reopened = PDFDocument(data: bytes), reopened.pageCount == pdf.pageCount else { return Output() }
            try Task.checkCancellation()
            output.reopened = await Reopened(reopened)
            output.bytes = bytes
        }
        return output
    }
}

extension PrintedFragmentLinks {
    /// WebKit captures top-down rectangles of a vertical strip. A slice can be scaled,
    /// placed in either booklet row, or split over pages when it contains a large table.
    struct VerticalLayout: Sendable {
        struct Slice: Sendable {
            let source: CGRect
            let paper: CGRect
            let page: Int

            func project(_ box: Box) -> Region? {
                let rect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height).intersection(source)
                guard !rect.isEmpty, source.width > 0, source.height > 0 else { return nil }
                let sx = paper.width / source.width
                let sy = paper.height / source.height
                let projected = CGRect(
                    x: paper.minX + (rect.minX - source.minX) * sx,
                    y: paper.maxY - (rect.maxY - source.minY) * sy, width: rect.width * sx, height: rect.height * sy)
                return Region(page: page, bounds: projected)
            }
        }

        private var slices: [Int: [Slice]] = [:]
        private var count = 0

        mutating func record(_ index: Int, _ slice: Slice) {
            guard count <= 16384 else { return }
            count += 1
            if count > 16384 {
                slices.removeAll()
                return
            }
            slices[index, default: []].append(slice)
        }

        func regions(_ boxes: [Box]) throws -> [Region] {
            var hits: [Region] = []
            for box in boxes {
                for slice in slices[box.slice] ?? [] {
                    try Task.checkCancellation()
                    if let hit = slice.project(box) { hits.append(hit) }
                }
            }
            return hits
        }

        func first(_ anchor: Anchor, in document: PDFDocument) throws -> Region? {
            guard let box = anchor.box, let glyph = anchor.glyph else { return nil }
            // PDFKit can extract the left column before its right-hand predecessor.
            // Identify the glyph at its painted location, independently of extraction order.
            var found: Region?
            for region in try regions([box]) {
                guard let page = document.page(at: region.page),
                    let selection = page.selection(for: region.bounds.insetBy(dx: -1, dy: -1)),
                    let text = page.string as NSString?
                else { continue }
                for n in 0..<selection.numberOfTextRanges(on: page) {
                    var remaining = selection.range(at: n, on: page)
                    guard remaining.location != NSNotFound, NSMaxRange(remaining) <= text.length else { continue }
                    while remaining.length > 0 {
                        try Task.checkCancellation()
                        let hit = text.range(of: glyph, options: .literal, range: remaining)
                        guard hit.location != NSNotFound, hit.length > 0 else { break }
                        if let bounds = page.selection(for: hit)?.bounds(for: page),
                            region.bounds.insetBy(dx: -1, dy: -1).contains(CGPoint(x: bounds.midX, y: bounds.midY))
                        {
                            guard found == nil else { return nil }
                            found = Region(page: region.page, bounds: bounds)
                        }
                        let end = NSMaxRange(hit)
                        remaining = NSRange(location: end, length: NSMaxRange(remaining) - end)
                    }
                }
            }
            return found
        }
    }
}

/// Index the vertical extents once per source page. A long contents page should not
/// rescan every other row for each link. The prefix maxima also handle tall annotations.
private struct PrintedAnnotations {
    struct Item {
        let index: Int
        let bounds: CGRect
        let url: String?
    }
    private let sorted: [Item]
    private let tops: [CGFloat]

    init(_ annotations: [PDFAnnotation]) async throws {
        var items: [Item] = []
        for (index, annotation) in annotations.enumerated() {
            if index.isMultiple(of: 64) {
                await Task.yield()
                try Task.checkCancellation()
            }
            guard annotation.type == "Link" else { continue }
            let action = annotation.action
            guard action == nil || action is PDFActionURL || action is PDFActionGoTo else { continue }
            let url = annotation.url ?? (action as? PDFActionURL)?.url
            items.append(.init(index: index, bounds: annotation.bounds, url: url?.absoluteString))
        }
        sorted = items.sorted { $0.bounds.minY < $1.bounds.minY }
        var maxima: [CGFloat] = []
        for annotation in sorted {
            maxima.append(max(maxima.last ?? -.infinity, annotation.bounds.maxY))
        }
        tops = maxima
    }

    func overlapping(_ rect: CGRect) -> ArraySlice<Item> {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = low + (high - low) / 2
            if tops[mid] < rect.minY { low = mid + 1 } else { high = mid }
        }
        let first = low
        high = sorted.count
        while low < high {
            let mid = low + (high - low) / 2
            if sorted[mid].bounds.minY <= rect.maxY { low = mid + 1 } else { high = mid }
        }
        return sorted[first..<low]
    }
}

/// Whitespace, list counters and print furniture can add characters to a page. Find the
/// earliest and latest order-preserving embeddings. Only coincident offsets prove an occurrence.
private struct PrintedTextIndex {
    let document: PDFDocument
    let firstMatch: [Int]
    let lastMatch: [Int]
    let glyphs: [(page: Int, offset: Int)]

    init?(document: PDFDocument, text: String) async throws {
        var paper: [UInt16] = []
        var glyphs: [(Int, Int)] = []
        let spaces = CharacterSet.whitespacesAndNewlines
        for i in 0..<document.pageCount {
            try Task.checkCancellation()
            if i.isMultiple(of: 16) { await Task.yield() }
            guard let page = document.page(at: i), page.numberOfCharacters < 524288 - paper.count else { return nil }
            let pageText = (page.string ?? "").utf16
            guard pageText.count <= 524288 - paper.count else { return nil }
            for (offset, unit) in pageText.enumerated() {
                if offset.isMultiple(of: 2048) { try Task.checkCancellation() }
                if unit == 0xad || unit == 0x200b || unit == 0xfeff || Unicode.Scalar(unit).map(spaces.contains) == true
                {
                    continue
                }
                paper.append(unit)
                glyphs.append((i, offset))
            }
        }
        let dom = Array(text.utf16)
        var low = Array(repeating: 0, count: dom.count)
        var high = low
        var next = 0
        for i in dom.indices {
            if i.isMultiple(of: 2048) { try Task.checkCancellation() }
            while next < paper.count, paper[next] != dom[i] { next += 1 }
            guard next < paper.count else { return nil }
            low[i] = next
            next += 1
        }
        next = paper.count
        for i in dom.indices.reversed() {
            if i.isMultiple(of: 2048) { try Task.checkCancellation() }
            while next > 0, paper[next - 1] != dom[i] { next -= 1 }
            guard next > 0 else { return nil }
            next -= 1
            high[i] = next
        }
        self.document = document
        self.glyphs = glyphs
        firstMatch = low
        lastMatch = high
    }

    func first(start: Int, end: Int) -> PrintedFragmentLinks.Region? {
        guard firstMatch.indices.contains(start), start < end, firstMatch[start] == lastMatch[start] else { return nil }
        let glyph = glyphs[firstMatch[start]]
        guard let page = document.page(at: glyph.page) else { return nil }
        // PDFKit's characterBounds counts drawn glyphs, while selection ranges count
        // UTF-16 text including the line separators synthesized by PDFKit.
        guard let rect = page.selection(for: NSRange(location: glyph.offset, length: 1))?.bounds(for: page) else {
            return nil
        }
        let visible = rect.intersection(page.bounds(for: .cropBox))
        guard !visible.isEmpty, !visible.isInfinite else { return nil }
        return .init(page: glyph.page, bounds: visible)
    }

    func regions(start: Int, end: Int, allowAmbiguous: Bool = false) throws -> [PrintedFragmentLinks.Region] {
        guard start >= 0, start < end, end <= firstMatch.count, end - start <= 16384 else { return [] }
        var result: [PrintedFragmentLinks.Region] = []
        var i = start
        while i < end {
            try Task.checkCancellation()
            if !allowAmbiguous && firstMatch[i] != lastMatch[i] { return [] }
            let first = glyphs[firstMatch[i]]
            var last = first
            i += 1
            while i < end, firstMatch[i] == firstMatch[i - 1] + 1, glyphs[firstMatch[i]].page == first.page {
                if !allowAmbiguous && firstMatch[i] != lastMatch[i] { return [] }
                last = glyphs[firstMatch[i]]
                i += 1
            }
            guard let page = document.page(at: first.page),
                let selection = page.selection(
                    for: NSRange(location: first.offset, length: last.offset - first.offset + 1))
            else { continue }
            for line in selection.selectionsByLine() {
                try Task.checkCancellation()
                let box = line.bounds(for: page).intersection(page.bounds(for: .cropBox))
                if !box.isEmpty, !box.isInfinite { result.append(.init(page: first.page, bounds: box)) }
            }
        }
        return result
    }
}
