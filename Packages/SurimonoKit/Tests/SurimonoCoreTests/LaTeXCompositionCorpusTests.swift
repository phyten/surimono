import Foundation
import SurimonoCore
import Testing

struct LaTeXCompositionCorpusTests {
    @Test(
        "五つの実原稿で2段組の本文・紙面・柱・HTMLの全属性がクラス指定と一致する",
        arguments: [
            "001-survey", "002-chapter-map", "003-parts", "101-jsarticle-page-edge", "111-ltjarticle-plain",
        ])
    func twoColumns(folder: String) throws {
        let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let url = root.appendingPathComponent("Snapshots/corpus/latex/\(folder)/main.tex")
        let source = try String(contentsOf: url, encoding: .utf8)
        let explicit =
            source.contains(#"\documentclass["#)
            ? source.replacingOccurrences(of: #"\documentclass["#, with: #"\documentclass[twocolumn,"#)
            : source.replacingOccurrences(of: #"\documentclass{"#, with: #"\documentclass[twocolumn]{"#)
        let selected = LaTeXConverter.convert(source, composition: .twoColumn, documentURL: url)
        let written = LaTeXConverter.convert(explicit, documentURL: url)
        let info = try #require(selected.latexClass)
        let expected = try #require(written.latexClass)
        #expect(info.columns == 2 && info.offersCompositionChoice)
        #expect(!expected.offersCompositionChoice)
        #expect(selected == written)
        #expect(selected.body == written.body)
        #expect(info.pageBox == expected.pageBox)
        #expect(info.pageNumbers == expected.pageNumbers)
        let theme = try #require(
            PrintThemeLibrary.load().first { $0.id == PrintThemeLibrary.defaultLaTeXStyle(for: info) })
        let html = HTMLDocumentBuilder.build(fragment: selected, format: .latex, theme: theme)
        #expect(html == HTMLDocumentBuilder.build(fragment: written, format: .latex, theme: theme))
        let proof = LaTeXConverter.convert(source, composition: .proof)
        #expect(
            HTMLDocumentBuilder.build(fragment: proof, format: .latex, theme: theme).contains(
                #"data-latex-review="proofPageLines""#))
    }
}
