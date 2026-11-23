import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SourcePaperCopyTests {
    private func paper(_ text: String, renderer: DocumentRenderer = DocumentRenderer()) async throws -> (
        PaperPDFView, PDFDocument
    ) {
        let settings = RenderSettings(
            layout: .a4Single, theme: try #require(PrintThemeLibrary.load().first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let file = DocumentSource(data: Data(text.utf8), format: .plainText).named("example.swift")
        let prepared = try await renderer.prepare(file, settings: settings)
        let view = PaperPDFView()
        view.configure(
            prepared.viewDocument, at: 0,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            logicalMargin: nil, showsPageNumbers: true)
        let document = try #require(view.document)
        return (view, document)
    }

    private func copied(_ selection: PDFSelection, on view: PaperPDFView) throws -> String {
        view.setCurrentSelection(selection, animate: false)
        let board = NSPasteboard(name: .init("SurimonoTests.source.\(UUID())"))
        defer { board.releaseGlobally() }
        view.copySelection(to: board) { Issue.record("原文と一致する選択で通常のコピーが呼ばれた") }
        return try #require(board.string(forType: .string))
    }

    @Test("原文と照合できない選択は通常のコピーに渡し、紙に見えている文字を取得できる")
    func fallback() async throws {
        let renderer = DocumentRenderer(paginate: { _ in
            try #require(PDFDocument(data: TestFixtures.textPDF(["visible"])))
        })
        let (view, document) = try await paper("different source", renderer: renderer)
        let selection = try #require(document.findString("visible").first)
        view.setCurrentSelection(selection, animate: false)
        let board = NSPasteboard(name: .init("SurimonoTests.source.\(UUID())"))
        defer { board.releaseGlobally() }
        var called = false
        // Stand in for PDFView.copy so the test never changes the user's clipboard.
        view.copySelection(to: board) {
            called = true
            if let visible = view.currentSelection?.string { board.setString(visible, forType: .string) }
        }
        #expect(called)
        #expect(board.string(forType: .string) == "visible")
    }

    @Test("紙一枚を選ぶと行番号も折り返しも入らず、タブ・空行・末尾の改行まで戻る")
    func fullPage() async throws {
        let text = "\tlet title = \"日本語\"\r\n\r\n\t// " + String(repeating: "abcd ", count: 48) + "終わり\r\n"
        let (view, document) = try await paper(text)
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
        #expect(try copied(selection, on: view) == text)
        #expect(document.findString("1", withOptions: []).isEmpty)
    }

    @Test("折り返しをまたぐ選択と、色の境目・タブ・和文をまたぐ選択はそれぞれ原文の部分列になる")
    func partial() async throws {
        let wrapped = "START" + String(repeating: "abcdefghij", count: 24) + "END"
        let text = "let first = \"\(wrapped)\"\nvar\tname = \"摺物\" // 和文コメント\n"
        let (view, document) = try await paper(text)
        let page = try #require(document.page(at: 0))
        let printed = try #require(page.string) as NSString
        func selection(from head: String, through tail: String) throws -> PDFSelection {
            let first = printed.range(of: head)
            let last = printed.range(of: tail)
            try #require(first.location != NSNotFound && last.location != NSNotFound)
            return try #require(page.selection(for: NSUnionRange(first, last)))
        }
        let across = try selection(from: "START", through: "END")
        #expect(across.selectionsByLine().count >= 2)
        #expect(try copied(across, on: view) == wrapped)
        #expect(try copied(selection(from: "var", through: "コメント"), on: view) == "var\tname = \"摺物\" // 和文コメント")
    }

    @Test("複数ページをまたぐ選択で行の抜け・重複がなく、80桁を折らない")
    func pageBoundary() async throws {
        let eighty = String(repeating: "w", count: 80)
        let text = eighty + "\n" + (1...120).map { "// 行 \($0)" }.joined(separator: "\n")
        let (view, document) = try await paper(text)
        #expect(document.pageCount > 1)
        let first = try #require(document.findString(eighty, withOptions: []).first)
        #expect(first.selectionsByLine().count == 1)
        let all = PDFSelection(document: document)
        for i in 0..<document.pageCount {
            let page = try #require(document.page(at: i))
            all.add(try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))))
        }
        #expect(try copied(all, on: view) == text)
    }
}
