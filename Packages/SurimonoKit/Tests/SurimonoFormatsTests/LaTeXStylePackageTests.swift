import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXStylePackageTests {
    private func paper(_ preamble: String, body: String = #"\maketitle"#) -> HTMLFragment {
        LaTeXConverter.convert(
            #"\documentclass{article}"# + preamble
                + #"\title{Mixed Case}\author{First Writer \\ West \And Second Writer \\ East \AND Third Writer}\date{Secret date}"#
                + #"\begin{document}"# + body + #"\end{document}"#)
    }

    @Test("年を含む完全なパッケージ名だけが同じ系列の組み込み定義を選ぶ")
    func registryTable() throws {
        for (name, year, definition, family) in [
            ("neurips_2023", "2023", 2026, "neurips"), ("neurips_2036", "2036", 2026, "neurips"),
            ("iclr2024_conference", "2024", 2027, "iclr"), ("iclr2099_conference", "2099", 2027, "iclr"),
        ] {
            let info = try #require(paper("\\usepackage{\(name)}").latexClass)
            let style = try #require(info.resolvedStyle)
            #expect(style.requestedName == name)
            #expect(style.year == year)
            #expect(style.definitionYear == definition)
            #expect(style.family.rawValue == family)
            #expect(style.classProfile.id == .article)
            #expect(info.profile.id == .article)
        }
        for name in [
            "neurips", "neurips_202", "neurips_２０２６", "neurips_2026_notes", "myiclr2027_conference", "iclr2027",
        ] {
            #expect(LaTeXStylePackageRegistry.match(name, options: []) == nil)
        }
    }

    @Test("原稿開始時に通過オプションと記載順、査読状態、未知の指定を確定する")
    func preambleResolution() throws {
        let fragment = paper(#"\PassOptionsToPackage{main}{neurips_2026}\usepackage[final,Extra]{neurips_2026}"#)
        let style = try #require(fragment.latexClass?.resolvedStyle)
        #expect(style.options == ["main", "final", "Extra"])
        #expect(style.mode == .final)
        #expect(style.diagnostics == ["Extra"])
        #expect(fragment.readingIssues.contains("neurips_2026: unknown option Extra"))
        let before = paper(#"\usepackage{palatino}\usepackage{neurips_2026}"#)
        #expect(before.latexClass?.mainFontName == "Times New Roman")
        let after = paper(#"\usepackage{neurips_2026}\usepackage{palatino}"#)
        #expect(after.latexClass?.mainFontName == "Palatino")
        let camera = paper(#"\usepackage{iclr2028_conference}\usepackage{times}\iclrfinalcopy"#)
        #expect(camera.latexClass?.resolvedStyle?.mode == .final)
        #expect(camera.latexClass?.mainFontName == "Times New Roman")
        #expect(camera.latexClass?.pageNumbers.header == ["Published as a conference paper at ICLR 2028", "", ""])
    }

    @Test("査読原稿は規定の匿名表記と柱または提出通知を刷り、完成原稿は横並びと改行を保つ")
    func frontMatter() throws {
        for (package, fixed, furniture) in [
            ("neurips_2026", "Anonymous Author(s)", "Submitted to 40th Conference"),
            ("iclr2027_conference", "Anonymous authors", "Under review as a conference paper at ICLR 2027"),
        ] {
            let fragment = paper("\\usepackage{\(package)}")
            let style = try #require(fragment.latexClass?.resolvedStyle)
            #expect(fragment.body.contains("<strong>\(fixed)</strong>"))
            #expect(!fragment.body.contains("Writer"))
            #expect(!fragment.body.contains("Secret date"))
            #expect((style.firstPageNotice ?? style.runningHeader ?? "").contains(furniture))
            #expect(style.review != nil)
        }
        for preamble in [
            #"\usepackage[main,final]{neurips_2026}"#, #"\usepackage{iclr2027_conference,times}\iclrfinalcopy"#,
        ] {
            let fragment = paper(preamble)
            #expect(fragment.latexClass?.resolvedStyle?.review == nil)
            #expect(fragment.body.components(separatedBy: "class=\"latex-author-row\"").count == 3)
            #expect(fragment.body.components(separatedBy: "class=\"latex-front-author\"").count == 4)
            #expect(fragment.body.contains("<strong>Second Writer</strong>"))
            #expect(!fragment.body.contains("Secret date"))
            #expect(!fragment.body.contains("Anonymous"))
        }
        let preprint = paper(#"\usepackage[preprint]{neurips_2026}"#)
        #expect(preprint.latexClass?.resolvedStyle?.firstPageNotice == "Preprint.")
        #expect(preprint.body.contains("First Writer"))
        let final = paper(#"\usepackage[main,final]{neurips_2026}"#)
        #expect(
            final.latexClass?.resolvedStyle?.firstPageNotice
                == "40th Conference on Neural Information Processing Systems (NeurIPS 2026).")
        let singleBlind = paper(#"\usepackage[sglblindworkshop,nonatbib]{neurips_2026}"#)
        #expect(singleBlind.body.contains("First Writer"))
        #expect(singleBlind.latexClass?.resolvedStyle?.loadsNatbib == false)
        #expect(singleBlind.latexClass?.resolvedStyle?.review == .textLines)
    }

    @Test("レター用紙の本文寸法と行送りを適用し、文書の余白・柱・段落指定を優先する")
    func dimensions() throws {
        for (package, top, pitch, skip) in [
            ("neurips_2026", 72.0, "10.95", "5.5"),
            ("iclr2027_conference", 81.862, "11", "6"),
        ] {
            let info = try #require(paper("\\usepackage{\(package)}").latexClass)
            let box = info.pageBox
            #expect(abs(box.paperWidth - 612) < 0.001 && abs(box.paperHeight - 792) < 0.001)
            #expect(abs(box.textWidth - 396) < 0.001 && abs(box.textHeight - 648) < 0.001)
            #expect(abs(box.left - 108) < 0.001 && abs(box.top - top) < 0.001)
            #expect(info.styleVariables.contains("--latex-array-baseline: \(pitch)"))
            #expect(info.styleVariables.contains("--latex-parskip: calc(\(skip) * var(--tex-pt))"))
        }
        let info = try #require(
            paper(
                #"\usepackage{iclr2027_conference}\usepackage[margin=1in]{geometry}\setlength{\textwidth}{300pt}\setlength{\parskip}{3pt}\pagestyle{empty}"#
            ).latexClass)
        #expect(abs(info.pageBox.left - 72) < 0.001)
        #expect(abs(info.pageBox.textWidth - 298.879) < 0.001)
        #expect(info.pageNumbers.header == ["", "", ""])
        #expect(info.pageNumbers.footer == ["", "", ""])
        #expect(!info.styleVariables.contains("--latex-parskip: calc(6 "))
    }

    @Test("原稿が既知のパッケージを読み込んでも隣のスタイルファイルを要求しない")
    func noCompanionRead() {
        var reads: [URL] = []
        let fragment = LaTeXConverter.convert(
            #"\documentclass[a4paper]{article}\usepackage{neurips_2026}\begin{document}Text.\end{document}"#,
            documentURL: URL(fileURLWithPath: "/corpus/main.tex"),
            readFile: {
                reads.append($0)
                return nil
            })
        #expect(reads.isEmpty)
        #expect(abs((fragment.latexClass?.pageBox.paperWidth ?? 0) - 612) < 0.001)
    }

    private let items = #"""
        \begin{thebibliography}{9}
        \bibitem[Model Rail Desk(2025)Model Rail Desk and Crew]{a}Book A.
        \bibitem[Bench(2024)]{b}Book B.
        \bibitem[Ruler(2023)]{c}Book C.
        \end{thebibliography}
        """#

    @Test("手書き文献の著者年を各引用命令で読み、前後注と複数キーを保つ")
    func manualLabels() {
        for (command, expected) in [
            (#"\cite{a}"#, "Model Rail Desk (2025)"), (#"\cite[p. 3]{a}"#, "(Model Rail Desk, 2025, p. 3)"),
            (#"\citep[see][p. 3]{a,b}"#, "(see Model Rail Desk, 2025; Bench, 2024, p. 3)"),
            (#"\citet[see][p. 4]{b}"#, "Bench (see 2024, p. 4)"),
            (#"\citealp{a,b}"#, "Model Rail Desk, 2025; Bench, 2024"), (#"\citeauthor{b}"#, "Bench"),
            (#"\citeyear{b}"#, "2024"), (#"\citeauthor*{a}"#, "Model Rail Desk and Crew"),
        ] {
            let html = paper(#"\usepackage{natbib}"#, body: command + items).body
            #expect(DocumentOutline.plainText(ofHTML: html).contains(expected), "\(command)")
            #expect(html.contains(#"class="latex-bibliography latex-author-year""#))
            #expect(!html.contains(#"class="bib-label""#))
        }
    }

    @Test("文献番号は掲載順を使い、括弧・並べ替え・連続番号の圧縮を反映する")
    func numericLabels() {
        let html = paper(
            #"\PassOptionsToPackage{numbers,sort&compress}{natbib}\usepackage{neurips_2026}\setcitestyle{round}"#,
            body: #"\citep{c,a,b}"# + items
        ).body
        #expect(DocumentOutline.plainText(ofHTML: html).contains("(1–3)"))
        #expect(html.contains(#"class="bib-label">[1]"#))
        let square = paper(#"\usepackage{natbib}\setcitestyle{square}"#, body: #"\citep{a}"# + items).body
        #expect(DocumentOutline.plainText(ofHTML: square).contains("[Model Rail Desk, 2025]"))
    }
}
