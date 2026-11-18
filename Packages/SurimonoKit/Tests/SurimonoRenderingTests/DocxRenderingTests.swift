import AppKit
import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@Suite(.serialized)
@MainActor
struct DocxRenderingTests {
    @Test("Wordの文書でないファイルは理由をそのまま伝える")
    func reportsWhatIsWrong() async throws {
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        let source = DocumentSource(data: Data("not a zip".utf8), format: .docx)
        await #expect(throws: DocxError.invalidDocument) {
            _ = try await DocumentRenderer().render(source, settings: settings)
        }
    }

    @Test("Wordの改ページと脚注を論理ページへ組版する", .timeLimit(.minutes(1)))
    func paginates() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Samples/sample.docx")
        let source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .docx)
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(source, settings: settings)
        let pdf = result.logicalDocument
        let pages = (0..<pdf.pageCount).map { index in
            (pdf.page(at: index)?.string ?? "").filter { !$0.isWhitespace }
        }
        #expect(pages.joined().contains("Printguide"))
        #expect(pages.joined().contains("注の本文"))
        let before = try #require(pages.firstIndex { $0.contains("print(sheets)") })
        let after = try #require(pages.firstIndex { $0.contains("まとめ") })
        #expect(after > before)
    }
}
