import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXExamPrintingTests {
    @Test("exam の小問の番号は (b) も本文と同じ行に置き、採点表の語を途中で折らない", .timeLimit(.minutes(1)))
    func partLabelsAndGradeTable() async throws {
        let questions = (1...12).map { index in
            #"\question[10] Question \#(index) about the folded strip."#
                + #"\begin{parts}\part Alpha step \#(index).\part Bravo step \#(index).\part Charlie step \#(index).\end{parts}"#
        }.joined(separator: "\n")
        let tex = #"""
            \documentclass[a4paper,11pt]{exam}
            \begin{document}
            \gradetable[h][questions]
            \begin{questions}
            """# + questions + #"""
                \end{questions}
                \end{document}
                """#
        let document = try await printed(tex)
        let rows = (0..<document.pageCount).compactMap(document.page(at:)).flatMap(lines(on:))
        for index in 1...12 {
            #expect(rows.contains { $0.hasPrefix("(b)") && $0.contains("Bravo step \(index)") }, "part (b) of \(index)")
        }
        for word in ["Question:", "Points:", "Score:", "Total"] {
            #expect(rows.contains { $0.hasPrefix(word) }, "\(word) must stay whole")
        }
    }

    /// The plain document uses WebKit's pagination. A footnote or two columns send it through the LaTeX flow.
    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case plain, footnote, twoColumns
        var testDescription: String { rawValue }
        var options: String { self == .twoColumns ? "a4paper,11pt,twocolumn" : "a4paper,11pt" }
        var note: String { self == .footnote ? #"\footnote{Bench note.}"# : "" }
    }

    @Test(
        "ページや段の残りに入らない短い exam の解答は、連続していてもそれぞれ枠を途中で切らずに送る",
        .timeLimit(.minutes(1)), arguments: Route.allCases)
    func shortSolutionsMoveWhole(route: Route) async throws {
        var split: [String] = []
        var places: Set<String> = []
        let sentence = "The workshop records an unmatched label separately."
        // Each filler line moves the frames down by one line, so some count puts each across an edge.
        for count in stride(from: 34, through: 52, by: 3) {
            let filler = (1...count).map { "Filler line \($0) keeps the frame low.\\par " }.joined()
            // Marks such as QA1 are not hyphenated, so each stays findable as one word.
            let solutions = ["A", "B"].map { name in
                #"\begin{solution}"# + "Q\(name)1. " + Array(repeating: sentence, count: 6).joined(separator: " ")
                    + " Q\(name)2." + #"\end{solution}"#
            }.joined(separator: "\n")
            let tex = #"""
                \documentclass[\#(route.options)]{exam}
                \printanswers
                \begin{document}
                Bench text\#(route.note).
                """# + filler + #"""
                    \begin{questions}
                    \question Explain the bench record.
                    """# + solutions + #"""
                    \end{questions}
                    \end{document}
                    """#
            let document = try await printed(tex)
            for name in ["A", "B"] {
                let found = try ["Q\(name)1", "Q\(name)2"].map {
                    try place(of: $0, in: document, columns: route == .twoColumns)
                }
                places.insert(found[0])
                if found[0] != found[1] { split.append("\(count) lines: \(name) \(found)") }
            }
        }
        #expect(places.count > 1, "some filler count must move a solution")
        #expect(split == [])
    }

    @Test(
        "1 段より長い exam の解答は縮めずに行の境目で分けて続ける", .timeLimit(.minutes(1)),
        arguments: Route.allCases)
    func longSolutionSplits(route: Route) async throws {
        let marks = (1...70).map { String(format: "Q%03d", $0) }
        let text = marks.map { "\($0) The workshop records an unmatched label separately." }.joined(separator: " ")
        let tex = #"""
            \documentclass[\#(route.options)]{exam}
            \printanswers
            \begin{document}
            Bench text\#(route.note).
            \begin{questions}
            \question Explain the bench record.
            \begin{solution}
            \#(text)
            \end{solution}
            \end{questions}
            \end{document}
            """#
        let document = try await printed(tex)
        let printed = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        #expect(printed.matches(of: /Q\d{3}/).map { String($0.output) } == marks)
        let first = try #require(document.findString("Q001", withOptions: []).first)
        let last = try #require(document.findString("Q070", withOptions: []).first)
        let firstPage = try #require(first.pages.first)
        let lastPage = try #require(last.pages.first)
        #expect(document.index(for: lastPage) > document.index(for: firstPage))
        // A whole-box shrink would reduce the type; split lines keep their natural height.
        #expect(abs(first.bounds(for: firstPage).height - last.bounds(for: lastPage).height) < 0.5)
    }

    /// The page and, on a two-column page, the column that hold a word.
    private func place(of word: String, in document: PDFDocument, columns: Bool) throws -> String {
        let selection = try #require(document.findString(word, withOptions: []).first, "\(word)")
        let page = try #require(selection.pages.first)
        let column = !columns ? "" : selection.bounds(for: page).midX < page.bounds(for: .mediaBox).midX ? "L" : "R"
        return "\(document.index(for: page))\(column)"
    }

    private func lines(on page: PDFPage) -> [String] {
        (page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []).compactMap { line in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private func printed(_ tex: String) async throws -> PDFDocument {
        let info = LaTeXConverter.documentClassInfo(tex)
        let theme = try #require(
            PrintThemeLibrary.load().first { $0.id == PrintThemeLibrary.defaultLaTeXStyle(for: info) })
        var settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""),
            options: PrintOptions().defaults(for: .latex))
        settings.applyLaTeXPage(info)
        return try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
    }
}
