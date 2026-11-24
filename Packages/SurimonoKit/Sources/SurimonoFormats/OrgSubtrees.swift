import Foundation

/// Filter only headlines recognized at the document root. A star in an example or quote never starts a subtree.
struct OrgSubtrees {
    struct Heading {
        let line: Int
        let level: Int
    }
    var headings: [Heading] = []
    var select: Set<String> = []
    var exclude: Set<String> = []

    static let tagPattern = #"^(?:(.*?)\s+)?(:[^\s:]+(?::[^\s:]+)*:)\s*$"#

    /// End-exclusive ranges, paired with the first omitted line. Ancestors of selected trees keep their own text.
    func omissions(context: OrgContext, lines: [String]) -> [Int: Int] {
        let reading = context.reading
        guard !headings.isEmpty,
            !select.isEmpty || !exclude.isEmpty || reading.tasks != .all || reading.archived != .all
        else { return [:] }
        var parents = [Int?]()
        var path = [Int]()
        var included = [Bool]()
        var blocked = [Bool]()
        var headingOnly = [Bool]()
        var anySelection = false
        for (index, heading) in headings.enumerated() {
            while let last = path.last, headings[last].level >= heading.level { path.removeLast() }
            let parent = path.last
            parents.append(parent)
            let source = lines[heading.line].dropFirst(heading.level).drop(while: \.isWhitespace)
            let tail = orgCaptures(Self.tagPattern, String(source))?[1] ?? ""
            let tags = Set(tail.split(separator: ":").map(String.init))
            let keyword = String(source.prefix { !$0.isWhitespace })
            let archive = tags.contains("ARCHIVE")
            let omit =
                parent.map { blocked[$0] || headingOnly[$0] } == true
                || !tags.isDisjoint(with: exclude) || (archive && reading.archived == .off)
                || !includesTask(keyword, context: context)
            blocked.append(omit)
            headingOnly.append(archive && reading.archived == .headline)
            let selected = !tags.isDisjoint(with: select)
            anySelection = anySelection || selected
            included.append(!omit && (selected || parent.map { included[$0] } == true))
            path.append(index)
        }
        if anySelection {
            for index in headings.indices.reversed() where included[index] {
                if let parent = parents[index] { included[parent] = true }
            }
        }
        var result: [Int: Int] = [:]
        if anySelection, headings[0].line > 0 { result[0] = headings[0].line }
        for index in headings.indices {
            let end = index + 1 < headings.count ? headings[index + 1].line : lines.count
            let start = headings[index].line
            if blocked[index] || (anySelection && !included[index]) {
                result[start] = end
            } else if headingOnly[index], start + 1 < end {
                result[start + 1] = end
            }
        }
        return result
    }

    private func includesTask(_ keyword: String, context: OrgContext) -> Bool {
        let done = context.done.contains(keyword)
        guard done || context.active.contains(keyword) else { return true }
        switch context.reading.tasks {
        case .all: return true
        case .off: return false
        case .todo: return !done
        case .done: return done
        case .keywords(let keys): return keys.contains(keyword)
        }
    }
}
