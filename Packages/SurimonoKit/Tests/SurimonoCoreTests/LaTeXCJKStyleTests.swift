import Foundation
import SurimonoFormats
import Testing

@testable import SurimonoCore

struct LaTeXCJKStyleTests {
    @Test(
        "中国語と韓国語の見出しは欧文クラスでは本文書体、専用クラスやパッケージでは見出し書体を選ぶ",
        arguments: [
            ("article", #"\setmainfont{Songti SC}\XeTeXlinebreaklocale "zh""#, false),
            ("article", #"\setmainfont{AppleMyungjo}\XeTeXlinebreaklocale "ko""#, false),
            ("ctexart", "", true), ("article", #"\usepackage{kotex}"#, true), ("oblivoir", "", true),
        ])
    func headingFamily(_ fixture: (String, String, Bool)) throws {
        let (className, preamble, nativeHeadings) = fixture
        let fragment = LaTeXConverter.convert(
            #"\documentclass{\#(className)}\#(preamble)\begin{document}\title{春}\maketitle\section{一}月\end{document}"#)
        let info = try #require(fragment.latexClass)
        let id = PrintThemeLibrary.defaultLaTeXStyle(for: info)
        let style = try #require(PrintThemeLibrary.load().first { $0.id == id })
        let page = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: style)
        let body = try #require(page.components(separatedBy: "<body ").last)
        #expect(body.contains(" data-latex-native-headings") == nativeHeadings)
        #expect(
            style.css.contains("body[data-latex-native-headings] :is(h1, h2, h3, h4, h5, h6, .latex-contents-title)"))
    }

    @Test("康熙部首と字形が共通の明朝・宋体には漢字だけの代替書体を置き、原文中の部首を保つ")
    func songCharacters() throws {
        let text = "月日目木用高面手文⽉"
        for (face, alias) in [
            ("Songti SC", "Song SC"), ("Songti TC", "Song TC"), ("YuMincho", "Mincho"), ("HiraMinProN-W3", ""),
            ("Yu Mincho", "Mincho"), ("游明朝", "Mincho"), ("Custom", ""),
        ] {
            let fragment = LaTeXConverter.convert(
                #"\documentclass{article}\setmainfont{\#(face)}\begin{document}\#(text)\end{document}"#)
            #expect(fragment.body.contains(text))
            let info = try #require(fragment.latexClass)
            #expect(info.styleVariables.contains(" Ideographs") == !alias.isEmpty)
            if !alias.isEmpty { #expect(info.styleVariables.contains("Surimono \(alias) Ideographs")) }
        }
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-zh" })
        let page = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(text), format: .latex, theme: style)
        let unified = (0x2F00...0x2FD5).compactMap { UnicodeScalar($0) }.map {
            String($0).precomposedStringWithCompatibilityMapping
        }
        let range = try #require(page.firstMatch(of: /unicode-range: (U\+4E00,[^;]+);/))
        let declared = Set(range.1.split(separator: ",").compactMap { UInt32($0.dropFirst(2), radix: 16) })
        #expect(declared == Set(unified.flatMap { $0.unicodeScalars.map(\.value) }))
        #expect(declared.count == 214)
    }

    @Test("和文の反復で作った箱の数字は原文を維持し、専用スタイルの和欧混植を継承する")
    func boxedNumbers() throws {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{jsarticle}\begin{document}\foreach \n in {1,2}{\fbox{確認\n}}\end{document}"#)
        #expect(fragment.body.contains("確認1") && fragment.body.contains("確認2"))
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        #expect(style.css.contains("text-autospace: ideograph-alpha ideograph-numeric; text-autospace-size: 0.25;"))
    }
}
