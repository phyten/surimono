import Foundation
import SurimonoFormats
import Testing

struct LaTeXGraphicBoxTests {
    @Test("塗った罫線・持ち上げ量・高さや幅だけの支柱を保つ")
    func rules() {
        let result = LaTeXConverter.convert(#"\rule[2pt]{.25\linewidth}{1mm}\fbox{\rule{0pt}{3cm}\rule{5cm}{0pt}}"#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("width: 25%; height: calc(2.84527559"))
        #expect(result.body.contains("vertical-align: calc(2 * var(--tex-pt"))
        #expect(result.body.contains("width: calc(0 * var(--tex-pt, 0.996264pt)); height: calc(85.3582677"))
        #expect(result.body.contains("width: calc(142.26378 * var(--tex-pt, 0.996264pt)); height: calc(0"))
        #expect(result.body.components(separatedBy: "background: currentColor").count == 4)
    }

    @Test("表のセル内の改行と列区切りは内側の表に属し外側最終罫が全列にかかる")
    func nestedTabular() {
        let result = LaTeXConverter.convert(
            #"\begin{tabular}{ll}A&B\\C&\begin{tabular}[t]{lr}i&ii\\iii&iv\end{tabular}\\\hline\end{tabular}"#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.components(separatedBy: "<table").count == 3)
        #expect(result.body.components(separatedBy: "<tr>").count == 5)
        #expect(result.body.components(separatedBy: "border-bottom: 0.5pt solid currentColor").count == 3)
        #expect(result.body.contains("currentColor\">C</td><td style=\"text-align: start; border-bottom:"))
        #expect(result.body.contains(">iv</td></tr>"))
    }

    @Test("伸びる空きの両側の色付き段落箱・寸法のある枠・通常の枠をひとつの行に置く")
    func alignedBoxes() {
        for (left, right) in [
            (#"\fbox{左}"#, #"\fbox{右}"#),
            (#"\colorbox{yellow}{\parbox{.4\linewidth}{左}}"#, #"\fbox{\begin{minipage}{.4\linewidth}右\end{minipage}}"#),
            (#"\fbox{左}"#, #"\begin{minipage}{.4\linewidth}右\end{minipage}"#),
        ] {
            let html = LaTeXConverter.convert(left + "\n\\hfill " + right).body
            #expect(html.components(separatedBy: "latex-box-row").count == 2)
            #expect(html.contains("latex-box-row latex-box-fill"))
            #expect(html.contains("左") && html.contains("右"))
        }
    }

    @Test("表の指定幅と縦横倍率は内容を一度だけ処理して印刷時の計測に渡す")
    func scaledBoxes() {
        let html = LaTeXConverter.convert(
            #"\resizebox{.8\linewidth}{!}{\begin{tabular}{c}枠内\end{tabular}}本文\scalebox{2}[.75]{文字}"#
        ).body
        #expect(
            html.contains(
                #"<div class="latex-graphic-box" data-latex-transform="1 1 0" style="--latex-target-width: 80%"><div class="latex-graphic-content"><table"#
            ))
        #expect(html.contains(#"<span class="latex-graphic-box" data-latex-transform="2 0.75 0""#))
        #expect(html.components(separatedBy: "枠内").count == 2)
    }

    @Test("画像の切り抜きは左下右上の順で解像度込みの自然寸法と一緒に渡す")
    func trimmedImage() {
        let html = LaTeXConverter.convert(
            #"\includegraphics[trim={2bp 1in 0 4bp},clip,width=20mm]{pic.png}"#,
            directory: URL(fileURLWithPath: "/fixture"), imageExists: { _ in true },
            imageSizeInPoints: { _ in CGSize(width: 100, height: 200) }
        ).body
        #expect(html.contains(#"data-latex-crop="2 72 0 4""#))
        #expect(html.contains(#"data-latex-intrinsic="100 200""#))
        #expect(html.contains("--latex-target-width: calc(56.9055118"))
    }

    @Test("横向き環境は選択用紙に正立した内容を保ち未知環境の確認を出さない")
    func landscape() {
        let result = LaTeXConverter.convert(#"\begin{landscape}\section*{幅の確認}\rule{.9\linewidth}{2pt}\end{landscape}"#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("幅の確認</h2>"))
        #expect(result.body.contains("width: 90%"))
    }
}
