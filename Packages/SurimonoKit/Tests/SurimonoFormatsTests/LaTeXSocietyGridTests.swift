import Foundation
import RobustnessSupport
import Testing

@testable import SurimonoFormats

struct LaTeXSocietyGridTests {
    @Test("実測した判型・版面・段間と和文の字送りを使う")
    func metrics() throws {
        // Expected lengths are PDF points from the reference pages, relative to trim.
        for (name, paper, origin, measure, gap, pitch, cells, lines) in [
            ("ipsj", [595.28, 841.89], [47.08, 64.93], [501.12, 707.36], 22.68, 14.88, 26, 48),
            ("ieicej", [515.91, 728.50], [43.23, 69.70], [429.45, 587.0], 21.26, 13.47, 24, 44),
            ("ieice", [595.28, 793.70], [48.57, 79.54], [498.13, 665.50], 22.68, 11.69, 0, 57),
        ] {
            let input = "\\documentclass{\(name)}\\begin{document}Grid.\\end{document}"
            let fragment = LaTeXConverter.convert(input)
            let info = try #require(fragment.latexClass)
            let grid = try #require(info.profile.page.fixedGrid)
            let box = info.pageBox
            let unit = 72.0 / 72.27
            #expect(info.columns == 2)
            #expect(fragment.body.contains("data-latex-columns=\"2\""))
            for (actual, expected) in zip(
                [
                    box.paperWidth, box.paperHeight, box.left, box.top, box.textWidth, box.textHeight,
                    grid.columnGap * unit, grid.pitch * unit,
                ], paper + origin + measure + [gap, pitch])
            {
                #expect(abs(actual - expected) < 0.13, "\(name): \(actual) / \(expected)")
            }
            #expect(abs((box.textHeight / unit - grid.topSkip) / grid.pitch - Double(lines - 1)) < 0.11)
            if cells > 0 {
                let scale = try #require(grid.japaneseScale)
                #expect(grid.bodySize * scale * Double(cells) <= (grid.width - grid.columnGap) / 2 + 0.00001)
                let zw = try #require(grid.characterWidth)
                #expect(abs((grid.width - grid.columnGap) / (2 * zw) - Double(cells)) < 0.05)
            }
            for key in ["body-size", "body-pitch", "parindent", "columnsep", "note-pitch"] {
                #expect(info.styleVariables.contains("--latex-\(key): calc("))
            }
        }
    }

    @Test("通常論文は段末を揃え、技報・査読原稿の指定はプリアンブルでも変更できる")
    func columnBottoms() throws {
        for (declaration, command, ragged) in [
            ("[submit]{ipsj}", "", false), ("[paper]{ieicej}", "", false), ("[paper]{ieice}", "", false),
            ("[technicalreport]{ieicej}", "", true), ("[referee]{ieice}", "", true),
            ("[technicalreport]{ieicej}", #"\flushbottom"#, false), ("[paper]{ieice}", #"\raggedbottom"#, true),
        ] {
            let tex = #"\documentclass"# + declaration + command + #"\begin{document}Text.\end{document}"#
            let info = try #require(LaTeXConverter.convert(tex).latexClass)
            #expect(info.raggedColumns == ragged)
        }
    }

    @Test("学会の別行数式は段左の字下げと式番号の余白を持ち、浮動表には本文と別の行送りがある")
    func displayAndFloatRegisters() throws {
        for (name, size, indent, inset, pitch, rule) in [
            ("ipsj", "footnotesize", 9.21, 8.50, 12.76, 0.3985),
            ("ieicej", "small", 8.50, 8.50, 9.21, 0.2835),
            ("ieice", "footnotesize", 19.84, 0.0, 9.57, 0.3985),
        ] {
            let source =
                "\\documentclass{\(name)}" + #"""
                    \begin{document}
                    \begin{equation}x=y\end{equation}
                    \begin{table}\begin{tabular}{|c|}\hline A\\ \hline\end{tabular}\end{table}
                    \end{document}
                    """#
            let fragment = LaTeXConverter.convert(source)
            let grid = try #require(fragment.latexClass?.profile.page.fixedGrid)
            #expect(fragment.body.contains("data-latex-float-size=\"\(size)\""))
            #expect(fragment.body.contains("latex-top-hline"))
            #expect(fragment.body.contains("border-left: var(--latex-arrayrulewidth"))
            #expect(fragment.body.contains("border-right: var(--latex-arrayrulewidth"))
            #expect(fragment.body.contains(#"class="eqno">(1)</span>"#))
            for (actual, expected) in [
                (grid.indent, indent), (grid.tagInset, inset), (grid.floatPitch, pitch), (grid.ruleWidth, rule),
            ] {
                #expect(abs(actual * 72 / 72.27 - expected) < 0.01)
            }
        }
    }

    @Test("英語の各地域で入れ子の書体指定の端にある細い空白を落とさない", arguments: ["english", "british", "american"])
    func spaceInFontArgument(language: String) {
        let source = #"""
            \documentclass{article}\usepackage[\#(language)]{babel}
            \begin{document}\textit{1\,}mm and 2~mm.\end{document}
            """#
        let html = LaTeXConverter.convert(source).body
        #expect(html.contains("<em>1<span data-latex-thin-space>\u{2009}</span></em>mm"), "\(html)")
        #expect(DocumentOutline.plainText(ofHTML: html).contains("1\u{2009}mm and 2\u{00A0}mm."))
        #expect(html.contains("2&nbsp;mm"))
    }

    @Test("表の下罫までの深さは最終行のセルに一度だけ確保する")
    func closingRuleDepth() {
        let tables = #"""
            \begin{tabular}{ll}\hline \multirow{2}{*}{Span}&First\\ \hline &Last\\ \hline\end{tabular}
            \begin{tabular}{l}Open\\\end{tabular}
            """#
        for name in ["ipsj", "ieicej", "ieice"] {
            let html = LaTeXConverter.convert("\\documentclass{\(name)}\\begin{document}\(tables)\\end{document}").body
            #expect(html.components(separatedBy: "latex-rule-depth").count == 2)
            #expect(html.contains(#">Last<span class="latex-rule-depth" aria-hidden="true"></span></td>"#))
        }
    }

    @Test("学会クラス名・パッケージ・文献スタイルを解決するために周辺ファイルを開かない")
    func companionFiles() {
        for name in ["ipsj", "ieicej", "ieice"] {
            let requests = Locked<[URL]>([])
            let tex =
                "\\documentclass{\(name)}" + #"\usepackage{newtxtext}\bibliographystyle{local}"#
                + #"\begin{document}Body.\end{document}"#
            let result = LaTeXConverter.convert(
                tex, documentURL: URL(fileURLWithPath: "/sample/main.tex"),
                readFile: {
                    requests.value.append($0)
                    return nil
                })
            #expect(result.body.contains("Body."))
            #expect(requests.value.isEmpty)
        }
    }

    @Test("学会の投稿区分は題字・言語・判型・英文要旨の有無を決める")
    func options() {
        for (name, option, title) in [
            ("ipsj", "technote", "テクニカルノート"), ("ipsj", "invited", "招待論文"),
            ("ieicej", "letter", "研究速報"), ("ieicej", "electronicsletter", "レター"),
            ("ieicej", "invited", "招待論文"), ("ieicej", "comment", "解説論文"), ("ieicej", "survey", "サーベイ論文"),
            ("ieice", "position", "POSITION PAPER"), ("ieice", "letter", "LETTER"), ("ieice", "brief", "BRIEF PAPER"),
            ("ieice", "invited", "INVITED PAPER"), ("ieice", "review", "REVIEW PAPER"),
            ("ieice", "tutorial", "TUTORIAL PAPER"), ("ieice", "survey", "SURVEY PAPER"),
        ] {
            #expect(LaTeXDocumentClassInfo(name: name, options: option).profile.titleBlock.paperTypeLabel == title)
        }
        for option in ["english", "JIP", "preprint"] {
            #expect(LaTeXDocumentClassInfo(name: "ipsj", options: option).mainLanguage == "en")
        }
        #expect(LaTeXDocumentClassInfo(name: "ieicej", options: "technicalreport").profile.page.forcedPaper == .a4)
        #expect(
            LaTeXDocumentClassInfo(name: "ieicej", options: "cameraready").profile.titleBlock.omitsEnglishSupplement)
        #expect(LaTeXDocumentClassInfo(name: "ieice", options: "referee").columns == 1)
    }
}
