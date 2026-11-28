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

    @Test("ページの残りに入らない短い exam の解答は、枠を途中で切らずに次のページへ送る", .timeLimit(.minutes(1)))
    func shortSolutionMovesWhole() async throws {
        var split: [String] = []
        var pages: Set<Int> = []
        // Each filler line moves the frame down by one line, so some count puts it across the page edge.
        for count in stride(from: 36, through: 50, by: 2) {
            let filler = (1...count).map { "Filler line \($0) keeps the frame low.\\par " }.joined()
            let tex = #"""
                \documentclass[a4paper,11pt]{exam}
                \printanswers
                \begin{document}
                """# + filler + #"""
                    \begin{questions}
                    \question Explain the bench record.
                    \begin{solution}
                    Opening mark. \#(Array(repeating: "The workshop records an unmatched label separately.", count: 8).joined(separator: " ")) Closing mark.
                    \end{solution}
                    \end{questions}
                    \end{document}
                    """#
            let document = try await printed(tex)
            let found = ["Solution:", "Closing mark"].map { word in
                document.findString(word, withOptions: []).first?.pages.first.map { document.index(for: $0) }
            }
            if let page = found[0] { pages.insert(page) }
            if found[0] == nil || found[0] != found[1] { split.append("\(count) lines: \(found)") }
        }
        #expect(pages.count > 1, "some filler count must push the solution to the next page")
        #expect(split == [])
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
