import Foundation
import Testing

@testable import SurimonoCore

@Suite(.timeLimit(.minutes(1)))
struct ResourceLimitTests {
    @Test("表の入れ子は32段で止まり残りの原文を文字として残す")
    func nestedTableWrappers() {
        for command in [#"\multicolumn{1}{c}{"#, #"\multirow{1}{*}{"#] {
            let source = String(repeating: command, count: 256) + "<本文>" + String(repeating: "}", count: 256)
            let html = LaTeXTable(spec: "c", body: source).html { _ in "通常の変換" }
            #expect(html.contains(command))
            #expect(html.contains("&lt;本文&gt;"))
        }
    }

    @Test("Orgの深いリストは32段で止まり最深部の本文を残す")
    func nestedOrgLists() {
        let source = (0..<160).map { String(repeating: "  ", count: $0) + "- 本文\($0)" }.joined(separator: "\n")
        let html = OrgConverter.convert(source).body
        #expect(html.components(separatedBy: "<ul>").count - 1 == 32)
        #expect(html.contains("本文159"))
        #expect(html.components(separatedBy: "</ul>").count - 1 == 32)
    }

    @Test("一行のOrgリスト入れ子も深さ制限を迂回しない")
    func compactOrgLists() {
        let html = OrgConverter.convert(String(repeating: "- ", count: 2000) + "最後").body
        #expect(html.components(separatedBy: "<ul>").count - 1 == 32)
        #expect(html.contains("最後"))
    }

    @Test("多数の閉じないOrg領域でも末尾の見出しを保持して処理を終える")
    func unclosedOrgRegions() {
        let source = (0..<4000).map { "#+begin_missing\($0)\n:drawer\($0):" }.joined(separator: "\n")
        let html = OrgConverter.convert(source + "\n* 最後の見出し").body
        #expect(html.contains("#+begin_missing3999"))
        #expect(html.contains("<h1>最後の見出し</h1>"))
    }

    @Test("多数の脚注も初出順と繰り返し参照の番号を保つ")
    func manyFootnotes() {
        let count = 20000
        let notes = MarkdownExtensions.Footnotes(
            definitions: Dictionary(
                uniqueKeysWithValues: (0..<count).map {
                    ("n\($0)", "注\($0)")
                }))
        let source = (0..<count).reversed().map { "[^n\($0)]" }.joined(separator: " ")
        let html = MarkdownExtensions.rewriteInline(
            [source, "[^N19999] [^n0] [^unknown]"], footnotes: notes,
            formulas: MarkdownExtensions.Formulas())
        for index in 0..<count { #expect(notes.number(of: "n\(index)") == count - index) }
        #expect(notes.order.first == "n19999")
        #expect(notes.order.last == "n0")
        #expect(html[1].contains("id=\"fnref-1-2\">1</a>"))
        #expect(html[1].contains("id=\"fnref-20000-2\">20000</a>"))
        #expect(html[1].contains("[^unknown]"))
    }
}
