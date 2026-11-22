import RobustnessSupport
import SurimonoFormats
import Testing

extension InstalledFontIndex {
    static let testInventory = Self(faces: [
        "Menlo": .init(family: "Menlo", postScriptName: "Menlo-Regular", bold: "Menlo-Bold"),
        "Paper Sans": .init(family: "Paper Sans", postScriptName: "PaperSans-Regular", bold: "PaperSans-Bold"),
    ])
}

struct InstalledFontIndexTests {
    @Test("固定の書体一覧から和文ファミリーの標準・太字を引き、未登録の書体には候補を足さない")
    func injectedFaces() throws {
        let source =
            #"\documentclass{ltjsarticle}\setsansjfont{PAPER SANS}\setmonojfont{Paper Mono}\begin{document}紙\end{document}"#
        let info = try #require(LaTeXConverter.convert(source, fontIndex: .testInventory).latexClass)
        #expect(
            info.localFontFaces == LaTeXConverter.documentClassInfo(source, fontIndex: .testInventory).localFontFaces)
        #expect(info.localFontFaces.contains(#"local("PaperSans-Regular"), local("PAPER SANS")"#))
        #expect(info.localFontFaces.contains(#"local("PaperSans-Bold"); font-weight: bold;"#))
        #expect(info.localFontFaces.contains(#"local("Paper Mono");"#))
        #expect(!info.localFontFaces.contains("PaperMono-Bold"))
    }

    @Test("システム書体の一覧は Helvetica を引け、存在しない名前をすぐに棄却する")
    func systemNames() throws {
        let face = try #require(InstalledFontIndex.system.face(named: "heLVeTica"))
        #expect(face.family == "Helvetica")
        #expect(InstalledFontIndex.system.face(named: face.postScriptName)?.postScriptName == face.postScriptName)
        let start = ContinuousClock.now
        #expect(InstalledFontIndex.system.face(named: "Surimono Missing Font 56D9025C") == nil)
        // Only the time is skipped under a sanitizer, which slows the code several times over.
        if !Sanitizer.isActive { #expect(start.duration(to: .now) < .seconds(1)) }
    }

    @Test("未導入の和文書体を八つ指定した文書を十回変換しても二秒以内に収まる")
    func missingFonts() {
        let declarations = (1...8).map { "\\setsansjfont{Surimono Absent Face \($0)}" }.joined(separator: "\n")
        let source = "\\documentclass[11pt]{ltjsarticle}\n" + declarations + "\n\\begin{document}紙片。\\end{document}"
        let start = ContinuousClock.now
        for _ in 0..<10 {
            #expect(LaTeXConverter.convert(source).body.contains("紙片。"))
        }
        if !Sanitizer.isActive { #expect(start.duration(to: .now) < .seconds(2)) }
    }
}
