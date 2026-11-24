import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SourcePaperTextTests {
    @Test("同じ文字が続く紙は前ページから照合し、ページ境界の改行・タブ・折り返しを原文に戻す")
    func boundaries() throws {
        let pdf = try RenderingFixtures.pdf(count: 3, textPrefix: "紙")
        let text = "\t紙1\r\n\t紙2紙3\n"
        SourcePaperText.attach(text, to: pdf, options: .sourcePage, language: nil)
        func selected(_ pages: [Int]) throws -> String? {
            let selection = PDFSelection(document: pdf)
            for i in pages {
                let page = try #require(pdf.page(at: i))
                selection.add(try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))))
            }
            return SourcePaperText.selected(selection, in: pdf, logicalIndex: { pdf.index(for: $0) })
        }
        #expect(try selected([2]) == "紙3\n")
        #expect(try selected([0]) == "\t紙1\r\n")
        #expect(try selected([1]) == "\t紙2")
        #expect(try selected([0, 1, 2]) == text)
    }

    @Test("表示用のページ番号はソースの選択範囲を延ばさず、最終文字と末尾改行を戻す")
    func displayedFolio() throws {
        let pdf = try RenderingFixtures.pdf(textPrefix: "body")
        SourcePaperText.attach("body1\r\n", to: pdf, options: .sourcePage, language: nil)
        let plan = ViewPageLayout(
            pageCount: 1,
            options: .init(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: true)
        let view = try #require(ViewPageDocument.make(pdf, plan: plan, margin: 0))
        let page = try #require(view.page(at: 0))
        #expect(page.string?.trimmingCharacters(in: .newlines) == "body1")
        let all = try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
        #expect(
            SourcePaperText.selected(all, in: pdf, logicalIndex: { view.index(for: $0) }) == "body1\r\n",
            "pages=\(all.pages.count) ranges=\(all.numberOfTextRanges(on: page)) chars=\(page.numberOfCharacters)/\(page.string?.utf16.count ?? 0)"
        )
        let matches = view.findString("1")
        #expect(matches.count == 1)
        let last = try #require(matches.first)
        #expect(SourcePaperText.selected(last, in: pdf, logicalIndex: { view.index(for: $0) }) == "1")
    }

    @Test("一枚の中で飛び飛びに選んだコードは間の文字をコピーしない")
    func discontiguous() throws {
        let pdf = try RenderingFixtures.pdf(textPrefix: "abcdef")
        SourcePaperText.attach("abcdef1", to: pdf, options: .sourcePage, language: nil)
        let page = try #require(pdf.page(at: 0))
        let selection = PDFSelection(document: pdf)
        selection.add(try #require(page.selection(for: NSRange(location: 0, length: 2))))
        selection.add(try #require(page.selection(for: NSRange(location: 4, length: 2))))
        #expect(SourcePaperText.selected(selection, in: pdf, logicalIndex: { pdf.index(for: $0) }) == "ab\nef")
    }

    @Test("折り返した行末までの選択はそこで終わり、次の行まで選んだときだけ原文の改行とタブが入る")
    func wrappedLineEnd() throws {
        let pdf = try RenderingFixtures.pdf(textPrefix: "// START\nEND\nNEXT")
        SourcePaperText.attach("\t// STARTEND\r\n\tNEXT1\r\n", to: pdf, options: .sourcePage, language: nil)
        let page = try #require(pdf.page(at: 0))
        let text = try #require(page.string) as NSString
        func copied(through end: String) throws -> String? {
            let range = NSUnionRange(text.range(of: "START"), text.range(of: end))
            let selection = try #require(page.selection(for: range))
            return SourcePaperText.selected(selection, in: pdf, logicalIndex: { pdf.index(for: $0) })
        }
        let line = try copied(through: "END")
        #expect(line == "STARTEND")
        let next = try copied(through: "NEXT")
        #expect(next == "STARTEND\r\n\tNEXT")
    }

    @Test("組み直し前の文字と一致しない PDF の範囲から別の原文を取り出さない")
    func mismatch() throws {
        let pdf = try RenderingFixtures.pdf(textPrefix: "different")
        SourcePaperText.attach("wanted", to: pdf, options: .sourcePage, language: nil)
        let page = try #require(pdf.page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
        #expect(SourcePaperText.selected(selection, in: pdf, logicalIndex: { pdf.index(for: $0) }) == nil)
    }

    @Test("合本で選んだ子の同じ文字列をその子の空白に対応付ける")
    func binder() throws {
        let binder = PDFDocument()
        for text in ["紙1\n", "\t紙1\r\n"] {
            let child = try RenderingFixtures.pdf(textPrefix: "紙")
            let page = try #require(child.page(at: 0))
            SourcePaperText.attach(text, to: child, options: .sourcePage, language: nil)
            SourcePaperText.include(child, in: binder, startingAt: binder.pageCount)
            binder.insert(try #require(StandalonePage.copy(of: page)), at: binder.pageCount)
        }
        let finished = try #require(StandalonePage.selectableDocument(binder))
        let page = try #require(finished.page(at: 1))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
        #expect(
            SourcePaperText.selected(selection, in: finished, logicalIndex: { finished.index(for: $0) }) == "\t紙1\r\n")
    }
}
