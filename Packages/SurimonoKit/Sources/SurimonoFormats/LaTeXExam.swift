import Foundation

/// Totals belong to the document so a grading table can precede the questions it grades.
struct LaTeXExam {
    enum List: String {
        case questions, parts, subparts, choices, oneparchoices, checkboxes
        var command: String {
            switch self {
            case .questions: "question"
            case .parts: "part"
            case .subparts: "subpart"
            default: "choice"
            }
        }

        var declarations: [String] {
            switch self {
            case .questions: ["question", "subpart"]
            case .parts: ["part"]
            case .subparts: []
            case .choices, .oneparchoices, .checkboxes: ["choice", "CorrectChoice", "correctchoice"]
            }
        }

        func label(_ index: Int, correct: Bool) -> String {
            switch self {
            case .questions: "\(index)."
            case .parts: "(\(LaTeXSymbols.format(index, as: "alph")))"
            case .subparts: "\(LaTeXSymbols.format(index, as: "roman"))."
            case .checkboxes: correct ? "☑" : "☐"
            default: "\(LaTeXSymbols.format(index, as: "Alph"))."
            }
        }
    }

    struct Table: Hashable {
        let horizontal: Bool
        let pages: Bool
        let grade: Bool
    }

    var linePitch = LaTeXSymbols.printLength("0.25in") ?? "1.5em"
    var dottedPitch = LaTeXSymbols.printLength("0.25in") ?? "1.5em"
    var lineThickness = LaTeXSymbols.printLength("0.1pt") ?? "0.1pt"
    var listCommands: Set<String> = []
    var questions: [Double] = []
    var tables: [Table] = []
    var total = 0.0

    static func points(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let half = value.hasSuffix(#"\half"#)
        let whole = half ? String(value.dropLast(5)).trimmingCharacters(in: .whitespaces) : value
        guard let number = whole.isEmpty && half ? 0 : Double(whole), number.isFinite,
            number >= 0, number <= 1_000_000_000
        else { return nil }
        return number + (half ? 0.5 : 0)
    }

    static func number(_ value: Double) -> String { NSDecimalNumber(value: value).stringValue }

    func tableHTML(_ index: Int) -> String {
        guard tables.indices.contains(index) else { return "" }
        let table = tables[index]
        let axis = table.pages ? "Page" : "Question"
        var rows: [[String]] = []
        let entries =
            table.pages
            ? [("?", Self.number(total))]
            : questions.enumerated().map {
                (String($0.offset + 1), Self.number($0.element))
            }
        if table.horizontal {
            rows = [[axis + ":"] + entries.map(\.0) + ["Total"], ["Points:"] + entries.map(\.1) + [Self.number(total)]]
            if table.grade { rows.append(["Score:"] + Array(repeating: "", count: entries.count + 1)) }
        } else {
            rows = [[axis, "Points"]]
            rows += entries.map { [$0.0, $0.1] }
            rows.append(["Total:", Self.number(total)])
            if table.grade {
                for i in rows.indices { rows[i].append(i == 0 ? "Score" : "") }
            }
        }
        let marker =
            table.pages
            ? " data-exam-pages=\"\(table.horizontal ? "h" : "v")\" data-exam-grade=\"\(table.grade)\"" : ""
        let body = rows.map { row in "<tr>" + row.map { "<td>\($0)</td>" }.joined() + "</tr>" }.joined()
        return "<table class=\"latex-exam-table\"\(marker)><tbody>\(body)</tbody></table>\n"
    }
}

extension LaTeXReader {
    func handleExamEnvironment(_ name: String, body: String) -> Bool {
        guard document.classInfo.profile.body.readsQuestions else { return false }
        if let list = LaTeXExam.List(rawValue: name) {
            let child = LaTeXReader(body, document: document, isBlock: true)
            child.examList = list
            // exam.cls defines the item commands on entry, shadowing any preamble fallback until the list ends.
            let active = document.exam.listCommands
            let saved = list.declarations.map { ($0, document.macros.removeValue(forKey: $0)) }
            document.exam.listCommands.formUnion(list.declarations)
            defer {
                document.exam.listCommands = active
                for (name, definition) in saved { document.macros[name] = definition }
            }
            let contents = child.read()
            let close = child.examItemIndex == 0 ? "" : "</li>"
            appendBlock("<ol class=\"latex-exam-list latex-exam-\(name)\">\(contents)\(close)</ol>\n")
        } else if ["solution", "solutionorbox", "solutionorlines", "solutionordottedlines"].contains(name) {
            let child = LaTeXReader(body, document: document, isBlock: true)
            let space = child.optional()
            if document.booleans["printanswers"] == true {
                appendBlock("<div class=\"latex-exam-solution\"><strong>Solution:</strong> \(child.read())</div>\n")
            } else if let space {
                examSpace(space, kind: name)
            }
        } else {
            return false
        }
        return true
    }

    func handleExamCommand(_ name: String) -> Bool {
        guard document.classInfo.profile.body.readsQuestions else { return false }
        if let list = examList, list.command == name || list.command == "choice" && name.lowercased() == "correctchoice"
        {
            examItem(list, correct: name.lowercased() == "correctchoice" && document.booleans["printanswers"] == true)
            return true
        }
        switch name {
        case "addpoints": break
        case "printanswers", "noprintanswers": document.booleans["printanswers"] = name == "printanswers"
        case "numquestions", "numpoints":
            appendHTML(document.placeholder("E", name == "numquestions" ? 0 : 1))
        case "gradetable", "pointtable":
            let horizontal = optional() == "h"
            let pages = optional() == "pages"
            let request = LaTeXExam.Table(horizontal: horizontal, pages: pages, grade: name == "gradetable")
            let index: Int
            if let previous = document.exam.tables.firstIndex(of: request) {
                index = previous
            } else {
                index = document.exam.tables.count
                document.exam.tables.append(request)
            }
            appendBlock(document.placeholder("E", index + 2))
        case "fillin":
            let answer = optional() ?? ""
            let width = LaTeXSymbols.printLength(optional() ?? "1in") ?? "1em"
            let contents = document.booleans["printanswers"] == true ? inline(answer) : ""
            appendHTML("<span class=\"latex-exam-fillin\" style=\"min-width: \(width)\">\(contents)</span>")
        case "makeemptybox", "fillwithlines", "fillwithdottedlines": examSpace(argument() ?? "", kind: name)
        case "lhead", "chead", "rhead", "lfoot", "cfoot", "rfoot":
            let first = optional()
            let running = argument() ?? ""
            let field = String(name.prefix(1)).uppercased() + (name.hasSuffix("head") ? "H" : "F")
            pageAction("exam:first:\(field)", first ?? running)
            pageAction("exam:running:\(field)", running)
        case "header", "footer", "firstpageheader", "firstpagefooter", "runningheader", "runningfooter":
            let row = name.hasSuffix("header") ? "H" : "F"
            for column in ["L", "C", "R"] {
                let source = argument() ?? ""
                if !name.hasPrefix("running") { pageAction("exam:first:\(column)\(row)", source) }
                if !name.hasPrefix("firstpage") { pageAction("exam:running:\(column)\(row)", source) }
            }
        default: return false
        }
        return true
    }

    private func examItem(_ list: LaTeXExam.List, correct: Bool) {
        let previous = examItemIndex == 0 ? "" : "</li>"
        examItemIndex += 1
        let choice = list.command == "choice"
        let raw = choice ? nil : optional()
        if list == .questions { document.exam.questions.append(0) }
        let points = raw.flatMap(LaTeXExam.points)
        if let points, !document.exam.questions.isEmpty {
            let last = document.exam.questions.count - 1
            document.exam.questions[last] += points
            document.exam.total += points
        }
        let style = correct ? " class=\"latex-exam-correct\"" : ""
        appendBlock("\(previous)<li\(style)>", continuesParagraph: true)
        let credit = choice ? "" : " data-exam-credit=\"\(LaTeXExam.number(points ?? 0))\""
        let label = list.label(list == .questions ? document.exam.questions.count : examItemIndex, correct: correct)
        appendHTML("<span class=\"latex-exam-marker\"\(credit)>\(label)</span> ")
        if let raw {
            let amount = points.map(LaTeXExam.number) ?? inline(raw)
            appendHTML("(\(amount) \(points == 1 ? "point" : "points")) ")
        }
    }

    private func examSpace(_ raw: String, kind: String) {
        guard let height = LaTeXSymbols.printLength(raw) else {
            document.recordUnknown(kind)
            appendHTML(inline(raw))
            return
        }
        let pattern: String
        switch kind {
        case "fillwithlines", "solutionorlines": pattern = "lines"
        case "fillwithdottedlines", "solutionordottedlines": pattern = "dots"
        case "makeemptybox", "solutionorbox": pattern = "box"
        default: pattern = "blank"
        }
        var rules = ""
        if pattern == "lines" || pattern == "dots" {
            let dotted = pattern == "dots"
            let pitch = dotted ? document.exam.dottedPitch : document.exam.linePitch
            let stroke =
                dotted
                ? "stroke-width: 0.1em; stroke-linecap: round; stroke-dasharray: 0 0.45em"
                : "stroke-width: " + document.exam.lineThickness
            // A foreground SVG stroke survives WebKit printing with background graphics disabled.
            rules =
                "<svg data-exam-rules aria-hidden=\"true\" width=\"100%\" height=\"100%\" preserveAspectRatio=\"none\" style=\"display: block\">"
                + "<g style=\"stroke: currentColor; \(stroke)\"><path style=\"font-size: \(pitch)\" fill=\"none\" vector-effect=\"non-scaling-stroke\"></path></g></svg>"
        }
        appendBlock(
            "<div class=\"latex-exam-space latex-exam-\(pattern)\" style=\"height: \(height)\">\(rules)</div>\n")
    }
}
