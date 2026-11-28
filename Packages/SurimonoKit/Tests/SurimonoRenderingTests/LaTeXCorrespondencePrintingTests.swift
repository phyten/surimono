import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXCorrespondencePrintingTests {
    @Test("複数ページの手紙は、境目の行を両方のページに切って刷らず、段落の途中に空きを作らない", .timeLimit(.minutes(1)))
    func letterPages() async throws {
        let body = (1...9).map { "\\textbf{Stage \($0)}\n\n\(paragraph($0))\n\n" }.joined()
        let tex = #"""
            \documentclass[11pt,a4paper]{letter}
            \address{Model workshop\\East bench}\signature{Rail fixture desk}\date{14 May 2026}
            \begin{document}
            \begin{letter}{Stores desk\\Paper Model Workshop}
            \opening{Dear stores team,}
            """# + body + #"""
                \closing{With thanks,}
                \end{letter}
                \end{document}
                """#
        let document = try await printed(tex)
        #expect(document.pageCount >= 3)
        #expect(repeatedBoundaryLines(document) == [])
        #expect(widenedLineGaps(document, paragraphs: 1...9) == [])
        #expect(sentenceMarks(in: document) == (1...9).flatMap(marks))
    }

    @Test("複数ページの履歴書は、境目の行を両方のページに切って刷らず、項目の途中に空きを作らない", .timeLimit(.minutes(1)))
    func curriculumVitaePages() async throws {
        let rows = (1...9).map { index in
            let section = index % 3 == 1 ? "\\section{Stage \(index)}\n" : ""
            return section + "\\cvitem{Method \(index)}{\(paragraph(index))}\n"
                + "\\cvdoubleitem{Input}{Card stock \(index)}{Output}{Folded strip \(index)}\n"
        }.joined()
        let tex = #"""
            \documentclass[11pt,a4paper]{moderncv}
            \moderncvstyle{classic}\moderncvcolor{blue}\name{Model}{Workshop}\title{Fictional project profile}
            \begin{document}
            \makecvtitle
            """# + rows + #"""
                \end{document}
                """#
        let document = try await printed(tex)
        #expect(document.pageCount >= 3)
        #expect(repeatedBoundaryLines(document) == [])
        #expect(widenedLineGaps(document, paragraphs: 1...9) == [])
        #expect(sentenceMarks(in: document) == (1...9).flatMap(marks))
    }

    @Test("ページの残りに入らない短い履歴書の項目は、ラベルと本文をそろえて次のページへ送る", .timeLimit(.minutes(1)))
    func shortEntryMovesWhole() async throws {
        var pages: Set<Int> = []
        var split: [String] = []
        // Each filler row moves the entry by one line, so some count puts it across the page edge.
        for count in 28...44 {
            let filler = (0..<count).map { "\\cvitem{Row \($0)}{One short filler line.}\n" }.joined()
            let tex = #"""
                \documentclass[11pt,a4paper]{moderncv}
                \moderncvstyle{classic}\name{Model}{Workshop}
                \begin{document}
                """# + filler + #"""
                    \cvitem{Pivot}{\#(paragraph(1, sentences: 2))}
                    \cvitemwithcomment{Hinge}{\#(paragraph(2, sentences: 2))}{Bench note}
                    \end{document}
                    """#
            let document = try await printed(tex)
            for (label, number) in [("Pivot", 1), ("Hinge", 2)] {
                let found = [label, "Ka\(number)", "Zu\(number)"].map { word in
                    document.findString(word, withOptions: .caseInsensitive).first?.pages.first
                        .map { document.index(for: $0) }
                }
                if let page = found[0] { pages.insert(page) }
                if Set(found).count != 1 || found[0] == nil { split.append("\(count) rows: \(label) \(found)") }
            }
            let printed = sentenceMarks(in: document)
            if printed != marks(1, sentences: 2) + marks(2, sentences: 2) { split.append("\(count) rows: \(printed)") }
        }
        #expect(pages.count > 1)
        #expect(split == [])
    }

    @Test("1 ページを超える 1 つの履歴書の項目は、行を切らずに次のページへ続け、本文を欠かさない", .timeLimit(.minutes(1)))
    func entryTallerThanPage() async throws {
        let tex = #"""
            \documentclass[11pt,a4paper]{moderncv}
            \moderncvstyle{classic}\name{Model}{Workshop}
            \begin{document}
            \cvitem{Scope}{One short line.}
            \cvitem{Method}{\#(paragraph(1, sentences: 60))}
            \end{document}
            """#
        let document = try await printed(tex)
        #expect(document.pageCount >= 2)
        #expect(repeatedBoundaryLines(document) == [])
        #expect(widenedLineGaps(document, paragraphs: 1...1) == [])
        #expect(sentenceMarks(in: document) == marks(1, sentences: 60))
    }

    /// A long synthetic paragraph opened by `Ka<n>` and closed by `Zu<n>` so its lines can be found again.
    /// Each sentence starts with a mark such as `Q0103` so lost or repeated text shows up.
    private func paragraph(_ index: Int, sentences count: Int? = nil) -> String {
        let sentences = [
            "The folded strip keeps the rail level at the second mark while the glue sets overnight.",
            "Every revision of the packet travels with its local resources and a short description of its purpose.",
            "A reviewer compares the reading edition with the sheet edition before the stock is ordered.",
            "Interchangeable denominators would conceal the difference between readings and complete inspection rounds.",
            "The workshop records an unmatched label separately instead of converting the missing value to zero.",
        ]
        let text = zip(marks(index, sentences: count), 0...).map { mark, number in
            mark + " " + sentences[(number + index) % sentences.count]
        }
        return "Ka\(index) " + text.joined(separator: " ") + " Zu\(index)"
    }

    private func marks(_ index: Int) -> [String] { marks(index, sentences: nil) }

    private func marks(_ index: Int, sentences count: Int?) -> [String] {
        // Uneven paragraphs put the page edges at different places in each one.
        (1...(count ?? 5 + index * 2)).map { String(format: "Q%02d%02d", index, $0) }
    }

    /// Sentence marks in reading order across all pages.
    private func sentenceMarks(in document: PDFDocument) -> [String] {
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        return text.matches(of: /Q\d{4}/).map { String($0.output) }
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

    private func lines(on page: PDFPage) -> [(text: String, bounds: CGRect)] {
        (page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []).compactMap { line in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (text, line.bounds(for: page))
        }
    }

    /// Text drawn both as the last row of a page and as the first row of the next one:
    /// a line cut horizontally at the page edge.
    private func repeatedBoundaryLines(_ document: PDFDocument) -> [String] {
        var repeated: [String] = []
        for index in 0..<max(0, document.pageCount - 1) {
            guard let page = document.page(at: index), let next = document.page(at: index + 1) else { continue }
            let bottom = lines(on: page)
            let top = lines(on: next)
            guard let lowest = bottom.map(\.bounds.minY).min(), let highest = top.map(\.bounds.maxY).max() else {
                continue
            }
            let last = Set(bottom.filter { $0.bounds.minY < lowest + 2 }.map(\.text))
            let first = Set(top.filter { $0.bounds.maxY > highest - 2 }.map(\.text))
            repeated += last.intersection(first).map { "page \(index + 1)→\(index + 2): \($0)" }
        }
        return repeated
    }

    /// Gaps inside one paragraph that exceed 1.8 times its smallest line advance.
    private func widenedLineGaps(_ document: PDFDocument, paragraphs: ClosedRange<Int>) -> [String] {
        var widened: [String] = []
        for number in paragraphs {
            guard let start = document.findString("Ka\(number)", withOptions: .caseInsensitive).first,
                let end = document.findString("Zu\(number)", withOptions: .caseInsensitive).first,
                let startPage = start.pages.first, let endPage = end.pages.first
            else {
                widened.append("paragraph \(number) not found")
                continue
            }
            let first = document.index(for: startPage)
            let last = document.index(for: endPage)
            var gaps: [(gap: CGFloat, page: Int)] = []
            for index in first...last {
                guard let page = document.page(at: index) else { continue }
                let top = index == first ? start.bounds(for: page).midY : .infinity
                let bottom = index == last ? end.bounds(for: page).midY : -.infinity
                // A floated label and the body beside it share one row.
                let rows = lines(on: page).map(\.bounds).filter { $0.midY <= top + 1 && $0.midY >= bottom - 1 }
                    .map(\.minY).sorted(by: >)
                let baselines = rows.reduce(into: [CGFloat]()) { kept, row in
                    if let previous = kept.last, previous - row < 2 { return }
                    kept.append(row)
                }
                gaps += zip(baselines, baselines.dropFirst()).map { ($0 - $1, index + 1) }
            }
            guard let smallest = gaps.map(\.gap).min() else { continue }
            widened += gaps.filter { $0.gap > smallest * 1.8 }.map {
                String(format: "paragraph %d page %d: %.1fpt against %.1fpt", number, $0.page, $0.gap, smallest)
            }
        }
        return widened
    }
}
