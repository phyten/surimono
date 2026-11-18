import Foundation

/// Original source lines are one-based, including front matter and definitions moved to the end.
public struct MarkdownBlock: Equatable, Sendable {
    public let id: String
    public let lines: Set<Int>
}

public struct MarkdownMappedDocument: Sendable {
    public let fragment: HTMLFragment
    public let blocks: [MarkdownBlock]
}

/// A short mark denotes a deletion at the nearest surviving block.
public struct MarkdownMarkRequest: Equatable, Sendable {
    public let blockID: String
    public let isShort: Bool

    public init(blockID: String, isShort: Bool = false) {
        self.blockID = blockID
        self.isShort = isShort
    }
}

public enum MarkdownChanges {
    public struct Lines: Equatable, Sendable {
        public let inserted: Set<Int>
        public let deletions: Set<Int>
    }

    /// Bounded LCS. The table cap bounds both memory and work, including adversarial repeated lines.
    /// Deletion positions are one-based positions in the new source (count + 1 means its end).
    public static func lines(from old: String, to new: String, cellLimit: Int = 1_000_000) -> Lines? {
        guard old.utf8.count <= 2_000_000, new.utf8.count <= 2_000_000 else { return nil }
        let a = TextDecoding.normalizeNewlines(old).components(separatedBy: "\n")
        let b = TextDecoding.normalizeNewlines(new).components(separatedBy: "\n")
        guard cellLimit > 0, a.count + 1 <= cellLimit / (b.count + 1) else { return nil }
        var symbols: [String: Int] = [:]
        func symbol(_ line: String) -> Int {
            if let existing = symbols[line] { return existing }
            let id = symbols.count
            symbols[line] = id
            return id
        }
        let oldLines = a.map(symbol)
        let newLines = b.map(symbol)
        let width = b.count + 1
        var lengths = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                lengths[i * width + j] =
                    oldLines[i] == newLines[j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var i = 0
        var j = 0
        var inserted = Set<Int>()
        var deletions = Set<Int>()
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, oldLines[i] == newLines[j] {
                i += 1
                j += 1
            } else if j < b.count && (i == a.count || lengths[i * width + j + 1] >= lengths[(i + 1) * width + j]) {
                inserted.insert(j + 1)
                j += 1
            } else {
                deletions.insert(j + 1)
                i += 1
            }
        }
        return Lines(inserted: inserted, deletions: deletions)
    }

    public static func marks(from old: String, to new: String, cellLimit: Int = 1_000_000) -> [MarkdownMarkRequest] {
        guard let changes = lines(from: old, to: new, cellLimit: cellLimit) else { return [] }
        let blocks = MarkdownConverter.convertWithSourceMap(new).blocks
        var selected: [String: Bool] = [:]
        func innermost(at line: Int) -> MarkdownBlock? {
            blocks.filter { $0.lines.contains(line) }.min { $0.lines.count < $1.lines.count }
        }
        for line in changes.inserted {
            if let block = innermost(at: line) { selected[block.id] = false }
        }
        for line in changes.deletions {
            // Replacement hunks already have a full mark; they are not deletion-only changes.
            if changes.inserted.contains(line) || changes.inserted.contains(line - 1) { continue }
            let next = blocks.compactMap { block -> (MarkdownBlock, Int)? in
                guard let start = block.lines.filter({ $0 >= line }).min() else { return nil }
                return (block, start)
            }.min { $0.1 == $1.1 ? $0.0.lines.count < $1.0.lines.count : $0.1 < $1.1 }
            let previous = blocks.max {
                let left = $0.lines.max() ?? 0
                let right = $1.lines.max() ?? 0
                return left == right ? $0.lines.count > $1.lines.count : left < right
            }
            if let block = innermost(at: line) ?? next?.0 ?? previous, selected[block.id] == nil {
                selected[block.id] = true
            }
        }
        // If a marker line changed along with its body, use the inner units only, not overlapping parent bars.
        let chosen = blocks.filter { selected[$0.id] != nil }
        return chosen.filter { parent in
            !chosen.contains { child in
                child.id != parent.id && child.lines.count < parent.lines.count
                    && child.lines.isSubset(of: parent.lines)
            }
        }.map { MarkdownMarkRequest(blockID: $0.id, isShort: selected[$0.id] ?? false) }
    }
}

/// Each generated parser line carries the exact original lines it represents; never reconstruct this by diffing HTML.
struct MarkdownSourceLines {
    var lines: [String]
    var origins: [Set<Int>]

    init(_ lines: [String], origins: [Set<Int>]? = nil) {
        self.lines = lines
        self.origins = origins ?? lines.indices.map { [$0 + 1] }
    }

    init() { self.init([]) }

    static func unmapped(_ lines: [String]) -> Self {
        Self(lines, origins: Array(repeating: [], count: lines.count))
    }

    mutating func append(_ text: String, from lines: Set<Int>) {
        let pieces = text.components(separatedBy: "\n")
        self.lines += pieces
        origins += Array(repeating: lines, count: pieces.count)
    }
}
