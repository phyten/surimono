import Foundation
import Testing

@testable import SurimonoFormats

@Suite("目次の見出しの題")
struct OutlineTitleTests {
    private func titles(_ html: String) -> [String] {
        DocumentOutline.headings(inHTML: html).map(\.text)
    }

    /// The first table of contents in the body.
    private func contents(in body: String) throws -> Substring {
        let rest = body[try #require(body.range(of: "<nav")).lowerBound...]
        return rest[..<(try #require(rest.range(of: "</nav>"))).lowerBound]
    }

    @Test("Org の見出しのタグ・作業の語・優先度は題に入れず、進み具合は残す")
    func orgTagsLeftOut() {
        let source = """
            * TODO [#A] 印刷の準備 [2/4] :sample:print:
            ** NEXT 持ち物 :list:
            ** 表紙の絵 :art:
            """
        #expect(titles(OrgConverter.convert(source).body) == ["印刷の準備 [2/4]", "持ち物", "表紙の絵"])
    }

    @Test("Org の作業の語と優先度は、ページの文字と照らす見出しの文字には残す")
    func orgKeywordsPrinted() {
        let heading = DocumentOutline.headings(inHTML: OrgConverter.convert("* TODO 印刷の準備").body).first
        #expect(heading?.text == "印刷の準備")
        #expect(heading?.printedText == "TODO 印刷の準備")
    }

    @Test("Org の見出しのタグを読まない設定でも、題は同じ")
    func orgTagsOff() {
        let body = OrgConverter.convert("#+OPTIONS: tags:nil\n* NEXT 持ち物 :list:").body
        #expect(titles(body) == ["持ち物"])
    }

    @Test("Markdown の見出しの脚注の番号は題に入れず、ページの文字と照らす文字には残す")
    func markdownFootnoteLeftOut() {
        let body = MarkdownConverter.convert("## 保存場所の変更[^1]\n\n本文\n\n[^1]: 注の文。").body
        let heading = DocumentOutline.headings(inHTML: body).first
        #expect(heading?.text == "保存場所の変更")
        #expect(heading?.printedText == "保存場所の変更1")
    }

    @Test("見出しのリンクは文字だけを題に残す")
    func linkWordsKept() {
        #expect(titles("<h2 id=\"a\"><a href=\"#b\">付録</a>へ戻る</h2>") == ["付録へ戻る"])
    }

    @Test("見出しの数式は題では原文の式になり、照らす文字では式の所を印にする")
    func formulaInTitle() {
        let body = MarkdownConverter.convert("## 収録条件 $n\\neq0$ の確認\n\n本文").body
        let heading = DocumentOutline.headings(inHTML: body).first
        #expect(heading?.text == "収録条件 n\\neq0 の確認")
        #expect(heading?.printedText == "収録条件 \u{FFFC} の確認")
    }

    @Test("Markdown の目次の項目に、見出しの数式を見出しと同じ形で入れる")
    func markdownContentsKeepFormula() throws {
        let body = MarkdownConverter.convert("[TOC]\n\n## 収録条件 $n\\neq0$\n\n本文\n\n## 保存\n\n本文").body
        #expect(try contents(in: body).contains("<svg"))
        #expect(DocumentOutline.sourceContentsEntries(inHTML: body) == ["収録条件 \u{FFFC}", "保存"])
    }

    @Test("front matter の toc の目次は、文書の始めの # の表題の後に置く")
    func markdownLeadAfterTitle() throws {
        let body = MarkdownConverter.convert("---\ntoc: true\n---\n# 表題\n\n## 一\n\n本文\n\n## 二\n\n本文").body
        let title = try #require(body.range(of: "</h1>"))
        let nav = try #require(body.range(of: "<nav"))
        #expect(title.upperBound <= nav.lowerBound)
    }

    @Test("LaTeX の紙の目次の項目には見出しの脚注を入れず、見出しの中のリンクは文字だけにする")
    func latexContentsWithoutNotesAndLinks() throws {
        let body = LaTeXConverter.convert(
            """
            \\documentclass{article}\\begin{document}\\tableofcontents
            \\section{はじめに}\\label{s1}本文
            \\section{注を含む見出し\\footnote{注の文。}}本文
            \\section{\\hyperref[s1]{最初の説明へ戻る}}本文
            \\end{document}
            """
        ).body
        let nav = try contents(in: body)
        #expect(!nav.contains("footnote-ref"))
        #expect(nav.components(separatedBy: "<a ").count - 1 == 3)
        #expect(
            DocumentOutline.sourceContentsEntries(inHTML: body) == ["1 はじめに", "2 注を含む見出し", "3 最初の説明へ戻る"])
        #expect(titles(body) == ["1 はじめに", "2 注を含む見出し", "3 最初の説明へ戻る"])
    }

    @Test("目次の項目のHTMLは、見出しの中の脚注の印と ID を持ち込まない")
    func contentsHTMLLeavesNotesAndIDs() {
        let html = DocumentOutline.contentsHTML(
            ofHeading: "<em id=\"x\">題</em><sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>")
        #expect(html == "<em>題</em>")
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
