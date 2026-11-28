import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXTraditionalJapaneseTests {
    private func sameRules(_ lhs: LaTeXClassProfile, _ rhs: LaTeXClassProfile) -> Bool {
        lhs.structure == rhs.structure && lhs.page == rhs.page && lhs.typography == rhs.typography
            && lhs.headings == rhs.headings && lhs.titleBlock == rhs.titleBlock && lhs.body == rhs.body
            && lhs.pageStyle == rhs.pageStyle && lhs.usesGridFlow == rhs.usesGridFlow
            && lhs.frontMatter == rhs.frontMatter && lhs.classCommands == rhs.classCommands
    }

    @Test(
        "upLaTeX の uj クラスは対応する pLaTeX のクラスと同じ決まりで組む",
        arguments: [("ujarticle", "jarticle"), ("ujreport", "jreport"), ("ujbook", "jbook")])
    func upLaTeXMatchesPLaTeX(pair: (String, String)) {
        for options in ["", "a4paper,11pt", "twoside,openany", "titlepage,twocolumn"] {
            let up = LaTeXDocumentClassInfo(name: pair.0, options: options).profile
            let p = LaTeXDocumentClassInfo(name: pair.1, options: options).profile
            #expect(sameRules(up, p), "\(pair.0) [\(options)]")
        }
    }

    @Test("ltjreport は jreport と同じ決まりで、箇条書きの黒丸だけを Latin Modern で刷る")
    func luaTeXReportMatchesPLaTeX() {
        let lua = LaTeXDocumentClassInfo(name: "ltjreport", options: "11pt").profile
        let p = LaTeXDocumentClassInfo(name: "jreport", options: "11pt").profile
        var body = lua.body
        #expect(body.usesLatinModernBullet)
        body.usesLatinModernBullet = false
        #expect(body == p.body)
        #expect(lua.structure == p.structure && lua.page == p.page && lua.typography == p.typography)
        #expect(lua.headings == p.headings && lua.pageStyle == p.pageStyle)
    }

    @Test("report 系は題名を独立したページに置き、片面で、記事と同じ版面と「第 n 章」の見出しを使う", arguments: ["jreport", "ujreport", "ltjreport"])
    func reportRules(name: String) {
        let profile = LaTeXDocumentClassInfo(name: name).profile
        #expect(profile.structure.titlePage == .separate)
        #expect(profile.page.layoutRule == .standard(.traditionalArticle))
        #expect(!profile.page.twoSidedBox && !profile.pageStyle.twoSidedNumbers)
        #expect(profile.structure.bookOpening == nil)
        #expect(profile.headings.chapterLabel == .traditionalJapaneseNumber)
        #expect(profile.structure.formatsContentsChapterNames)
        #expect(profile.typography.followsJClassesSizeFiles)
    }

    @Test("report 系の目次の章は「第 n 章」の番号を載せる", arguments: ["jreport", "ujreport", "ltjreport"])
    func reportContentsNumbers(name: String) {
        let tex = "\\documentclass{\(name)}\\begin{document}\\tableofcontents\\chapter{棚}\\end{document}"
        let body = LaTeXConverter.convert(tex).body
        #expect(body.contains(##"<a href="#sec-1"><span class="secnum">第 1 章</span>棚</a>"##))
    }
}
