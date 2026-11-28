import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXTallFigureTests {
    @Test(
        "本文より背の高い画像の図は画像だけを縮め、複数行の図題は普通の図と同じ大きさで画像の下に中央で組む",
        .timeLimit(.minutes(1)))
    func tallImage() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, height) in [("tall", 1000), ("small", 50)] {
            let svg =
                #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="\#(height)"><rect width="100" height="\#(height)" fill="red"/></svg>"#
            try Data(svg.utf8).write(to: folder.appending(path: name + ".svg"))
        }
        let long = String(repeating: "縦長の画像に付けた長い図題が何行にも折り返す。", count: 8)
        let text = #"""
            \documentclass{ujreport}
            \begin{document}
            \chapter{図}
            \begin{figure}[p]\centering\includegraphics[height=1.3\textheight]{tall.svg}\caption{\#(long)}\end{figure}
            \begin{figure}[h]\centering\includegraphics[height=2cm]{small.svg}\caption{小さい画像の図題}\end{figure}
            本文。
            \end{document}
            """#
        let file = folder.appending(path: "main.tex")
        try Data(text.utf8).write(to: file)
        let info = LaTeXConverter.documentClassInfo(text)
        let themeID = PrintThemeLibrary.defaultLaTeXStyle(for: info)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == themeID })
        let prepared = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(text.utf8), fileURL: file, format: .latex),
            settings: .init(
                layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""),
                options: PrintOptions().defaults(for: .latex)))
        let pdf = prepared.logicalDocument
        let tallCaption = try #require(pdf.findString("縦長の画像に付けた長い図題").first)
        let smallCaption = try #require(pdf.findString("小さい画像の図題").first)
        let page = try #require(tallCaption.pages.first)
        let tall = tallCaption.bounds(for: page)
        let small = smallCaption.bounds(for: try #require(smallCaption.pages.first))
        // The caption keeps its type size: its first line is as tall as the ordinary figure's caption.
        #expect(abs(tall.height - small.height) < 0.5)
        let image = try #require(try PagePixels(page).bounds { r, g, b in r > 200 && g < 80 && b < 80 })
        let media = page.bounds(for: .mediaBox)
        // Centred like the class's symmetric text block, above the caption, and on the page.
        #expect(image.minY >= 0 && image.maxY <= media.height)
        #expect(media.height - image.maxY > tall.maxY)
        #expect(abs(image.midX - media.midX) < 8)
        #expect(image.height > image.width * 5)
    }
}
