import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXAMSEquationPrintingTests {
    @Test(
        "AMS のクラスは align と equation の式番号を既定でそろって左に置き、reqno なら右に置く",
        .timeLimit(.minutes(1)),
        arguments: [("amsart", true), ("amsproc", true), ("amsbook", true), ("amsproc,reqno", false)])
    func tagsShareOneSide(classAndOptions: String, left: Bool) async throws {
        let parts = classAndOptions.split(separator: ",")
        let options = parts.dropFirst().joined(separator: ",")
        let tex = #"""
            \documentclass\#(options.isEmpty ? "" : "[\(options)]"){\#(parts[0])}
            \begin{document}
            Bench text before the display.
            \begin{align}
            a &= b + c\\
            d &= e
            \end{align}
            \begin{equation}
            x = y
            \end{equation}
            \end{document}
            """#
        let document = try await printed(tex)
        for tag in ["(1)", "(2)", "(3)"] {
            let selection = try #require(document.findString(tag, withOptions: []).first, "\(tag)")
            let page = try #require(selection.pages.first)
            let middle = page.bounds(for: .mediaBox).midX
            #expect((selection.bounds(for: page).midX < middle) == left, "\(classAndOptions) \(tag)")
        }
    }

    @Test(
        "行に入らない式番号は式と重ねず、TeX と同じく次の行へ送る",
        .timeLimit(.minutes(1)),
        arguments: [#"\documentclass{article}"#, #"\documentclass[11pt]{article}\usepackage[final]{acl}"#])
    func wideDisplayMovesTag(preamble: String) async throws {
        let wide = #"\text{if every required reference resolves within the bench packet, and only then}"#
        let body = #"""
            \begin{document}
            Bench text before the display.
            \begin{equation}
            Q = \#(wide),
            \end{equation}
            Bench text after the display.
            \end{document}
            """#
        let tex = preamble + "\n" + body
        let document = try await printed(tex)
        let tag = try #require(document.findString("(1)", withOptions: []).first)
        let words = try #require(document.findString("then", withOptions: []).first)
        let page = try #require(tag.pages.first)
        let tagBox = tag.bounds(for: page)
        let wordBox = words.bounds(for: page)
        // PDF coordinates grow upwards: a number moved off the display line sits below it, at the right edge.
        #expect(tagBox.midY < wordBox.minY, "\(tagBox) \(wordBox)")
        #expect(tagBox.maxX >= wordBox.maxX)
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
