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
            ("icml2026", "2026", 2026, "icml"), ("icml2050", "2050", 2026, "icml"),
            ("cvpr", "", 2027, "cvpr"), ("acl", "", 2026, "acl"), ("aaai2030", "2030", 2027, "aaai"),
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
            "myicml2026", "icml２026", "icml203", "aaai", "aaai2027final", "ACL", "cvpr2027",
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

    @Test("前置きで段末ぞろえと文末の空きを明示的に上書きできる")
    func documentOverrides() throws {
        let ragged = paper(#"\usepackage{cvpr}\raggedbottom\frenchspacing"#)
        #expect(ragged.latexClass?.resolvedStyle?.raggedBottom == true)
        #expect(ragged.latexClass?.resolvedStyle?.frenchSpacing == true)
        let reset = paper(#"\usepackage{aaai2027}\raggedbottom\flushbottom\nonfrenchspacing"#)
        #expect(reset.latexClass?.resolvedStyle?.raggedBottom == false)
        #expect(reset.latexClass?.resolvedStyle?.frenchSpacing == false)
    }

    @Test("二段の学会原稿は各用紙寸法・段間・本文の行送りを使う")
    func twoColumnPageBoxes() throws {
        for (package, width, left, top, height, gap, pitch) in [
            ("icml2026", 486.0, 55.44, 67.07, 648.0, 18.0675, "12"),
            ("cvpr", 495, 58.5, 72, 639, 22.584375, "12"),
            ("acl", 453.543, 70.866, 70.866, 701.968, 17.07165, "13.6"),
            ("aaai2027", 504, 54, 54, 648, 27.10125, "11"),
        ] {
            let fragment = paper("\\usepackage{\(package)}")
            let info = try #require(fragment.latexClass)
            #expect(info.columns == 2)
            #expect(abs(info.pageBox.textWidth - width) < 0.01)
            #expect(abs(info.pageBox.left - left) < 0.01 && abs(info.pageBox.top - top) < 0.01)
            #expect(abs(info.pageBox.textHeight - height) < 0.01)
            #expect(abs((info.resolvedStyle?.columnGap ?? 0) - gap) < 0.001)
            #expect(info.styleVariables.contains("--latex-array-baseline: \(pitch)"))
            #expect(fragment.body.contains(#"class="latex-title-block" data-latex-wide"#))
        }
    }

    @Test("ICML の表題命令を一度だけ読み、所属・連絡先・通知を左段の注へ送る")
    func affiliationList() throws {
        let title = #"""
            \twocolumn[\icmltitle{Wide Title}
            \begin{icmlauthorlist}\icmlauthor{First Writer}{b,a}\icmlauthor{Next Writer}{a}\end{icmlauthorlist}
            \icmlaffiliation{a}{West}\icmlaffiliation{b}{East}
            \icmlcorrespondingauthor{First Writer}{desk@example.com}\icmlkeywords{hidden-keyword}\vskip 0.3in]
            \printAffiliationsAndNotice{\icmlEqualContribution}\section{Introduction}Body.
            """#
        for (option, anonymous) in [("", true), ("[accepted]", false), ("[preprint,nohyperref]", false)] {
            let fragment = paper("\\usepackage\(option){icml2026}\\icmltitlerunning{Short title}", body: title)
            #expect(fragment.body.components(separatedBy: "Wide Title").count == 2)
            #expect(fragment.body.contains(#"data-latex-column-notice="first""#))
            #expect(fragment.body.contains(#"<span class="secnum">1.</span>"#))
            let plain = DocumentOutline.plainText(ofHTML: fragment.body)
            #expect(!plain.contains("hidden-keyword") && !plain.contains("0.3in"))
            #expect(fragment.body.contains("Anonymous Authors</strong><sup>1</sup>") == anonymous)
            #expect(fragment.body.contains("--latex-byline-spaces: 2") == anonymous)
            #expect(fragment.body.contains("First Writer") != anonymous)
            #expect(fragment.body.contains("First Writer</strong>\u{202F}<sup>1,2</sup>") != anonymous)
            #expect(fragment.body.contains("Anonymous Institution") == anonymous)
            #expect(fragment.body.contains("<sup>1</sup>East <sup>2</sup>West") != anonymous)
            #expect(fragment.body.contains("desk@example.com") != anonymous)
            #expect(fragment.body.contains("Equal contribution") != anonymous)
            #expect(fragment.latexClass?.pageNumbers.header == ["", "Short title", ""])
            #expect((fragment.latexClass?.resolvedStyle?.review == .leftRuler) == anonymous)
        }
    }

    @Test("CVPR は投稿番号と会議名を展開し、完成稿で署名とページ番号の指定を反映する")
    func reviewBannerAndSignature() throws {
        let defs = #"\def\paperID{42}\def\confName{Workshop}\def\confYear{2030}"#
        let review = paper(#"\usepackage[review]{cvpr}"# + defs)
        #expect(
            review.latexClass?.resolvedStyle?.reviewBanner
                == "Workshop 2030 Submission #42. CONFIDENTIAL REVIEW COPY. DO NOT DISTRIBUTE.")
        #expect(review.latexClass?.resolvedStyle?.reviewCorner == "Workshop")
        #expect(review.body.contains("Anonymous Workshop submission<br>Paper ID 42"))
        #expect(!review.body.contains("First Writer"))
        for (option, mode, numbered) in [
            ("", "final", false), ("[pagenumbers]", "final", true), ("[rebuttal]", "rebuttal", false),
        ] {
            let page = paper("\\usepackage\(option){cvpr}")
            #expect(page.latexClass?.resolvedStyle?.mode.rawValue == mode)
            #expect(page.latexClass?.pageNumbers.footer.contains("1") == numbered)
            #expect(page.body.contains("First Writer") == (mode == "final"))
        }
        let cites = paper(#"\usepackage{cvpr}"#, body: #"\citep{c,b,a}"# + items)
        #expect(DocumentOutline.plainText(ofHTML: cites.body).contains("[1–3]"))
        #expect(cites.body.contains(#"class="bib-label">[2]"#))
    }

    @Test("著者年方式の会議の cite は括弧を付け、明示した引用形式とリンク色を保存する")
    func parentheticalCiteAndOptions() {
        for name in ["icml2026", "acl"] {
            let style = "\\usepackage{\(name)}"
            let body = #"\cite{a}"# + items
            #expect(
                DocumentOutline.plainText(ofHTML: paper(style, body: body).body).contains("(Model Rail Desk, 2025)"))
            let options = #"\usepackage[numbers,square]{natbib}\usepackage[colorlinks,citecolor=red]{hyperref}"#
            for preamble in [options + style, style + options] {
                let html = paper(preamble, body: body).body
                #expect(DocumentOutline.plainText(ofHTML: html).contains("[1]"))
                #expect(html.contains("--latex-cite-ink, #ff0000"))
            }
        }
    }

    @Test("本文中の著者年引用では著者と年に同じ文献へのリンクを付け、前後注を保つ")
    func textualAuthorLinks() {
        for name in ["icml2026", "acl"] {
            let html = paper("\\usepackage{\(name)}", body: #"\citet[see][p. 3]{a}"# + items).body
            #expect(html.contains(#">Model Rail Desk</a> (see <a href="#))
            #expect(html.contains(#">2025</a>, p. 3)"#))
        }
    }

    @Test("数値と単位を改行しない空白で結び、明示したハイフン対は普通のダッシュにする")
    func nonbreakingSpaces() {
        for name in ["icml2026", "cvpr", "acl", "aaai2027"] {
            let source = #"0.06\,mm A\thinspace B C\;D E\:F G~H I\nobreakspace J pages 12--19. \textbf{1\,}mm"#
            let html = paper("\\usepackage{\(name)}", body: source).body
            let text = DocumentOutline.plainText(ofHTML: html)
            #expect(
                text.contains(
                    "0.06\u{202F}mm A\u{202F}B C\u{00A0}D E\u{00A0}F G\u{00A0}H I\u{00A0}J pages 12–19. 1\u{202F}mm"))
        }
    }

    @Test("無限の縦のりは自然長と伸びの次数・比率を段組みに渡し、後続の本文を残す")
    func infiniteGlue() {
        let source = #"A\vfil B\vfill C\vspace*{3pt plus 2.5fil}D\vskip 4pt plus .5filll E"#
        let html = paper(#"\usepackage{acl}"#, body: source).body
        #expect(html.contains(#"data-latex-fil="1" style="height:"#))
        #expect(html.contains(#"data-latex-fil="1" data-latex-fil-order="2" style="height: 0px"#))
        #expect(html.contains(#"data-latex-keep-space data-latex-fil="2.5" style="height: calc(3 *"#))
        #expect(html.contains(#"data-latex-fil="0.5" data-latex-fil-order="3" style="height: calc(4 *"#))
        #expect(html.contains("<p>E</p>"))
    }

    @Test("二段の著者欄は一人分の行をまとめ、同じ行の署名の間だけに間隔を設ける")
    func authorBlocks() {
        let html = paper(#"\usepackage{acl}"#).body
        #expect(html.components(separatedBy: #"class="latex-author-lines""#).count == 4)
        #expect(html.components(separatedBy: #"class="latex-author-separator""#).count == 2)
        let single = paper(#"\usepackage[final]{neurips_2026}"#).body
        #expect(!single.contains("latex-author-lines") && !single.contains("latex-author-separator"))
    }

    @Test("段抜き表題の中で指定した柱は本文より先に反映する")
    func runningTitleFromBracket() {
        for input in [
            #"\icmltitlerunning{Short}\icmltitle{Full}"#,
            #"\icmltitle{Full}\icmltitlerunning{Short}"#,
        ] {
            let fragment = paper(#"\usepackage{icml2026}"#, body: "\\twocolumn[\(input)]Body")
            #expect(fragment.latexClass?.pageNumbers.header == ["", "Short", ""])
            #expect(fragment.latexClass?.pageNumbers.runningTitle == "Short")
        }
        let broken = paper(#"\usepackage{icml2026}"#, body: #"\twocolumn[\icmltitle{First\\Second}]"#)
        #expect(broken.latexClass?.pageNumbers.header == ["", "Title Suppressed Due to Excessive Size", ""])
    }

    @Test("会議指定の引用色とキャプション記号は文書の再指定を尊重する")
    func citationsAndCaptions() {
        let content = #"\citep{a}\begin{figure}\caption{Gauge}\end{figure}"# + items
        for name in ["icml2026", "cvpr", "acl", "aaai2027"] {
            let fragment = paper("\\usepackage{\(name)}", body: content)
            let text = DocumentOutline.plainText(ofHTML: fragment.body)
            if name == "icml2026" {
                #expect(text.contains("(Model Rail Desk, 2025)"))
                #expect(fragment.body.contains("#001473"))
            }
            #expect(
                fragment.body.contains(
                    name == "icml2026" || name == "cvpr"
                        ? #"class="latex-caption-label">Figure 1.</span> Gauge"#
                        : #"class="latex-caption-label">Figure 1</span>: Gauge"#))
        }
        let override = paper(#"\usepackage[nohyperref]{icml2026}\captionsetup{labelsep=colon}"#, body: content)
        #expect(!override.body.contains("#001473"))
        #expect(override.body.contains(#"class="latex-caption-label">Figure 1</span>: Gauge"#))
    }

    @Test("ACL は既定で最終稿を選び、査読時だけ匿名と欄外番号を使う")
    func aclModes() throws {
        for (option, mode) in [
            ("", "final"), ("[final]", "final"), ("[review]", "submission"), ("[preprint]", "preprint"),
        ] {
            let fragment = paper(
                "\\usepackage\(option){acl}\\usepackage{times}",
                body: #"\maketitle\section{Introduction}\citep{a}"# + items)
            let info = try #require(fragment.latexClass)
            #expect(info.resolvedStyle?.mode.rawValue == mode)
            #expect((info.resolvedStyle?.review == .grayColumnLines) == (mode == "submission"))
            #expect(info.pageNumbers.footer.contains("1") == (mode == "submission"))
            #expect(fragment.body.contains("Anonymous ACL submission") == (mode == "submission"))
            #expect(fragment.body.contains("First Writer") != (mode == "submission"))
            #expect(fragment.body.contains(#"<span class="secnum">1</span>"#))
            #expect(DocumentOutline.plainText(ofHTML: fragment.body).contains("(Model Rail Desk, 2025)"))
            #expect(fragment.body.contains("#000080"))
            #expect(info.mainFontName == "Times New Roman")
        }
    }

    @Test("AAAI は所属を署名の下に置き、モード別の末尾注・番号なし見出し・引用を作る")
    func affiliationsAndCopyright() throws {
        let body = #"\maketitle\section{Intro}\subsubsection{Run.}Text \cite{a}."# + items
        for (option, notice, hidden) in [
            ("", "All rights reserved.", false), ("[submission]", "anonymized submission", true),
            ("[ccby]", "CC BY 4.0", false), ("[draft]", "", false), ("[preprint]", "", false),
        ] {
            let fragment = paper(
                "\\usepackage\(option){aaai2027}\\usepackage{natbib}\\affiliations{Our Lab}", body: body)
            let info = try #require(fragment.latexClass)
            #expect(info.mainFontName == "Times New Roman")
            #expect(info.pageNumbers.footer == ["", "", ""])
            #expect(fragment.body.contains("Our Lab") != hidden)
            #expect(fragment.body.contains("Anonymous submission") == hidden)
            #expect(fragment.body.contains(#"data-latex-column-notice="last""#) == !notice.isEmpty)
            if !notice.isEmpty { #expect(fragment.body.contains(notice)) }
            #expect(!fragment.body.contains(#"class="secnum""#))
            #expect(fragment.body.contains(#"class="latex-runin-subsubsection""#))
            #expect(DocumentOutline.plainText(ofHTML: fragment.body).contains("(Model Rail Desk 2025)"))
            #expect(!fragment.body.contains(#"class="bib-label""#))
        }
        let numbered = paper(
            #"\usepackage{aaai2027}\setcounter{secnumdepth}{1}"#, body: #"\section{One}\subsection{Two}"#)
        #expect(numbered.body.components(separatedBy: #"class="secnum""#).count == 2)
    }
}
