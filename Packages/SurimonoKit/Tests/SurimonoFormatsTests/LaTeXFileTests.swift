import Foundation
import SurimonoFormats
import Testing

struct LaTeXFileTests {
    private func withProject(
        _ files: [String: String], check: (URL) throws -> Void
    ) throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: folder) }
        for (name, text) in files {
            let url = folder.appending(path: name)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try check(folder.appending(path: "main.tex"))
    }

    private func convert(_ file: URL) throws -> HTMLFragment {
        LaTeXConverter.convert(
            try String(contentsOf: file, encoding: .utf8), documentURL: file,
            imageExists: { FileManager.default.fileExists(atPath: $0.path) },
            readFile: { try? Data(contentsOf: $0) },
            modificationDate: { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        )
    }

    @Test("前置きの入力と章からの相対入力を本文に差し込み includeonly で選んだ章だけを改ページする")
    func nestedInputs() throws {
        try withProject([
            "main.tex": #"""
            \documentclass{article}\input{defs}\includeonly{chapters/one}
            \begin{document}\include{absent}\include{chapters/one}\import{appendix}{extra}
            \subfile{standalone}\input{tail}{Next}\end{document}
            """#,
            "defs.tex": #"\newcommand{\greet}{Hello}"#,
            "chapters/one.tex": #"\greet{} \input{sub/two} \includegraphics{chart}"#,
            "chapters/sub/two.tex": #"\input{local} \input{mainonly}"#,
            "chapters/local.tex": "Nested", "mainonly.tex": "MainOnly", "chapters/chart.svg": "",
            "appendix/extra.tex": "Appendix", "tail.tex": #"\textbf"#,
            "standalone.tex": #"\documentclass{subfiles}\begin{document}SubBody\end{document}ignore"#,
        ]) { file in
            let fragment = try convert(file)
            #expect(fragment.readingIssues.isEmpty)
            for text in ["Hello", "Nested", "MainOnly", "Appendix", "SubBody", "<strong>Next</strong>"] {
                #expect(fragment.body.contains(text))
            }
            #expect(fragment.body.contains(#"src="chapters/chart.svg""#))
            #expect(fragment.body.components(separatedBy: "latex-pagebreak").count == 2)
            #expect(!fragment.body.contains("ignore"))
        }
    }

    @Test("入力先だけに文書境界があるときも和文クラスを読み、行末のコメントは親の本文に及ばない")
    func inputDocument() throws {
        try withProject([
            "main.tex": #"\input{wrapper}"#,
            "wrapper.tex":
                #"\documentclass{jsarticle}\begin{document}\input{comment}後続\begin{figure}\caption{題}\end{figure}\end{document}ignored"#,
            "comment.tex": "% skip to the end of this file",
        ]) { file in
            let fragment = try convert(file)
            #expect(fragment.readingIssues.isEmpty)
            #expect(fragment.body.contains("後続"))
            #expect(fragment.body.contains("図 1"))
            #expect(!fragment.body.contains("ignored"))
        }
    }

    @Test("入力の循環をそこで止め、別の参照元からは同じファイルを読み直せる")
    func cycle() throws {
        try withProject(["main.tex": #"\input{a}\input{a}Tail"#, "a.tex": #"Alpha\input{main}"#]) { file in
            let fragment = try convert(file)
            #expect(fragment.body.components(separatedBy: "Alpha").count == 3)
            #expect(fragment.body.contains("Tail"))
            #expect(fragment.readingIssues.count == 1)
            #expect(fragment.readingIssues.first?.contains("main.tex") == true)
        }
    }

    @Test("章は深さ20まで読み、21番目の入力と見つからない前置きは枠と印刷前の確認に出す")
    func depthAndMissing() throws {
        var files = ["main.tex": #"\documentclass{jlreq}\input{missing}\begin{document}\input{1}後続\end{document}"#]
        for n in 1...20 { files["\(n).tex"] = "章[\(n)]\\input{\(n + 1)}" }
        files["21.tex"] = "TooDeep"
        try withProject(files) { file in
            let fragment = try convert(file)
            #expect(fragment.body.contains("章[20]"))
            #expect(!fragment.body.contains("TooDeep"))
            #expect(fragment.body.contains("後続"))
            #expect(fragment.body.contains("missing.tex を読み込めません"))
            #expect(fragment.readingIssues.contains("ファイル 21.tex を読み込めません"))
        }
    }

    @Test("外部ファイルとマクロが同じ文字予算を使い、上限に達しても後続の本文を残す")
    func sharedBudget() throws {
        try withProject([
            "main.tex": #"\newcommand{\repeatme}{0123456789}\input{large}\repeatme{}Tail"#,
            "large.tex": "%" + String(repeating: "a", count: 1_999_995) + "\n",
        ]) { file in
            let fragment = try convert(file)
            #expect(fragment.readingIssues.contains("LaTeX expansion limit reached"))
            #expect(fragment.body.contains("Tail"))
            #expect(!fragment.body.contains("0123456789"))
        }
    }

    @Test("TikZ の保存名・接頭辞・標準名を調べ、図番号を進めながら古い図と未生成の図だけを知らせる")
    func externalized() throws {
        let figure = #"\begin{tikzpicture}\begin{axis}data\end{axis}\end{tikzpicture}"#
        let source =
            #"\documentclass{ltjsarticle}\tikzexternalize[prefix=fig/]\begin{document}\tikzsetnextfilename{named}"#
            + String(repeating: figure, count: 4) + #"\end{document}"#
        try withProject([
            "main.tex": source, "fig/named.svg": "", "fig/main-figure0.pdf": "",
            "fig/main-figure1.png": "", "main-figure2.pdf": "",
        ]) { file in
            let manager = FileManager.default
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
            let stale = file.deletingLastPathComponent().appending(path: "fig/named.svg")
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 50)], ofItemAtPath: stale.path)
            let fragment = try convert(file)
            #expect(fragment.body.contains(#"src="fig/named.svg""#))
            #expect(!fragment.body.contains("main-figure0"))
            #expect(fragment.body.contains(#"src="fig/main-figure1.png""#))
            #expect(fragment.body.contains(#"src="main-figure2.pdf""#))
            #expect(fragment.readingIssues.count == 4)
            #expect(fragment.readingIssues.contains { $0.contains("古い") && $0.contains("named.svg") })
            #expect(fragment.readingIssues.contains { $0.contains("図 4 (TikZ)") })
        }
    }
}
