import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXClassBodyPrintingTests {
    @Test("情報処理学会の英文誌の図表の見出しは、番号と本文の間を空ける", .timeLimit(.minutes(1)))
    func englishJournalCaptionGap() async throws {
        let tex = #"""
            \documentclass[JIP]{ipsj}
            \begin{document}
            \title{Bench study}\maketitle
            Bench text before the table.
            \begin{table}[h]\caption{Inspection duties of the bench}\begin{tabular}{ll}A & B\end{tabular}\end{table}
            \end{document}
            """#
        let document = try await printed(tex)
        let label = try #require(document.findString("Table 1", withOptions: []).first)
        let text = try #require(document.findString("Inspection", withOptions: []).first)
        let page = try #require(label.pages.first)
        let gap = text.bounds(for: page).minX - label.bounds(for: page).maxX
        #expect(gap > 4, "gap \(gap)")
    }

    @Test(
        "report の目次の直後の段落は、改ページせずに目次と同じページに続ける", .timeLimit(.minutes(1)),
        arguments: ["report", "scrreprt"])
    func paragraphAfterContents(name: String) async throws {
        let tex = #"""
            \documentclass[a4paper,11pt]{\#(name)}
            \title{Bench record}\author{Desk}
            \begin{document}
            \maketitle
            \tableofcontents
            Opening paragraph after the contents.

            \chapter{First bench}
            \section{Shelf}
            Chapter text.
            \end{document}
            """#
        let document = try await printed(tex)
        let contents = try #require(document.findString("Contents", withOptions: []).first?.pages.first)
        let opening = try #require(document.findString("Opening paragraph", withOptions: []).first?.pages.first)
        #expect(document.index(for: opening) == document.index(for: contents))
    }

    @Test("moderncv の 2 行の節見出しは、2 行目も右の列の始まりにそろえる", .timeLimit(.minutes(1)))
    func curriculumVitaeHeadingHangs() async throws {
        let tex = #"""
            \documentclass[11pt,a4paper]{moderncv}
            \moderncvstyle{classic}\moderncvcolor{blue}\name{Model}{Workshop}\title{Fictional project profile}
            \begin{document}
            \makecvtitle
            \section{Alpha bench heading that keeps going long enough to wrap onto Omega}
            \cvitem{Method}{Bench text.}
            \end{document}
            """#
        let document = try await printed(tex)
        let first = try #require(document.findString("Alpha", withOptions: []).first)
        let second = try #require(document.findString("Omega", withOptions: []).first)
        let page = try #require(first.pages.first)
        let start = first.bounds(for: page)
        let wrapped = second.bounds(for: page)
        #expect(wrapped.minY < start.minY - 5, "the heading must wrap")
        let lines = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
        let secondLine = try #require(lines.first { ($0.string ?? "").contains("Omega") }).bounds(for: page)
        #expect(abs(secondLine.minX - start.minX) < 1, "\(secondLine.minX) \(start.minX)")
    }

    @Test("moderncv の表題の氏名は折り返さない", .timeLimit(.minutes(1)))
    func curriculumVitaeNameStaysWhole() async throws {
        let tex = #"""
            \documentclass[11pt,a4paper]{moderncv}
            \moderncvstyle{classic}\name{紙野}{架空}\title{資料保存職の応募用作例}
            \address{架空の霧棚区}{架空地域}{}\extrainfo{人物・所属・経歴はすべて架空。連絡先は記載しない。}
            \begin{document}
            \makecvtitle
            \section{目的}
            \cvitem{希望}{本文。}
            \end{document}
            """#
        let document = try await printed(tex)
        let given = try #require(document.findString("紙野", withOptions: []).first)
        let family = try #require(document.findString("架空", withOptions: []).first)
        let page = try #require(given.pages.first)
        #expect(abs(given.bounds(for: page).midY - family.bounds(for: page).midY) < 2)
    }

    private func printed(_ tex: String) async throws -> PDFDocument {
        let info = LaTeXConverter.documentClassInfo(tex)
        let theme = try #require(
            PrintThemeLibrary.load().first { $0.id == PrintThemeLibrary.defaultLaTeXStyle(for: info) })
        var settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""),
            options: PrintOptions().defaults(for: .latex))
        settings.applyLaTeXPage(info)
        return try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
        ).logicalDocument
    }
}
