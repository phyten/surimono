import Foundation
import Testing

@testable import SurimonoFormats

@Suite("目次の見出しの題")
struct OutlineTitleTests {
    private func titles(_ html: String) -> [String] {
        DocumentOutline.headings(inHTML: html).map(\.text)
    }

    @Test("Org の見出しのタグは題に入れず、作業の語と進み具合は残す")
    func orgTagsLeftOut() {
        let source = """
            * TODO 印刷の準備 [2/4] :sample:print:
            ** NEXT 持ち物 :list:
            ** 表紙の絵 :art:
            """
        #expect(titles(OrgConverter.convert(source).body) == ["TODO 印刷の準備 [2/4]", "NEXT 持ち物", "表紙の絵"])
    }

    @Test("Org の見出しのタグを読まない設定でも、題は同じ")
    func orgTagsOff() {
        let body = OrgConverter.convert("#+OPTIONS: tags:nil\n* NEXT 持ち物 :list:").body
        #expect(titles(body) == ["NEXT 持ち物"])
    }

    @Test("Org の本文の目次の項目にも、見出しのタグを入れない")
    func orgContentsTagsLeftOut() {
        let body = OrgConverter.convert("#+OPTIONS: toc:t tags:t\n* 前提 :scope:\n** 関係 :evidence:art:\n* 結び").body
        #expect(DocumentOutline.sourceContentsEntries(inHTML: body) == ["前提", "関係", "結び"])
    }

    @Test("LaTeX の節の番号と題の間に空白を入れる")
    func latexNumberSpaced() {
        let body = LaTeXConverter.convert(
            "\\documentclass{article}\\begin{document}\\section{はじめに}本文\\subsection{冊数}本文\\end{document}"
        ).body
        #expect(titles(body) == ["1 はじめに", "1.1 冊数"])
    }

    @Test(
        "和文の章は「第1章 題」の形になり、縦組みのクラスでも同じ",
        arguments: [("jreport", "第 1 章 はじめに"), ("tbook", "第1章 はじめに"), ("jlreq", "第 1 章 はじめに")])
    func japaneseChapters(documentClass: String, expected: String) {
        let body = LaTeXConverter.convert(
            "\\documentclass{\(documentClass)}\\begin{document}\\chapter{はじめに}本文\\end{document}"
        ).body
        #expect(titles(body).first == expected)
    }
}
