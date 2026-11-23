import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct PageFootnotesRenderingTests {
    private func settings() throws -> RenderSettings {
        let themes = try PrintThemeLibrary.load()
        let standard = try #require(themes.first { $0.id == "standard" })
        // The last stock-only page must disappear too, even though it carries no measurement anchors.
        let theme = PrintTheme(
            id: "footnote-test", name: "Footnotes",
            css: standard.css + """
                .paper-footnote-stock::after { content: "STOCKONLYSENTINEL"; display: block;
                    break-before: page; page-break-before: always; }
                """)
        return RenderSettings(layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    @Test("見出しと ID が衝突した二番の注を参照と同じ紙面に置く", .timeLimit(.minutes(1)))
    func placedShiftedOrgFootnote() async throws {
        let org =
            "* A\n:PROPERTIES:\n:CUSTOM_ID: fn-2\n:END:\nFirst[fn:a], second[fn:b].\n\n* Last\nEnd.\n\n[fn:a] NOTEONE\n\n[fn:b] NOTETWO"
        var options = try settings()
        options.theme = PrintTheme(
            id: "org-notes", name: "Org", css: options.theme.css + " h1 + p + h1 { break-before: page; }")
        options.finish.footnotes = .pageBottom
        let source = DocumentSource(data: Data(org.utf8), format: .org)
        let pdf = try await DocumentRenderer().prepare(source, settings: options).logicalDocument
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.string?.contains("NOTETWO") == true)
        #expect(pdf.page(at: 1)?.string?.contains("NOTETWO") == false)
    }

    @Test("実際の組版で脚注が最初の参照と同じページに入り測定用ページは残らない", .timeLimit(.minutes(1)))
    func realPagination() async throws {
        let noteParagraphs = [7, 14, 21, 28, 35]
        let prose = String(
            repeating: "The printed page keeps the reader's place while the reference adds a short explanation. ",
            count: 7)
        var markdown = (1...40).map { index in
            let reference = noteParagraphs.contains(index) ? " REFPOINT\(index)[^note\(index)]" : ""
            return "Paragraph \(index). \(prose)\(reference)"
        }.joined(separator: "\n\n")
        markdown +=
            "\n\n"
            + noteParagraphs.map { "[^note\($0)]: NOTETEXT\($0) A short explanation belonging to its reference." }
            .joined(separator: "\n\n")
        let source = DocumentSource(data: Data(markdown.utf8), format: .markdown)
        var options = try settings()
        let renderer = DocumentRenderer()
        let plain = try await renderer.prepare(source, settings: options)
        let plainTexts = (0..<plain.logicalDocument.pageCount).map { plain.logicalDocument.page(at: $0)?.string ?? "" }
        options.finish.footnotes = .pageBottom
        let placed = try await renderer.prepare(source, settings: options)
        let document = placed.logicalDocument
        let texts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        #expect(document.pageCount <= plain.logicalDocument.pageCount + 1)
        #expect(!texts.contains { $0.contains("STOCKONLYSENTINEL") })
        for number in noteParagraphs {
            let pageIndex = try #require(texts.firstIndex { $0.contains("REFPOINT\(number)") })
            #expect(texts[pageIndex].contains("NOTETEXT\(number)"))
        }
        // This prevents a silent fallback to endnotes from making the placement assertions vacuous.
        #expect(texts.first { $0.contains("REFPOINT7") }?.contains("NOTETEXT7") == true)
        #expect(plainTexts.first { $0.contains("REFPOINT7") }?.contains("NOTETEXT7") == false)
        options.finish.footnotes = .end
        let again = try await renderer.prepare(source, settings: options)
        #expect(
            (0..<again.logicalDocument.pageCount).map { again.logicalDocument.page(at: $0)?.string ?? "" } == plainTexts
        )
    }

    @Test("表の中だけにある脚注はページ下設定でも文末の節に残る", .timeLimit(.minutes(1)))
    func tableRemainsAtEnd() async throws {
        let markdown = """
            | Table |
            | --- |
            | Reference[^table] |

            """ + String(repeating: "A long paragraph following the table. ", count: 400) + """

                [^table]: TABLEENDNOTE
                """
        let source = DocumentSource(data: Data(markdown.utf8), format: .markdown)
        var options = try settings()
        let renderer = DocumentRenderer()
        let plain = try await renderer.prepare(source, settings: options)
        options.finish.footnotes = .pageBottom
        let placed = try await renderer.prepare(source, settings: options)
        let plainTexts = (0..<plain.logicalDocument.pageCount).map { plain.logicalDocument.page(at: $0)?.string ?? "" }
        let texts = (0..<placed.logicalDocument.pageCount).map { placed.logicalDocument.page(at: $0)?.string ?? "" }
        #expect(texts == plainTexts)
        #expect(texts.last?.contains("TABLEENDNOTE") == true)
        #expect(texts.first?.contains("TABLEENDNOTE") == false)
    }

    @Test("参照の行の横に回り込んだ文字があるときは詰めずに文末の脚注へ戻す", .timeLimit(.minutes(1)))
    func floatBesideFallsBack() async throws {
        let side = (1...12).map { "SIDE\($0)" }.joined(separator: "<br>")
        let markdown = """
            <aside style="float:right; width:40%; line-height:20px">\(side)</aside>

            Left text REFPOINT[^n].

            """ + String(repeating: "A long paragraph after the float. ", count: 300) + """

                [^n]: FLOATNOTE
                """
        let source = DocumentSource(data: Data(markdown.utf8), format: .markdown)
        var options = try settings()
        options.finish.footnotes = .pageBottom
        let placed = try await DocumentRenderer().prepare(source, settings: options)
        let texts = (0..<placed.logicalDocument.pageCount).map { placed.logicalDocument.page(at: $0)?.string ?? "" }
        let first = try #require(texts.first)
        for index in 1...12 { #expect(first.contains("SIDE\(index)")) }
        #expect(!first.contains("FLOATNOTE"))
        #expect(texts.last?.contains("FLOATNOTE") == true)
    }
}
