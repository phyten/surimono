import Foundation
import Testing

@testable import SurimonoFormats

struct ReadingInstructionTests {
    private func contents(_ html: String) -> [String] {
        html.matches(of: /(?s)<nav class="toc"[^>]*>(.*?)<\/nav>/).map { String($0.1) }
    }

    private let headings = "# Root\n\n## Alpha\n\n### Bravo\n\n#### Charlie\n\n##### Delta"

    @Test(
        "Markdown は先頭の目次だけを指定の深さにし、本文の目次にも番号と題を載せる",
        arguments: ["[TOC]", "[[toc]]", "[[_TOC_]]"])
    func markdown(marker: String) throws {
        let header = "---\ntoc: true\ntoc-depth: 1\ntoc-title: Custom\nnumber-sections: true\n---\n"
        let fragment = MarkdownConverter.convert(header + headings + "\n\n" + marker)
        #expect(fragment.markdownContentsMarker?.lowercased() == marker.lowercased())
        let html = fragment.body
        let navs = contents(html)
        try #require(navs.count == 2)
        for nav in navs {
            #expect(nav.contains("1. Alpha") && nav.contains(">Custom</p>"))
            #expect(!nav.contains("Root") && !nav.contains("Delta"))
        }
        #expect(!navs[0].contains("Bravo") && navs[1].contains("1.1. Bravo"))
        #expect(html.contains(">1.1. Bravo</h3>"))
    }

    @Test("Quarto の目次は絶対段で切り、本文の目次とは別に置く。number-depth は番号を制限しない")
    func quarto() throws {
        let header = "---\ntoc: true\ntoc-depth: 2\ntoc-title: Custom\nnumber-sections: true\nnumber-depth: 1\n---\n"
        let html = ComputationalMarkdown.convert(header + headings + "\n\n[TOC]").body
        let navs = contents(html)
        #expect(navs.count == 2)
        let first = try #require(navs.first)
        #expect(first.contains("Custom") && first.contains("1 Root") && first.contains("1.1 Alpha"))
        #expect(!first.contains("Bravo"))
        #expect(navs.last?.contains("Charlie") == true)
        #expect(html.contains(">1.1.1 Bravo</h3>"))
    }

    @Test(
        "Quarto の format と R Markdown の複数の output の下は読まず、最上位の指定は読む",
        arguments: [
            "format:\n  html:\n    toc: true\n    number-sections: true",
            "output:\n  html_document:\n    toc: true\n    toc_depth: 1\n    number_sections: true\n  pdf_document:\n    toc: true",
        ])
    func computationalMetadata(nested: String) throws {
        let html = ComputationalMarkdown.convert("---\n" + nested + "\n---\n" + headings).body
        #expect(contents(html).isEmpty && html.contains(">Bravo</h3>"))
        let top = ComputationalMarkdown.convert(
            "---\n" + nested + "\ntoc: true\nnumber-sections: true\n---\n" + headings
        ).body
        let navs = contents(top)
        #expect(navs.count == 1)
        let nav = try #require(navs.first)
        #expect(nav.contains("1.1.1 Bravo") && !nav.contains("Charlie"))
    }

    @Test("Org の先頭と本文の目次はそれぞれの深さを使い、番号は num の深さで止まる")
    func org() {
        let html = OrgConverter.convert("#+OPTIONS: num:1 toc:2\n* Alpha\n** Bravo\n*** Charlie\n#+TOC: headlines 1")
            .body
        let navs = contents(html)
        #expect(navs.count == 2)
        #expect(navs.first?.contains("Bravo") == true && navs.first?.contains("Charlie") == false)
        #expect(navs.last?.contains("Alpha") == true && navs.last?.contains("Bravo") == false)
        #expect(html.contains("class=\"section-number-1\"") && !html.contains("class=\"section-number-2\""))
    }

    @Test("reStructuredText の目次と番号は別の相対深さを使い、local の目次にはその節の子だけが入る")
    func rst() {
        let html = RSTConverter.convert(
            """
            .. sectnum::
               :depth: 1

            .. contents::
               :depth: 2

            Alpha
            =====

            .. contents::
               :local:

            Bravo
            -----

            Charlie
            ~~~~~~~

            Delta
            =====
            """
        ).body
        let navs = contents(html)
        #expect(navs.count == 2)
        #expect(navs.first?.contains("1 Alpha") == true && navs.first?.contains("Charlie") == false)
        #expect(navs.first?.contains(">Bravo</a>") == true)
        #expect(navs.last?.contains("Charlie") == true && navs.last?.contains("Delta") == false)
        #expect(html.components(separatedBy: "class=\"sectnum\"").count - 1 == 2)
    }

    @Test("AsciiDoc の JavaScript 変換は目次と番号の深さを別々に扱い、属性の解除を反映する")
    func asciidoc() throws {
        let body = "\n\n== Alpha\n\n=== Bravo\n\n==== Charlie"
        let header = "= Title\n:toc:\n:toclevels: 2\n:sectnums:\n:sectnumlevels: 1"
        let html = try AsciiDocConverter.convert(header + body).body
        let navs = contents(html)
        #expect(navs.count == 1)
        let nav = try #require(navs.first)
        #expect(nav.contains("1. Alpha") && nav.contains("Bravo") && !nav.contains("Charlie"))
        #expect(html.contains(">Bravo</h3>"))
        let cleared = try AsciiDocConverter.convert(header + "\n:toc!:\n:sectnums!:" + body).body
        #expect(contents(cleared).isEmpty && cleared.contains(">Alpha</h2>"))
    }

    @Test("AsciiDoc の macro は本文のマクロ位置にだけ目次を置き、本文途中で番号を切れる")
    func asciiDocMacro() throws {
        let header = "= Title\n:toc: macro\n:sectnums:\n\n== Alpha\n\n"
        let suffix = "\n\n:sectnums!:\n\n== Bravo"
        let without = try AsciiDocConverter.convert(header + suffix).body
        #expect(contents(without).isEmpty)
        let with = try AsciiDocConverter.convert(header + "toc::[]" + suffix).body
        #expect(contents(with).count == 1)
        let heading = try #require(with.range(of: ">1. Alpha</h2>"))
        let nav = try #require(with.range(of: "<nav class=\"toc\""))
        #expect(heading.upperBound <= nav.lowerBound && with.contains(">Bravo</h2>"))
    }

    @Test("MediaWiki の強制・本文の目次は合わせて一つで章から三段、NOTOC は両方を隠す")
    func wiki() throws {
        let body = "\n= Root =\n== Alpha ==\n=== Bravo ===\n==== Charlie ====\n===== Delta ====="
        for marker in ["__FORCETOC__", "__TOC__", "__FORCETOC__\n__TOC__"] {
            let html = MediaWikiConverter.convert(marker + body).body
            let navs = contents(html)
            #expect(navs.count == 1)
            let nav = try #require(navs.first)
            #expect(nav.contains("Alpha") && nav.contains("Charlie") && !nav.contains("Root") && !nav.contains("Delta"))
            #expect(html.contains(">Charlie</h4>"))
            #expect(contents(MediaWikiConverter.convert(marker + body + "\n__NOTOC__").body).isEmpty)
        }
        #expect(contents(MediaWikiConverter.convert(body).body).isEmpty)
    }
}
