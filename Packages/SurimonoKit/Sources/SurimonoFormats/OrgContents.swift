import Foundation

/// Expanding a one-line keyword can duplicate the document. Check the exact cost before allocating its HTML.
struct OrgContents {
    struct Table {
        let html: String
        let count: Int
        let bytes: Int
    }

    /// For each binary prefix, keep the greatest present level with that prefix. This sparse predecessor
    /// index takes at most one machine word's worth of steps per lookup, even across a huge gap in levels.
    private struct Levels {
        private var maxima: [UInt: Int] = [:]

        // The leading bit distinguishes a complete level from its shorter prefixes.
        private func leaf(_ level: Int) -> UInt { UInt(level) | (1 << (UInt.bitWidth - 1)) }

        mutating func insert(_ level: Int) {
            var prefix = leaf(level)
            while prefix > 0, (maxima[prefix] ?? 0) < level {
                maxima[prefix] = level
                prefix >>= 1
            }
        }

        func deepest(upTo limit: Int) -> Int? {
            var prefix = leaf(limit)
            if let exact = maxima[prefix] { return exact }
            // The nearest occupied left sibling on the path back to the root is the last lower interval.
            while prefix > 1 {
                if prefix & 1 == 1, let lower = maxima[prefix - 1] { return lower }
                prefix >>= 1
            }
            return nil
        }
    }

    /// In-order traversal gives document order. A shallower entry is always above a deeper one, so cutting
    /// off a branch visits no excluded descendants, even for many requests at different depths.
    private struct Scope {
        struct Node {
            let entry: Int
            var left: Int?
            var right: Int?
        }
        var nodes: [Node] = []
        var root: Int?
        var levels = Levels()
        var deepest = 0
        var costs: [Int: (count: Int, bytes: Int)] = [:]

        init(entries: [OrgOutline.Entry], after: Int?, base: Int) {
            var path: [Int] = []
            var byLevel: [Int: [Int]] = [:]
            for index in (after ?? 0)..<entries.count {
                let entry = entries[index]
                if after != nil && entry.level <= base { break }
                guard entry.listed else { continue }
                deepest = max(deepest, entry.level)
                levels.insert(entry.level)
                byLevel[entry.level, default: []].append(nodes.count)
                var left: Int?
                while let last = path.last, entries[nodes[last].entry].level > entry.level {
                    left = path.removeLast()
                }
                let next = nodes.count
                if let parent = path.last { nodes[parent].right = next } else { root = next }
                nodes.append(Node(entry: index, left: left))
                path.append(next)
            }
            guard let root else { return }
            let top = entries[nodes[root].entry].level
            // Removing the deepest rows leaves exactly the next shallower projection. Each removal changes
            // only the two neighbouring list transitions, so all depths are priced in a single pass.
            var previous = nodes.indices.map { $0 - 1 }
            var following = nodes.indices.map { $0 + 1 }
            func linkBytes(_ index: Int) -> Int {
                let entry = entries[nodes[index].entry]
                return "<li><a href=\"#\"></a></li>".utf8.count + entry.escapedID.utf8.count + entry.html.utf8.count
            }
            func listBytes(from left: Int, to right: Int) -> Int {
                guard right < nodes.count else { return 0 }
                let before = left >= 0 ? entries[nodes[left].entry].level : top - 1
                let rise = entries[nodes[right].entry].level - before
                guard rise > 0 else { return 0 }
                return rise * "<ul></ul>".utf8.count + (rise - 1) * "<li></li>".utf8.count
            }
            var bytes = nodes.indices.reduce(0) { $0 + linkBytes($1) + listBytes(from: $1 - 1, to: $1) }
            var count = nodes.count
            var level: Int? = deepest
            while let current = level {
                costs[current] = (count, bytes)
                for index in byLevel[current] ?? [] {
                    let left = previous[index]
                    let right = following[index]
                    bytes -= linkBytes(index) + listBytes(from: left, to: index) + listBytes(from: index, to: right)
                    bytes += listBytes(from: left, to: right)
                    if left >= 0 { following[left] = right }
                    if right < nodes.count { previous[right] = left }
                    count -= 1
                }
                level = levels.deepest(upTo: current - 1)
            }
        }
    }

    let entries: [OrgOutline.Entry]
    let headlineLevels: Int
    private static let opening = "<nav class=\"toc\" role=\"doc-toc\">"
    private static let closing = "</nav>\n"
    private let titledOpening: String
    private var scopes: [Int: Scope] = [:]
    private(set) var tables: [OrgOutline.Request: Table] = [:]
    private var remainingItems = OrgOutline.entryBudget
    private var remainingBytes = 8_000_000
    private(set) var omitted = false

    init(entries: [OrgOutline.Entry], headlineLevels: Int, title: String) {
        self.entries = entries
        self.headlineLevels = headlineLevels
        titledOpening = Self.opening + "<p class=\"toc-title\">\(HTML.escape(title))</p>"
    }

    mutating func table(_ request: OrgOutline.Request) -> String {
        let base = request.level ?? 0
        guard base < headlineLevels, request.depth ?? 1 > 0 else { return "" }
        let start = request.after ?? 0
        // A heading belongs to at most as many distinct local scopes as it has stars in the source.
        if scopes[start] == nil { scopes[start] = Scope(entries: entries, after: request.after, base: base) }
        guard let scope = scopes[start], let root = scope.root else { return "" }
        let ceiling = min(scope.deepest, headlineLevels)
        guard ceiling > base else { return "" }
        let cutoff = base + min(request.depth ?? (ceiling - base), ceiling - base)
        guard let limit = scope.levels.deepest(upTo: cutoff) else { return "" }
        var key = request
        key.depth = limit
        let opening = request.after == nil ? titledOpening : Self.opening
        guard let cost = scope.costs[limit], cost.count <= remainingItems,
            cost.bytes + opening.utf8.count + Self.closing.utf8.count <= remainingBytes
        else {
            omitted = true
            return ""
        }
        if let cached = tables[key] {
            remainingItems -= cached.count
            remainingBytes -= cached.bytes
            return cached.html
        }
        guard let table = build(scope, root: root, limit: limit, opening: opening) else {
            omitted = true
            return ""
        }
        tables[key] = table
        return table.html
    }

    private mutating func build(_ scope: Scope, root: Int, limit: Int, opening: String) -> Table? {
        let top = entries[scope.nodes[root].entry].level
        let initialItems = remainingItems
        let initialBytes = remainingBytes
        var html = ""
        func append(_ piece: String) -> Bool {
            let bytes = piece.utf8.count
            guard bytes <= remainingBytes else { return false }
            remainingBytes -= bytes
            html += piece
            return true
        }
        guard append(opening) else { return nil }
        var pending: [Int] = []
        var next: Int? = root
        var level = top - 1
        while next != nil || !pending.isEmpty {
            while let node = next, entries[scope.nodes[node].entry].level <= limit {
                pending.append(node)
                next = scope.nodes[node].left
            }
            guard let node = pending.popLast() else { break }
            let entry = entries[scope.nodes[node].entry]
            guard remainingItems > 0, entry.html.utf8.count <= remainingBytes,
                entry.escapedID.utf8.count <= remainingBytes - entry.html.utf8.count
            else { return nil }
            remainingItems -= 1
            while level > entry.level {
                guard append("</li></ul>") else { return nil }
                level -= 1
            }
            if level == entry.level {
                guard append("</li>") else { return nil }
            } else {
                guard append("<ul>") else { return nil }
                level += 1
                while level < entry.level {
                    guard append("<li><ul>") else { return nil }
                    level += 1
                }
            }
            guard append("<li><a href=\"#"), append(entry.escapedID), append("\">"),
                append(entry.html), append("</a>")
            else { return nil }
            next = scope.nodes[node].right
        }
        while level >= top {
            guard append("</li></ul>") else { return nil }
            level -= 1
        }
        guard append(Self.closing) else { return nil }
        return Table(html: html, count: initialItems - remainingItems, bytes: initialBytes - remainingBytes)
    }
}
