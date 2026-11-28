import Foundation
import SurimonoFormats
import Testing

struct LaTeXConversionReportTests {
    private func report(
        _ source: String, readFile: @escaping @Sendable (URL) -> Data? = { _ in nil }
    ) -> (fragment: HTMLFragment, report: LaTeXConversionReport) {
        let url = URL(fileURLWithPath: "/virtual/paper/main.tex")
        let result = LaTeXConverter.convertWithReport(source, documentURL: url, readFile: readFile)
        // Asking for the report changes nothing on the page or in the print check.
        #expect(result.fragment == LaTeXConverter.convert(source, documentURL: url, readFile: readFile))
        return result
    }

    @Test("未知の命令と環境を、文の解釈なしに種類と名前で報告する")
    func unknownNames() {
        let result = report(
            #"\documentclass{article}\begin{document}\affilx{A} \begin{deluxething}x\end{deluxething}\end{document}"#)
        let unknown = result.report.diagnostics.filter { [.unknownCommand, .unknownEnvironment].contains($0.kind) }
        #expect(unknown.map(\.name) == [#"\affilx"#, "deluxething"])
        #expect(unknown.map(\.kind) == [.unknownCommand, .unknownEnvironment])
    }

    @Test("読めなかった入力は、TeX が足す拡張子つきの参照として報告する")
    func unreadInput() {
        let result = report(#"\documentclass{article}\begin{document}\input{chapters/missing}\end{document}"#)
        let files = result.report.diagnostics.filter { $0.kind == .unreadFile }
        #expect(files.map(\.name) == ["chapters/missing.tex"])
        #expect(files.first?.detail == result.fragment.readingIssues.first)
    }

    @Test("描けない数式は、文書の定義の検査で断られたか、構文で失敗したかを分けて報告する")
    func formulaCauses() {
        let result = report(
            #"""
            \documentclass{article}\newcommand{\R}{x}
            \begin{document}$\R \surimonoNoSuchCommand$ and $\frac{1}$\end{document}
            """#)
        let formulas = result.report.diagnostics.filter { $0.kind == .formula }
        #expect(formulas.count == 2)
        #expect(formulas.first?.formula == .boundRefused(command: #"\surimonoNoSuchCommand"#))
        #expect(formulas.first?.name.hasPrefix("$") == true)
        #expect(formulas.last?.formula?.code == "parse")
    }

    @Test("長い本文の前で短いマクロを何度も展開すると、本文を動かす作業量の上限で止まり、そのマクロに計上する")
    func workBudget() {
        let tail = String(repeating: "Plain words for the remaining paper. ", count: 12_000)
        let calls = String(repeating: #"\x "#, count: 400)
        let result = report(
            #"\documentclass{article}\newcommand{\x}{y}\begin{document}"# + calls + tail + #"\end{document}"#)
        let budget = result.report.budget
        #expect(budget.stop?.limit == .work)
        #expect(budget.stop?.site == "insertExpansion(_:)")
        #expect(budget.stop?.macro == #"\x"#)
        #expect(budget.heaviest.first?.command == #"\x"#)
        #expect(result.fragment.readingIssues.last == "LaTeX expansion limit reached")
        #expect(result.report.diagnostics.last?.kind == .expansionLimit)
        #expect(result.report.diagnostics.last?.name == "work")
    }

    @Test("自分を二重に呼ぶ定義は上限で止まり、止めた段と最後に展開したマクロを記録する")
    func recursiveDefinition() {
        let result = report(#"\documentclass{article}\def\a{\a\a}\begin{document}\a\end{document}"#)
        let stop = result.report.budget.stop
        #expect(stop != nil)
        #expect(stop?.macro == #"\a"#)
        #expect(stop?.command == #"\a"#)
        #expect(result.report.budget.calls > 0)
        #expect(result.fragment.readingIssues.contains("LaTeX expansion limit reached"))
    }

    @Test("上限に達しない文書は止まった記録を持たず、診断にも上限を出さない")
    func noStop() {
        let result = report(#"\documentclass{article}\newcommand{\x}{y}\begin{document}\x\x\end{document}"#)
        #expect(result.report.budget.stop == nil)
        #expect(result.report.budget.mathStop == nil)
        #expect(result.report.budget.heaviest.first?.command == #"\x"#)
        #expect(result.report.budget.heaviest.first?.calls == 2)
        #expect(!result.report.diagnostics.contains { $0.kind == .expansionLimit })
    }
}
