import PDFKit

/// Aligns the text read from a DOM with the text of the pages printed from it, tolerating differences on either
/// side: a page can carry characters that are not in the DOM (list numbers, heading counters, hyphens), and its text
/// can lack some that are (a ligature extracted as one letter: Hiragino's "ll" in "Filler" reads "Filer").
///
/// `PrintedTextIndex` proves an occurrence by requiring every DOM character in an order-preserving embedding, so a
/// single lost glyph leaves a whole document without an index; this walks both texts together instead and
/// resynchronizes on the nearest run of characters that both share, from either end (`placements(dom:paper:)`). A
/// character counts as placed only where both walks agree, inside a run of matches, so a coincidental match while
/// resynchronizing places nothing.
struct PrintedTextAlignment {
    let document: PDFDocument
    private let pages: [Int32]
    private let offsets: [Int32]
    /// The printed character of each DOM character, -1 where it is not placed.
    private let matches: [Int32]

    /// Characters on both sides that confirm a resynchronization.
    private static let anchor = 6
    /// Consecutive matches that make a character placed.
    private static let run = 3

    var count: Int { matches.count }

    /// - Parameters:
    ///   - document: The printed pages, opened from `data`; positions are read from it later.
    ///   - limit: The most UTF-16 units of printed text to read; a longer document has no alignment.
    init?(document: PDFDocument, data: Data, text: String, limit: Int) async throws {
        var paper: [UInt16] = []
        var pages: [Int32] = []
        var offsets: [Int32] = []
        let spaces = CharacterSet.whitespacesAndNewlines
        guard let texts = try await Self.pageTexts(of: data, count: document.pageCount, limit: limit),
            texts.count == document.pageCount
        else { return nil }
        for (i, pageText) in texts.enumerated() {
            try Task.checkCancellation()
            guard pageText.count <= limit - paper.count else { return nil }
            for (offset, unit) in pageText.enumerated() {
                if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
                if unit == 0xad || unit == 0x200b || unit == 0xfeff || Unicode.Scalar(unit).map(spaces.contains) == true
                {
                    continue
                }
                for folded in Self.fold(unit) {
                    paper.append(folded)
                    pages.append(Int32(i))
                    offsets.append(Int32(offset))
                }
            }
        }
        let dom = text.utf16.map { Self.fold($0).first ?? $0 }
        let matches = try Self.placements(dom: dom, paper: paper)
        self.document = document
        self.pages = pages
        self.offsets = offsets
        self.matches = matches
    }

    /// The printed character of each DOM character, -1 where it is not placed (both texts already folded).
    ///
    /// A resynchronization finds a run that both texts share, which is not yet the right occurrence of it: a term
    /// repeated later, with the reading order of the page swapped (terms printed before their definitions), matches
    /// the later occurrence. So the texts are walked from both ends, and a character is placed only where the two
    /// walks put it on the same printed character: the walk from the start takes the earliest occurrence that fits,
    /// the walk from the end the latest, and they agree only where no other occurrence fits between the anchors on
    /// either side. Where they disagree, the heading that needs the character is left unmeasured.
    static func placements(dom: [UInt16], paper: [UInt16]) throws -> [Int32] {
        let forward = try walk(dom, paper)
        let reversed = try walk(dom.reversed(), paper.reversed())
        var matches = [Int32](repeating: -1, count: dom.count)
        let last = Int32(paper.count - 1)
        for i in dom.indices {
            let back = reversed[dom.count - 1 - i]
            if forward[i] >= 0, back >= 0, forward[i] == last - back { matches[i] = forward[i] }
        }
        var placed = [Int32](repeating: -1, count: dom.count)
        var start = 0
        while start < dom.count {
            guard matches[start] >= 0 else {
                start += 1
                continue
            }
            var end = start + 1
            while end < dom.count, matches[end] == matches[end - 1] + 1 { end += 1 }
            if end - start >= Self.run { for k in start..<end { placed[k] = matches[k] } }
            start = end
        }
        return placed
    }

    /// One walk through both texts in reading order, matching where they agree and resynchronizing where not.
    private static func walk(_ dom: [UInt16], _ paper: [UInt16]) throws -> [Int32] {
        var matches = [Int32](repeating: -1, count: dom.count)
        var far: FarIndex?
        var i = 0
        var j = 0
        // A resynchronization costs up to a thousand comparisons and a few hundred lookups, so it counts for more
        // than a match before the next check for cancellation.
        var work = 0
        while i < dom.count {
            work += 1
            if work >= 4096 {
                work = 0
                try Task.checkCancellation()
            }
            if j < paper.count, paper[j] == dom[i] {
                matches[i] = Int32(j)
                i += 1
                j += 1
                continue
            }
            work += 512
            if let (di, dj) = Self.nearSync(dom, i, paper, j) {
                i += di
                j += dj
                continue
            }
            work += 2048
            if far == nil { far = try FarIndex(paper, k: Self.anchor) }
            if let far, let (di, dj) = far.sync(dom, i, j) {
                i += di
                j += dj
                continue
            }
            i += 1
        }
        return matches
    }

    /// The text of each page, nil when it is longer than `limit` UTF-16 units. PDFKit takes most of the measurement
    /// extracting it, one page after another, so a long document is read by a few workers, each from a document of
    /// its own (a `PDFDocument` is not shared across threads). A worker stops as soon as its own share is over the
    /// limit, rather than after holding every page.
    private static func pageTexts(of data: Data, count: Int, limit: Int) async throws -> [String.UTF16View]? {
        let workers = count < 16 ? 1 : min(4, ProcessInfo.processInfo.activeProcessorCount)
        let size = (count + workers - 1) / workers
        return try await withThrowingTaskGroup(of: (Int, [String.UTF16View]?).self) { group in
            for worker in 0..<workers {
                group.addTask {
                    guard let document = PDFDocument(data: data) else { return (worker, []) }
                    var texts: [String.UTF16View] = []
                    var units = 0
                    for page in (worker * size)..<min(count, (worker + 1) * size) {
                        try Task.checkCancellation()
                        let text = (document.page(at: page)?.string ?? "").utf16
                        units += text.count
                        guard units <= limit else { return (worker, nil) }
                        texts.append(text)
                    }
                    return (worker, texts)
                }
            }
            var parts = [[String.UTF16View]](repeating: [], count: workers)
            for try await (worker, texts) in group {
                guard let texts else {
                    group.cancelAll()
                    return nil
                }
                parts[worker] = texts
            }
            return parts.flatMap { $0 }
        }
    }

    /// A ligature's letters, and ASCII letters in lower case, for a theme that prints headings in capitals.
    private static func fold(_ unit: UInt16) -> [UInt16] {
        switch unit {
        case 0x41...0x5a: [unit + 0x20]
        case 0xfb00: [0x66, 0x66]
        case 0xfb01: [0x66, 0x69]
        case 0xfb02: [0x66, 0x6c]
        case 0xfb03: [0x66, 0x66, 0x69]
        case 0xfb04: [0x66, 0x66, 0x6c]
        case 0xfb05, 0xfb06: [0x73, 0x74]
        default: [unit]
        }
    }

    private static func agree(_ dom: [UInt16], _ i: Int, _ paper: [UInt16], _ j: Int) -> Bool {
        let length = min(anchor, dom.count - i)
        guard length > 0, j + length <= paper.count else { return false }
        for k in 0..<length where dom[i + k] != paper[j + k] { return false }
        return true
    }

    /// The nearest point within a few characters where both texts go on alike: most differences are a list number
    /// or a lost ligature letter. The skips are tried by their total, so that a short item printed out of the source
    /// order (an Org planning item drawn beside the next line) is skipped rather than the longer text after it.
    private static func nearSync(_ dom: [UInt16], _ i: Int, _ paper: [UInt16], _ j: Int) -> (Int, Int)? {
        for cost in 1...48 {
            for di in 0...min(cost, 32) {
                let dj = cost - di
                guard dj <= 32 else { continue }
                if agree(dom, i + di, paper, j + dj) { return (di, dj) }
            }
        }
        return nil
    }

    /// Runs of the printed text by their first characters, built only when a difference is too long for `nearSync`
    /// (generated text, or source text that was not printed).
    private struct FarIndex {
        let paper: [UInt16]
        let k: Int
        private let keys: [(hash: UInt64, position: Int32)]

        init(_ paper: [UInt16], k: Int) throws {
            self.paper = paper
            self.k = k
            var keys: [(UInt64, Int32)] = []
            if paper.count >= k {
                keys.reserveCapacity(paper.count - k + 1)
                for p in 0...(paper.count - k) {
                    if p.isMultiple(of: 65536) { try Task.checkCancellation() }
                    keys.append((Self.hash(paper, p, k), Int32(p)))
                }
            }
            keys.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            self.keys = keys
        }

        static func hash(_ text: [UInt16], _ start: Int, _ k: Int) -> UInt64 {
            var value: UInt64 = 0xcbf2_9ce4_8422_2325
            for n in start..<(start + k) {
                value ^= UInt64(text[n])
                value &*= 0x100_0000_01b3
            }
            return value
        }

        /// The least total skip on both sides to a run that both share, looking a little way ahead in the DOM and
        /// far ahead in the pages.
        func sync(_ dom: [UInt16], _ i: Int, _ j: Int) -> (Int, Int)? {
            var best: (Int, Int)?
            for di in 0..<256 where i + di + k <= dom.count {
                if let best, di >= best.0 + best.1 { break }
                let key = Self.hash(dom, i + di, k)
                var low = 0
                var high = keys.count
                while low < high {
                    let mid = (low + high) / 2
                    if keys[mid].hash < key || keys[mid].hash == key && Int(keys[mid].position) < j {
                        low = mid + 1
                    } else {
                        high = mid
                    }
                }
                var n = low
                while n < keys.count, keys[n].hash == key {
                    let p = Int(keys[n].position)
                    if p - j > 65536 { break }
                    if (0..<k).allSatisfy({ dom[i + di + $0] == paper[p + $0] }) {
                        if best.map({ di + (p - j) < $0.0 + $0.1 }) != false { best = (di, p - j) }
                        break
                    }
                    n += 1
                }
            }
            return best
        }
    }

    /// The page of a DOM character, when it is placed.
    func page(of offset: Int) -> Int? {
        glyph(of: offset)?.page
    }

    /// The printed glyph of a DOM character: its page and its UTF-16 offset in the page's text.
    func glyph(of offset: Int) -> (page: Int, offset: Int)? {
        guard matches.indices.contains(offset), matches[offset] >= 0 else { return nil }
        let p = Int(matches[offset])
        return (Int(pages[p]), Int(offsets[p]))
    }

    /// The share of DOM characters that were placed, for diagnostics.
    var placedShare: Double {
        matches.isEmpty ? 1 : Double(matches.lazy.filter { $0 >= 0 }.count) / Double(matches.count)
    }
}
