import Foundation

/// Filter only headlines recognized at the document root. A star in an example or quote never starts a subtree.
struct OrgSubtrees {
    struct Heading {
        let line: Int
        let level: Int
    }
    var headings: [Heading] = []
    var select: Set<String>?
    var exclude: Set<String>?
    var fileTags: Set<String> = []

    static let tagPattern = #"^(?:(.*?)\s+)?(:[^\s:]+(?::[^\s:]+)*:)\s*$"#

    /// End-exclusive ranges, paired with the first omitted line. Ancestors of selected trees keep their own text.
    func omissions(context: OrgContext, lines: [String]) -> [Int: Int] {
        let reading = context.reading
        let select = select ?? ["export"]
        let exclude = exclude ?? ["noexport"]
        let selectFile = !fileTags.isDisjoint(with: select)
        let excludeFile = !fileTags.isDisjoint(with: exclude)
        guard !headings.isEmpty,
            !select.isEmpty || !exclude.isEmpty || reading.tasks != .all || reading.archived != .all
        else { return [:] }
        let taskNames: Set<String>
        if case .keywords(let names) = reading.tasks { taskNames = Set(names) } else { taskNames = [] }
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
                || excludeFile || !tags.isDisjoint(with: exclude) || (archive && reading.archived == .off)
                || !includesTask(keyword, context: context, names: taskNames)
            blocked.append(omit)
            headingOnly.append(archive && reading.archived == .headline)
            let selected = selectFile || !tags.isDisjoint(with: select)
            anySelection = anySelection || selected
            included.append(selected || parent.map { included[$0] } == true)
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

    private func includesTask(_ keyword: String, context: OrgContext, names: Set<String>) -> Bool {
        let done = context.taskKeywords.done.contains(keyword)
        guard done || context.taskKeywords.active.contains(keyword) else { return true }
        switch context.reading.tasks {
        case .all: return true
        case .off: return false
        case .todo: return !done
        case .done: return done
        case .keywords: return names.contains(keyword)
        }
    }
}

/// Only outline boundaries and workflow declarations are needed to recognize COMMENT, before collecting metadata.
struct OrgCommentOutline {
    private enum Event {
        case heading(line: Int, level: Int, requiredKeyword: String?)
        case workflow(String)
    }
    private var events: [Event] = []
    private var sourceKeywords = OrgTaskKeywords()

    mutating func workflow(_ declaration: String) {
        events.append(.workflow(declaration))
        sourceKeywords.declare(declaration)
    }

    mutating func heading(line: Int, level: Int, title: String) {
        var required: String?
        let words = title.split(maxSplits: 3, whereSeparator: \.isWhitespace)
        switch words.prefix(3).firstIndex(of: "COMMENT") {
        case 0: required = ""
        case 1: required = Self.isPriority(words[0]) ? "" : String(words[0])
        case 2 where Self.isPriority(words[1]): required = String(words[0])
        default: break
        }
        events.append(.heading(line: line, level: level, requiredKeyword: required))
    }

    private static func isPriority(_ word: Substring) -> Bool {
        word.first == "[" && orgCaptures(#"^\[#[A-Za-z0-9]\]$"#, String(word)) != nil
    }

    func ranges(end: Int) -> [Int: Int] {
        // A declaration later in the buffer can decide whether a word preceding COMMENT is a keyword.
        // If a declaration itself disappears, also recognize comments in the surviving export vocabulary.
        func scan(_ keywords: OrgTaskKeywords) -> (ranges: [Int: Int], vocabulary: OrgTaskKeywords) {
            var vocabulary = OrgTaskKeywords()
            var ranges: [Int: Int] = [:]
            var comment: (line: Int, level: Int)?
            for event in events {
                switch event {
                case .heading(let line, let level, let required):
                    if let open = comment {
                        if level > open.level { continue }
                        ranges[open.line] = line
                        comment = nil
                    }
                    if let required, required.isEmpty || keywords.contains(required) { comment = (line, level) }
                case .workflow(let value):
                    if comment == nil { vocabulary.declare(value) }
                }
            }
            if let comment { ranges[comment.line] = end }
            return (ranges, vocabulary)
        }
        let visible = scan(sourceKeywords)
        guard visible.vocabulary != sourceKeywords else { return visible.ranges }
        return visible.ranges.merging(scan(visible.vocabulary).ranges, uniquingKeysWith: max)
    }
}
