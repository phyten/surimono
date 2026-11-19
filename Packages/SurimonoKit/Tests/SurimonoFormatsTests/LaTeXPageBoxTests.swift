import SurimonoFormats
import Testing

struct LaTeXPageBoxTests {
    private func box(_ cls: String, _ options: String, _ preamble: String = "") throws -> LaTeXPageBox {
        let source = "\\documentclass[\(options)]{\(cls)}\n\(preamble)\n\\begin{document}Ink.\\end{document}"
        let fragment = LaTeXConverter.convert(source)
        let info = try #require(fragment.latexClass)
        #expect(info.pageBox == LaTeXConverter.documentClassInfo(source).pageBox)
        #expect(fragment.readingIssues.isEmpty)
        return info.pageBox
    }

    private func check(_ box: LaTeXPageBox, margins: [Double]) {
        for (actual, expected) in zip([box.left, box.right, box.top, box.bottom], margins) {
            #expect(abs(actual - expected) < 0.02)
        }
    }

    @Test("欧文の標準クラスは用紙と級数で決まる本文の四辺を返す")
    func standardClasses() throws {
        for (paper, size, plain, book) in [
            ("a4paper", 10, [124.80, 126.76, 125.80, 120.33], [99.90, 151.67, 124.87, 121.25]),
            ("a4paper", 11, [117.83, 118.79, 126.79, 121.52], [93.92, 142.70, 125.67, 122.64]),
            ("a4paper", 12, [102.88, 103.85, 128.79, 123.31], [81.96, 124.77, 126.67, 125.43]),
            ("letterpaper", 10, [133.77, 134.52, 124.80, 119.25], [106.87, 161.42, 123.87, 120.18]),
            ("letterpaper", 11, [125.80, 127.55, 129.78, 122.84], [100.89, 152.45, 127.67, 124.96]),
            ("letterpaper", 12, [110.85, 112.60, 125.80, 119.75], [88.94, 134.52, 123.68, 121.87]),
        ] {
            for cls in ["article", "report", "book"] {
                let page = try box(cls, "\(paper),\(size)pt")
                check(page, margins: cls == "book" ? book : plain)
                #expect(page.mirrorsSides == (cls == "book"))
            }
        }
    }

    @Test("学会誌のクラスと版型ごとの本文寸法と左上の原点が実 TeX のレジスターと一致する")
    func journalClasses() throws {
        // PDF points from the class registers at begin-document, including geometry's rounded height.
        for (cls, options, width, height, left, top) in [
            ("IEEEtran", "conference,letterpaper", 514.072, 669.489, 48.964, 46.955),
            ("IEEEtran", "conference,a4paper", 514.072, 669.489, 40.602, 46.955),
            ("IEEEtran", "journal,letterpaper", 514.072, 693.400, 48.964, 52.483),
            ("IEEEtran", "journal,a4paper", 514.072, 693.400, 40.602, 52.483),
            ("acmart", "sigconf", 504.403, 623.661, 53.798, 83.686),
            ("acmart", "manuscript", 428.398, 557.908, 73.441, 95.041),
            ("revtex4-2", "aps,preprint", 466.252, 663.014, 72.000, 72.000),
            ("revtex4-2", "reprint", 508.095, 669.489, 54.000, 52.075),
            ("revtex4-2", "twocolumn", 508.095, 669.489, 54.000, 52.075),
            ("llncs", "", 345.827, 547.087, 134.765, 115.836),
            ("elsarticle", "preprint", 343.711, 547.945, 133.768, 124.802),
            ("elsarticle", "1p", 382.565, 559.900, 106.355, 140.995),
            ("elsarticle", "3p", 466.252, 619.676, 64.512, 111.107),
            ("elsarticle", "5p", 520.050, 679.452, 37.613, 81.219),
            ("article", "twocolumn", 467.248, 547.945, 72.000, 124.802),
        ] {
            let page = try box(cls, options)
            for (actual, expected) in zip(
                [page.textWidth, page.textHeight, page.left, page.top], [width, height, left, top])
            {
                #expect(abs(actual - expected) < 0.02, "\(cls) \(options)")
            }
        }
    }

    @Test("二段の学会誌と標準 article は段間をクラスから取り表題と著者を段抜きにする")
    func journalTitlesAndGaps() throws {
        for (declaration, columns, gap) in [
            ("[conference]{IEEEtran}", 2, "12"), ("[format=sigconf]{acmart}", 2, "24"),
            ("[reprint]{revtex4-2}", 2, "18"), ("[twocolumn]{revtex4-2}", 2, "18"),
            ("[twocolumn]{article}", 2, ""), ("[3p,twocolumn]{elsarticle}", 2, "24"),
            ("[5p]{elsarticle}", 2, "18"), ("[1p,twocolumn]{elsarticle}", 1, ""),
            ("[manuscript]{acmart}", 1, ""), ("[preprint]{revtex4-2}", 1, ""),
        ] {
            let source =
                "\\documentclass\(declaration)\\title{Spacers}\\author{Desk}\\begin{document}\\maketitle Body.\\end{document}"
            let fragment = LaTeXConverter.convert(source)
            let info = try #require(fragment.latexClass)
            #expect(info.columns == columns)
            #expect(fragment.body.contains(#"<header class="latex-title-block" data-latex-wide"#) == (columns == 2))
            if !gap.isEmpty { #expect(fragment.body.contains("data-latex-gap=\"\(gap)\"")) }
        }
        let override = LaTeXConverter.convert(
            #"\documentclass[conference]{IEEEtran}\setlength{\columnsep}{15pt}\begin{document}Body\end{document}"#)
        #expect(override.body.contains(#"data-latex-gap="15""#))
        #expect(abs(try box("elsarticle", "5p,letterpaper").paperWidth - 595.276) < 0.02)
        #expect(abs(try box("acmart", "sigconf,a4paper").paperWidth - 612) < 0.02)
        check(try box("IEEEtran", "conference", #"\usepackage[margin=1in]{geometry}"#), margins: [72, 72, 72, 72])
    }

    @Test("学会誌の図表と本文やキャプションの間にはクラスが選ぶ自然長を渡す")
    func journalFloatSkips() {
        for (declaration, register, length) in [
            ("[conference]{IEEEtran}", "abovecaptionskip", "6"),
            ("[journal,12pt]{IEEEtran}", "floatsep", "11.832"),
            ("[sigconf]{acmart}", "textfloatsep", "15"),
            ("[manuscript]{acmart}", "abovecaptionskip", "12"),
            ("[preprint]{revtex4-2}", "floatsep", "14"),
            ("[reprint]{revtex4-2}", "belowcaptionskip", "2"),
            ("{llncs}", "intextsep", "22.7622047"),
            ("{llncs}", "table-caption-skip", "10"),
            ("{memoir}", "abovecaptionskip", "6"),
            ("{memoir}", "belowcaptionskip", "6"),
            ("[11pt]{memoir}", "abovecaptionskip", "6.8"),
            ("[12pt]{memoir}", "belowcaptionskip", "7.25"),
        ] {
            let info = LaTeXConverter.documentClassInfo("\\documentclass\(declaration)\\begin{document}")
            #expect(info.styleVariables.contains("--latex-\(register): calc(\(length) * var(--tex-pt))"))
        }
        let fragment = LaTeXConverter.convert(
            #"\documentclass[conference]{IEEEtran}\setlength{\intextsep}{17pt plus 2pt}\abovecaptionskip=5pt\begin{document}First.\intextsep=30pt Second.\end{document}"#
        )
        #expect(fragment.latexClass?.styleVariables.contains("--latex-intextsep: calc(17 * var(--tex-pt") == true)
        #expect(fragment.latexClass?.styleVariables.contains("--latex-abovecaptionskip: calc(5 * var(--tex-pt") == true)
        #expect(fragment.readingIssues.contains { $0.contains("intextsep") })
    }

    @Test("和文クラスは全角の整数倍で行長と版面を求める")
    func japaneseClasses() throws {
        for (paper, size, js, jlreq) in [
            ("a4paper", 10, [71.93, 71.93, 112.29, 95.12], [78.46, 78.46, 109.91, 112.30]),
            ("a4paper", 11, [75.71, 75.71, 109.15, 90.35], [78.46, 78.46, 106.75, 109.38]),
            ("a4paper", 12, [76.54, 76.54, 117.51, 96.90], [76.47, 76.47, 108.68, 111.55]),
            ("letterpaper", 10, [75.69, 75.69, 103.29, 86.11], [76.86, 76.86, 101.90, 104.29]),
            ("letterpaper", 11, [73.98, 73.98, 110.39, 91.58], [81.34, 81.34, 100.44, 103.07]),
            ("letterpaper", 12, [73.84, 73.84, 111.69, 91.08], [78.85, 78.85, 104.05, 106.92]),
        ] {
            for cls in ["jsarticle", "ltjsarticle", "jlreq"] {
                check(try box(cls, "\(paper),\(size)pt"), margins: cls == "jlreq" ? jlreq : js)
            }
        }
        let page = try box("ltjsarticle", "")
        #expect(abs(page.textWidth - 451.417) < 0.005)
    }

    @Test("geometry の指定順と内外・上下の組、総高さに含む柱を反映する")
    func geometry() throws {
        let asymmetric = try box(
            "article", "twoside", #"\usepackage[inner=32mm,outer=19mm,vmargin={22mm,26mm}]{geometry}"#)
        check(asymmetric, margins: [90.71, 53.86, 62.36, 73.70])
        #expect(asymmetric.mirrorsSides)
        let centered = try box("article", "11pt", #"\usepackage{geometry}\geometry{total={112mm,165mm},centering}"#)
        check(centered, margins: [147.26, 147.26, 162.14, 162.14])
        let paper = try box("article", "a4paper", #"\usepackage[textheight=180mm,textwidth=105mm]{geometry}"#)
        check(paper, margins: [148.82, 148.82, 132.66, 198.99])
        let headfoot = try box("article", "letterpaper", #"\usepackage[margin=1in,includeheadfoot]{geometry}"#)
        check(headfoot, margins: [72, 72, 108.86, 101.89])
    }

    @Test("用紙と余白のレジスターは一インチの原点から組み、代入した本文の高さを保つ")
    func lengths() throws {
        let result = try box(
            "article", "a4paper",
            #"""
            \paperwidth=500bp\setlength{\paperheight}{700bp}
            \setlength{\oddsidemargin}{-12bp}\textwidth=240bp\topmargin=-5bp
            \headheight=10bp\setlength{\headsep}{13bp}\footskip=31bp\textheight=400bp
            """#)
        check(result, margins: [60, 200, 90, 210])
        #expect(abs(result.paperWidth - 500) < 0.001)
        #expect(abs(result.paperHeight - 700) < 0.001)
        #expect(abs(result.footSkip - 31) < 0.001)
        let b5 = try box("jsarticle", "b5paper", #"\usepackage[margin=10mm]{geometry}"#)
        #expect(abs(b5.paperWidth - 515.9055) < 0.001)
    }
}
