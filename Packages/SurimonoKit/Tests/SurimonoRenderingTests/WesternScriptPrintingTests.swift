import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct WesternScriptPrintingTests {
    @Test(
        "和文の文書のキリル文字とギリシャ文字は欧文書体で刷り、和文は和文書体のまま", .timeLimit(.minutes(1)),
        arguments: [("standard", "HelveticaNeue"), ("mincho", "TimesNewRomanPSMT")])
    func westernFaces(themeID: String, expected: String) async throws {
        let source = "# 見出し\n\n日本語の本文に Кириллица と Ελληνικά を混ぜる。\n"
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == themeID })
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(source.utf8), format: .markdown),
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let bytes = try #require(result.logicalDocument.dataRepresentation())
        let pdf = try #require(PDFDocument(data: bytes))
        #expect(pdf.findString("Кириллица").count == 1)
        #expect(pdf.findString("Ελληνικά").count == 1)
        let faces = Set(
            String(decoding: bytes, as: UTF8.self).matches(of: #/\/BaseFont\s*\/(?:[A-Z]{6}\+)?([^/\s<>]+)/#)
                .map { String($0.output.1) })
        #expect(faces.contains(expected), "\(faces)")
        #expect(faces.contains { $0.hasPrefix("Hira") }, "\(faces)")
    }
}
