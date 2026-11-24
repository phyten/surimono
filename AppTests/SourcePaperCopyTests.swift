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
        PaperPDFView, PDFDocument, PDFDocument
    ) {
        let settings = RenderSettings(
            layout: .a4Single, theme: try #require(PrintThemeLibrary.load().first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let file = DocumentSource(data: Data(text.utf8), format: .plainText).named("example.swift")
        let prepared = try await renderer.prepare(file, settings: settings)
        // Give PDFKit a viewport before it installs a selection, as in a document window.
        let view = PaperPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
        view.configure(
            prepared.viewDocument, at: 0,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            logicalMargin: nil, showsPageNumbers: true)
        view.layoutSubtreeIfNeeded()
        let document = try #require(view.document)
        return (view, document, prepared.viewDocument)
    }

    private func copied(_ selection: PDFSelection, on view: PaperPDFView, logical: PDFDocument, source: String) throws
        -> String
    {
        view.setCurrentSelection(selection, animate: false)
        let board = NSPasteboard(name: .init("SurimonoTests.source.\(UUID())"))
        defer { board.releaseGlobally() }
        var usedFallback = false
        view.copySelection(to: board) { usedFallback = true }
        if usedFallback {
            let detail = selectionDiagnostic(selection, on: view, logical: logical, source: source)
            try #require(!usedFallback, "原文と一致する選択で通常のコピーが呼ばれた \(detail)")
        }
        return try #require(board.string(forType: .string))
    }

    private func selectionDiagnostic(
        _ selection: PDFSelection, on view: PaperPDFView, logical: PDFDocument, source: String
    )
        -> String
    {
        func excerpt(_ text: String) -> String {
            let scalars = text.unicodeScalars
            let start = scalars.prefix(24).map { $0.escaped(asASCII: true) }.joined()
            let end = scalars.count > 24 ? "…" + scalars.suffix(20).map { $0.escaped(asASCII: true) }.joined() : ""
            return start + end
        }
        // The mapper consumes ASCII whitespace separately. Locate the first other differing UTF-16 unit,
        // even if it is far beyond the abbreviated prefix and suffix printed by xcresult.
        func ink(_ text: String) -> [UInt16] { text.utf16.filter { $0 != 32 && !(9...13).contains($0) } }
        let original = ink(source)
        func extraction(_ page: PDFPage?) -> String {
            guard let page, let text = page.string else { return "nil" }
            let units = ink(text)
            let offset = zip(units, original).prefix { $0 == $1 }.count
            let window = offset..<min(offset + 4, units.count)
            let expected = offset..<min(offset + 4, original.count)
            return
                "chars=\(page.numberOfCharacters)/\(text.utf16.count) ink[\(offset)]=\(units[window])/src\(original[expected]) \(excerpt(text))"
        }
        let page = selection.pages.first
        let index = page.flatMap { view.document?.index(for: $0) }
        let originalPage = logical.page(at: index ?? 0)
        func ranges(_ selection: PDFSelection?) -> [NSRange] {
            guard let selection, let first = selection.pages.first else { return [] }
            return (0..<min(6, selection.numberOfTextRanges(on: first))).map { selection.range(at: $0, on: first) }
        }
        var fonts = Set<String>()
        if let text = page?.attributedString {
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let font = value as? NSFont { fonts.insert(font.fontName) }
            }
        }
        let mapped = view.currentSelection.flatMap { current in
            SourcePaperText.selected(current, in: logical, logicalIndex: { view.document?.index(for: $0) })
        }
        let wholeLogicalPage = originalPage.flatMap { page in
            page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))
        }.flatMap { SourcePaperText.selected($0, in: logical, logicalIndex: { logical.index(for: $0) }) }
        return
            "page=\(index ?? -1) ranges=\(ranges(selection))/\(ranges(view.currentSelection)) selected=\(excerpt(selection.string ?? "nil")) "
            + "current=\(excerpt(view.currentSelection?.string ?? "nil")) mapped=\(excerpt(mapped ?? "nil")) wholeLogical=\(excerpt(wholeLogicalPage ?? "nil")) source=\(excerpt(source)) "
            + "logical=\(extraction(originalPage)) shown=\(extraction(page ?? view.document?.page(at: 0))) "
            + "selectionPages=\(selection.pages.count)/\(view.currentSelection?.pages.count ?? 0) displayedPages=\(view.document?.pageCount ?? 0) "
            + "fonts=\(fonts.sorted()) scale=\(NSScreen.main?.backingScaleFactor ?? 0) locale=\(Locale.current.identifier)"
    }

    @Test("原文と照合できない選択は通常のコピーに渡し、紙に見えている文字を取得できる")
    func fallback() async throws {
        let renderer = DocumentRenderer(paginate: { _ in
            try #require(PDFDocument(data: TestFixtures.textPDF(["visible"])))
        })
        let (view, document, _) = try await paper("different source", renderer: renderer)
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
        let (view, document, logical) = try await paper(text)
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
        #expect(try copied(selection, on: view, logical: logical, source: text) == text)
        #expect(document.findString("1", withOptions: []).isEmpty)
    }

    @Test("折り返しをまたぐ選択と、色の境目・タブ・和文をまたぐ選択はそれぞれ原文の部分列になる")
    func partial() async throws {
        let wrapped = "START" + String(repeating: "abcdefghij", count: 24) + "END"
        let text = "let first = \"\(wrapped)\"\nvar\tname = \"摺物\" // 和文コメント\n"
        let (view, document, logical) = try await paper(text)
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
        #expect(try copied(across, on: view, logical: logical, source: text) == wrapped)
        #expect(
            try copied(selection(from: "var", through: "コメント"), on: view, logical: logical, source: text)
                == "var\tname = \"摺物\" // 和文コメント")
    }

    @Test("複数ページをまたぐ選択で行の抜け・重複がなく、80桁を折らない")
    func pageBoundary() async throws {
        let eighty = String(repeating: "w", count: 80)
        let text = eighty + "\n" + (1...120).map { "// 行 \($0)" }.joined(separator: "\n")
        let (view, document, logical) = try await paper(text)
        #expect(document.pageCount > 1)
        let first = try #require(document.findString(eighty, withOptions: []).first)
        #expect(first.selectionsByLine().count == 1)
        let all = PDFSelection(document: document)
        for i in 0..<document.pageCount {
            let page = try #require(document.page(at: i))
            all.add(try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))))
        }
        #expect(try copied(all, on: view, logical: logical, source: text) == text)
    }
}
