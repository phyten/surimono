import Foundation
import Testing

@testable import SurimonoFormats

struct ContentsLinkTests {
    // Inspect real tags and decoded attributes, including every occurrence of a repeated link.
    private func targets(in body: String, minimumLinks: Int) -> [String] {
        var ids: [String: Int] = [:]
        var links: [String] = []
        for case .tag(let tag) in HTMLScanner.tokens(body) where !tag.isClosing {
            if let id = tag.attribute("id") { ids[id, default: 0] += 1 }
            if tag.name == "a", let href = tag.attribute("href"), href.hasPrefix("#") {
                let name = String(href.dropFirst())
                links.append(name.removingPercentEncoding ?? name)
            }
        }
        #expect(links.count >= minimumLinks)
        #expect(ids.values.allSatisfy { $0 == 1 })
        for link in links { #expect(!link.isEmpty && ids[link] == 1, "href=#\(link)") }
        return links
    }

    @Test("Org の目次は番号の有無・見出しの飾り・抽出条件によらず同じ本文を指す", arguments: [false, true])
    func org(numbered: Bool) {
        var defaults = OrgReadingDefaults.surimono
        defaults.sectionNumbers = numbered ? .all : .off
        defaults.tableOfContents = .all
        defaults.priority = true
        let headings = """
            * TODO [#A] *予定* [[https://example.org/][確認]] [1/2] :仕事:
            :PROPERTIES:
            :CUSTOM_ID: 2-準備
            :END:
            ** 日本語
            ** 日本語
            ** 番号なし
            :PROPERTIES:
            :UNNUMBERED: t
            :END:
            ** 未掲載
            :PROPERTIES:
            :UNNUMBERED: notoc
            :END:
            *** 深い節
            * 除外 :noexport:
            """
        for directive in ["#+OPTIONS: toc:t H:2", "#+OPTIONS: toc:nil H:2\n#+TOC: headlines 2", "#+OPTIONS: H:2"] {
            let html = OrgConverter.convert(directive + "\n" + headings, defaults: defaults).body
            #expect(targets(in: html, minimumLinks: 4) == ["2-準備", "日本語", "日本語-1", "番号なし"])
        }
    }

    @Test(
        "各形式の目次・本文参照は一意なアンカーに解決できる",
        arguments: [DocumentFormat.markdown, .rst, .asciidoc, .mediawiki, .latex, .quarto, .rMarkdown, .notebook])
    func contents(format: DocumentFormat) throws {
        let headings = "# 見本\n\n## *日本語*\n\n## 日本語\n\n### 2番目\n\n###### 深い節"
        let html: String
        switch format {
        case .markdown:
            html = MarkdownConverter.convert("[TOC]\n\n" + headings + "\n\n注[^x]\n\n[^x]: 本文").body
        case .rst:
            html =
                RSTConverter.convert(
                    """
                    .. contents:: 目次

                    *日本語*
                    ===============

                    日本語
                    ===============

                    2番目
                    ---------------

                    深い節
                    ~~~~~~~~~~~~~~~
                    """
                ).body
        case .asciidoc:
            html = try AsciiDocConverter.convert(
                "= 見本\n:toc:\n\n== *日本語*\n\n== 日本語\n\n=== 2番目\n\n==== 深い節"
            ).body
        case .mediawiki:
            html =
                MediaWikiConverter.convert(
                    "__TOC__\n== ''日本語'' ==\n== 日本語 ==\n=== 2番目 ===\n====== 深い節 ======"
                ).body
        case .latex:
            html =
                LaTeXConverter.convert(
                    #"""
                    \documentclass{article}\usepackage{hyperref}\begin{document}
                    \tableofcontents\section{\emph{日本語}}\label{one}\section{日本語}
                    \subsection{2番目}\paragraph{深い節}\ref{one}\cite{book}
                    \begin{thebibliography}{9}\bibitem{book}本\end{thebibliography}\end{document}
                    """#
                ).body
        case .quarto, .rMarkdown:
            let header = format == .quarto ? "toc: true" : "output:\n  html_document:\n    toc: true"
            html = ComputationalMarkdown.convert("---\n" + header + "\n---\n" + headings, format: format).body
        case .notebook:
            let cells = ["[TOC]\n\n# 見本\n\n## *日本語*", "## 日本語\n\n### 2番目\n\n###### 深い節"]
            let data = try JSONSerialization.data(withJSONObject: [
                "nbformat": 4, "cells": cells.map { ["cell_type": "markdown", "source": $0] },
            ])
            html = try NotebookConverter.convert(String(decoding: data, as: UTF8.self)).body
        default:
            Issue.record("対象外の形式")
            return
        }
        #expect(!DocumentOutline.sourceContentsEntries(inHTML: html).isEmpty)
        #expect(Set(targets(in: html, minimumLinks: 3)).count >= 3)
    }

    @Test("Markdown の脚注と同じ名前の見出しにも目次から移れる")
    func markdownFootnoteIDs() {
        let html = MarkdownConverter.convert("[TOC]\n\n# fn-1\n\n# fnref-1\n\nNote[^a].\n\n[^a]: Text.").body
        #expect(targets(in: html, minimumLinks: 3) == ["section-fn-1", "section-fnref-1", "fn-1"])
    }

    @Test("Quarto と R Markdown は記号だけの題と重複した指定 ID にも別々の目次項目を作る")
    func computationalIDs() {
        let html = ComputationalMarkdown.convert("---\ntoc: true\n---\n# !!!\n# 一 {#sample}\n# 二 {#sample}").body
        #expect(targets(in: html, minimumLinks: 3) == ["section", "sample", "sample-1"])
    }

    @Test("脚注と同名の見出しは番号を外しても目次から見出しへ飛べる", arguments: [DocumentFormat.quarto, .rMarkdown], [true, false])
    func computationalFootnoteIDs(format: DocumentFormat, numbered: Bool) {
        let header =
            format == .quarto
            ? "toc: true\nnumber-sections: \(numbered)"
            : "output:\n  pdf_document:\n    toc: true\n    number_sections: \(numbered)"
        let source = "---\n" + header + "\n---\n# fn-1 {.unnumbered}\n\n# fnref-1\n\nNote[^a].\n\n[^a]: Text."
        let html = ComputationalMarkdown.convert(source, format: format).body
        #expect(targets(in: html, minimumLinks: 3) == ["section-fn-1", "section-fnref-1", "fn-1"])
        #expect(html.contains(#"<h1 id="section-fn-1">fn-1</h1>"#))
    }

    @Test("下線見出しと同名の節を参照しても、採番した節のリンクと番号が一致する")
    func computationalSectionReference() {
        let source = "---\nnumber-sections: true\ntoc: true\n---\nsec-end\n=======\n\n## End {#sec-end}\n\n@sec-end"
        let html = ComputationalMarkdown.convert(source).body
        #expect(targets(in: html, minimumLinks: 3) == ["sec-end", "sec-end-1", "sec-end-1"])
        #expect(html.contains(##"<a href="#sec-end-1">Section 1.1</a>"##))
    }

    @Test("Djot・Textile・Word の本文から見出しやブックマークに移れる")
    func manualLinks() throws {
        let word = try #require(
            Bundle.module.url(forResource: "word-structure", withExtension: "docx", subdirectory: "Fixtures"))
        for body in [
            try DjotConverter.convert("[Go][見出し]\n\n# 見出し\n\n# 見出し").body,
            try TextileConverter.convert("\"目次\":#outline\n\nh2(#outline). 日本語").body,
            try DocxConverter.convert(Data(contentsOf: word)).body,
        ] {
            _ = targets(in: body, minimumLinks: 1)
        }
    }
}
