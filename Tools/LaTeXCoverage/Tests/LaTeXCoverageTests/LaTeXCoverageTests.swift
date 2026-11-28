import Foundation
import Testing

@testable import LaTeXCoverageCore

struct LaTeXCoverageTests {
    private func withFolder(_ files: [String: String], check: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: "latex-coverage-" + UUID().uuidString)
        defer { try? manager.removeItem(at: folder) }
        for (name, text) in files {
            let url = folder.appending(path: name)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try check(folder)
    }

    @Test("主ファイルは文書クラスと本文の始まりを持つファイルで、入力するだけの入口のファイルは選ばない")
    func mainFile() throws {
        try withFolder([
            "main.tex": #"\input{latex/paper.tex}"#,
            "latex/paper.tex": #"\documentclass{article}\begin{document}Body\end{document}"#,
            "latex/figure.tex": #"\documentclass{standalone}"#,
            "notes.tex": "% \\documentclass{article}\n\\begin{document}",
        ]) { folder in
            #expect(Manuscripts.mainFile(in: folder) == "latex/paper.tex")
        }
    }

    @Test("同じ条件の候補では大きい方を選ぶ")
    func largerMain() throws {
        try withFolder([
            "a.tex": #"\documentclass{article}\begin{document}A\end{document}"#,
            "b.tex": #"\documentclass{article}\begin{document}A longer body\end{document}"#,
        ]) { folder in
            #expect(Manuscripts.mainFile(in: folder) == "b.tex")
        }
    }

    @Test("論文ごとの記録の manifest を読み、tex でない論文を除き、src の下のフォルダーを指す")
    func keyedManifest() throws {
        try withFolder([
            "manifest.json": #"""
            {"2601.00001": {"group": "math", "year": 2026, "main": "ms.tex", "status": "tex"},
             "2601.00002": {"group": "math", "year": 2026, "status": "pdfonly"}}
            """#,
            "src/2601.00001/ms.tex": "",
        ]) { folder in
            let papers = try Manuscripts.list(corpus: folder, manifest: nil)
            #expect(
                papers == [
                    Manuscript(id: "2601.00001", folder: "src/2601.00001", main: "ms.tex", group: "math", year: 2026)
                ])
        }
    }

    @Test("manifest がなければ主ファイルを持つフォルダーごとに 1 本の論文とする")
    func discovered() throws {
        try withFolder([
            "one/main.tex": #"\documentclass{article}\begin{document}\end{document}"#,
            "two/sub/paper.tex": #"\documentclass{article}\begin{document}\end{document}"#,
            "empty/readme.txt": "",
        ]) { folder in
            let papers = try Manuscripts.list(corpus: folder, manifest: nil)
            #expect(papers.map(\.id) == ["one", "two"])
            #expect(papers.map(\.main) == ["main.tex", "sub/paper.tex"])
        }
    }

    @Test("紙面の数え方: 論文のフォルダーの外の画像とない画像は見つからない画像、EPS は別に数える")
    func pageCounts() throws {
        try withFolder(["paper/fig.eps": "", "paper/fig.png": "", "outside.png": ""]) { folder in
            let paper = folder.appending(path: "paper")
            let body = #"""
                <img src="fig.png"><img src="fig.eps"><img src="missing.png"><img src="../outside.png">
                <img src="data:image/png;base64,AA"><span class="math-error">x</span>
                <div class="latex-unsupported" data-latex-picture data-issue="Figure 1 — tikz: option 3 is not drawn"></div>
                """#
            let counts = PageCounts(html: body, mainFolder: paper, paperFolder: paper)
            #expect(counts.imagesMissing == 2)
            #expect(counts.imagesEPS == 1)
            #expect(counts.formulasAsSource == 1)
            #expect(counts.frames == 1)
            #expect(counts.pictureReasons == ["Figure 1 — tikz: option 3 is not drawn"])
            #expect(PageCounts.reasonKey(counts.pictureReasons[0]) == "tikz: option N is not drawn")
        }
    }

    private func record(_ id: String, notes: [DocumentRecord.Diagnostic], outcome: DocumentRecord.Outcome = .ok)
        -> DocumentRecord
    {
        var record = DocumentRecord(id: id, main: "main.tex", outcome: outcome)
        record.diagnostics = notes
        return record
    }

    @Test("注記は名前・ファイル・数式・上限を 1 件ずつ数え、図の代わりの画像の注記は理由で 1 件にする")
    func notes() {
        var paper = record(
            "p",
            notes: [
                .init(kind: "unknownCommand", name: #"\affil"#), .init(kind: "unknownEnvironment", name: "algorithm"),
                .init(kind: "unreadFile", name: "refs.bib", detail: "refs.bib could not be read"),
                .init(kind: "fileNote", name: "Figure 2 — drawn from an image"),
                .init(kind: "formula", name: "$x$", cause: "parse"), .init(kind: "expansionLimit", name: "math"),
            ])
        paper.page.pictureReasons = ["Figure 2 — drawn from an image"]
        paper.page.imagesEPS = 2
        #expect(
            paper.noteKeys == [
                #"cmd:\affil"#, "env:algorithm", "file:bib", "math", "limit", "tikz:drawn from an image", "img:eps",
                "img:eps",
            ])
        #expect(record("t", notes: [.init(kind: "formula", name: "$x$")], outcome: .timeout).notes == 0)
    }

    @Test("集計は時間切れの論文を分母に残し、注記ゼロや 3 件以内には数えない")
    func summary() {
        let formula = DocumentRecord.Diagnostic(kind: "formula", name: "$x$", cause: "bound-refused", command: #"\ell"#)
        let records = [
            record("a", notes: []), record("b", notes: [formula, formula]),
            record("c", notes: Array(repeating: formula, count: 5)), record("d", notes: [], outcome: .timeout),
        ]
        let summary = CoverageSummary(records)
        #expect(summary.papers == 4)
        #expect(summary.zeroNotes == 1)
        #expect(summary.atMostThree == 2)
        #expect(summary.medianNotes == 2)
        #expect(summary.outcomes == ["ok": 3, "timeout": 1])
        #expect(summary.refusedMathCommands.first == .init(name: #"\ell"#, documents: 2, occurrences: 7))
        #expect(summary.formulaCauses.first?.name == "bound-refused")
    }

    @Test("比較は同じ論文の注記の増減と、終わり方の変化を挙げる")
    func comparison() {
        let note = DocumentRecord.Diagnostic(kind: "unknownCommand", name: #"\x"#)
        let before = [record("a", notes: [note, note]), record("b", notes: []), record("c", notes: [])]
        let after = [record("a", notes: [note]), record("b", notes: [note]), record("c", notes: [], outcome: .timeout)]
        let comparison = CoverageComparison(before: before, after: after)
        #expect(comparison.better.map(\.id) == ["a"])
        #expect(comparison.worse.map(\.id) == ["b"])
        #expect(comparison.outcomes == ["c: ok → timeout"])
        #expect(!comparison.formatsDiffer)
    }

    @Test("書き出した実行を読み直すと同じ記録になる")
    func roundTrip() throws {
        try withFolder([:]) { folder in
            let records = [
                record("b", notes: [.init(kind: "formula", name: "$y$", cause: "layout")]), record("a", notes: []),
            ]
            try CoverageFiles.write(records, to: folder)
            #expect(try CoverageFiles.read(folder) == records.sorted { $0.id < $1.id })
            let table = try String(contentsOf: folder.appending(path: "notes.csv"), encoding: .utf8)
            #expect(table.split(separator: "\n").map { $0.split(separator: ",")[2] } == ["notes", "0", "1"])
        }
    }
}
