import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct SourceSelectionBoundaryTests {
    // Specify exactly what PDFKit extracted, independently of the installed fonts and WebKit's pagination.
    private final class Page: PDFPage {
        var extracted = ""
        override var string: String? { extracted }
    }

    private final class Selection: PDFSelection {
        var spans: [(page: PDFPage, range: NSRange)] = []
        override var pages: [PDFPage] { spans.map { $0.page } }
        override func numberOfTextRanges(on page: PDFPage) -> Int { 1 }
        override func range(at index: Int, on page: PDFPage) -> NSRange {
            spans.first { $0.page === page }!.range
        }
    }

    private func copy(_ source: String, pages: [String], selecting: [Int: Range<Int>]) -> String? {
        let pdf = PDFDocument()
        let selection = Selection(document: pdf)
        for (i, text) in pages.enumerated() {
            let page = Page()
            page.extracted = text
            pdf.insert(page, at: i)
            if let range = selecting[i] { selection.spans.append((page, NSRange(range))) }
        }
        SourcePaperText.attach(source, to: pdf, options: .sourcePage, language: nil)
        return SourcePaperText.selected(selection, in: pdf, logicalIndex: { pdf.index(for: $0) })
    }

    @Test("空行がページをまたいで所属を決められないときは先頭ページの原文を返さない")
    func blankPages() {
        let text = "A\n" + String(repeating: "\n", count: 200) + "B\n"
        for first in ["A", "A\n"] {
            let result = copy(text, pages: [first, "", "", "B"], selecting: [0: 0..<first.utf16.count])
            #expect(result == nil)
        }
        // An omitted trailing space can also wrap onto the following sheet.
        #expect(copy("A   \nB", pages: ["A", "B"], selecting: [0: 0..<1]) == nil)
    }

    @Test("改行と字下げが異なる形で抽出された場合は空白の途中を推測せず、タブ直後の文字は復元する")
    func whitespaceEndpoints() {
        let text = "A\r\n\tB"
        let pages = ["A\n B"]
        let indent = copy(text, pages: pages, selecting: [0: 2..<4])
        #expect(indent == nil)
        #expect(copy(text, pages: pages, selecting: [0: 3..<4]) == "B")
        #expect(copy(text, pages: pages, selecting: [0: 0..<4]) == text)
        #expect(copy("A\tB", pages: ["A   B"], selecting: [0: 2..<5]) == nil)
        #expect(copy("A\tB", pages: ["A   B"], selecting: [0: 0..<2]) == nil)
        #expect(copy("A\tB", pages: ["A   B"], selecting: [0: 4..<5]) == "B")
        #expect(copy(text, pages: [text], selecting: [0: 2..<5]) == nil)
        #expect(copy(text, pages: [text], selecting: [0: 0..<2]) == nil)
        #expect(copy(text, pages: [text], selecting: [0: 3..<5]) == "\tB")
    }

    @Test("隣のページでも一部ずつを選んだときは区切り、端まで続く選択だけをつなぐ")
    func adjacentSelections() {
        let pages = ["abc", "def"]
        #expect(copy("abc\ndef", pages: pages, selecting: [0: 0..<1, 1: 2..<3]) == "a\nf")
        #expect(copy("abcdef", pages: pages, selecting: [0: 1..<3, 1: 0..<2]) == "bcde")
        #expect(copy("abc\r\n\tdef", pages: pages, selecting: [0: 1..<3, 1: 0..<2]) == "bc\r\n\tde")
        #expect(copy("abc\r\n\tdef", pages: pages, selecting: [0: 2..<3, 1: 2..<3]) == "c\nf")
        #expect(copy("abc\r\n\tdef", pages: pages, selecting: [0: 0..<1, 1: 0..<1]) == "a\nd")
    }

    @Test("選ばなかったページの前後は別々の選択として区切る")
    func skippedPage() {
        #expect(copy("abcdefghi", pages: ["abc", "def", "ghi"], selecting: [0: 2..<3, 2: 0..<1]) == "c\ng")
    }
}
