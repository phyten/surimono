import AppKit
import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXImageRenderingTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "surimono-latex-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func render(_ latex: String, in folder: URL) async throws -> PreparedRender {
        let file = folder.appending(path: "main.tex")
        try Data(latex.utf8).write(to: file)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        return try await DocumentRenderer().prepare(
            DocumentSource(data: Data(latex.utf8), fileURL: file, format: .latex),
            settings: RenderSettings(
                layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None")))
    }

    /// Whether the red test image is anywhere on the first page; nothing else on it is red.
    private func hasRed(_ document: PDFDocument) throws -> Bool {
        let page = try #require(document.page(at: 0))
        let tiff = try #require(page.thumbnail(of: CGSize(width: 298, height: 421), for: .mediaBox).tiffRepresentation)
        let image = try #require(NSBitmapImageRep(data: tiff))
        for x in 0..<image.pixelsWide {
            for y in 0..<image.pixelsHigh {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent < 0.3 && color.blueComponent < 0.3 { return true }
            }
        }
        return false
    }

    @Test("TikZ の図を描いた LaTeX 文書でも、ほかの画像と外部化の代わりの SVG を刷る", .timeLimit(.minutes(1)))
    func imagesAfterDrawnPicture() async throws {
        _ = NSApplication.shared
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(
            ##"<svg xmlns="http://www.w3.org/2000/svg" width="300" height="150"><rect width="300" height="150" fill="#e00"/></svg>"##
                .utf8
        ).write(to: folder.appending(path: "plate.svg"))
        let result = try await render(
            #"""
            \documentclass{article}
            \usepackage{graphicx}\usepackage{tikz}\usepackage{pgfplots}
            \begin{document}
            \begin{tikzpicture}\draw (0,0) -- (2,1);\end{tikzpicture}

            \tikzexternalize
            \tikzsetnextfilename{plate}
            \begin{figure}[h]\centering
            \begin{tikzpicture}\begin{axis}
            \addplot table[x=a,y=b,col sep=comma] {absent.csv};
            \end{axis}\end{tikzpicture}
            \caption{Fallback}
            \end{figure}
            \end{document}
            """#, in: folder)
        #expect(try hasRed(result.viewDocument))
    }

    @Test("TikZ の図を描いた LaTeX 文書でも、図の中の includegraphics の画像を刷る", .timeLimit(.minutes(1)))
    func includedImageAfterDrawnPicture() async throws {
        _ = NSApplication.shared
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(
            ##"<svg xmlns="http://www.w3.org/2000/svg" width="300" height="150"><rect width="300" height="150" fill="#e00"/></svg>"##
                .utf8
        ).write(to: folder.appending(path: "plate.svg"))
        let result = try await render(
            #"""
            \documentclass{article}
            \usepackage{graphicx}\usepackage{tikz}
            \begin{document}
            \begin{tikzpicture}\draw (0,0) -- (2,1);\end{tikzpicture}

            \begin{figure}[h]\centering
            \includegraphics[width=5cm]{plate}
            \caption{Included}
            \end{figure}
            \end{document}
            """#, in: folder)
        #expect(try hasRed(result.viewDocument))
    }
}

@MainActor
struct MissingImageRenderingTests {
    @Test("テーマで組む文書の読めない画像は、代替文字がなくても名前の枠を紙に残し確認に出す", .timeLimit(.minutes(1)))
    func markdownFrame() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: "surimono-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Present but not an image: the converter keeps the tag, and only the page can tell it cannot be drawn.
        try Data("not an image".utf8).write(to: folder.appending(path: "chart.png"))
        let file = folder.appending(path: "notes.md")
        let markdown = "Some words before the picture.\n\n![](chart.png)\n\nMore words after it.\n"
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(markdown.utf8), fileURL: file, format: .markdown),
            settings: RenderSettings(
                layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
                preset: HTMLCleanupPreset(id: "none", name: "None")))
        #expect(result.viewDocument.string?.contains("Image could not be read: chart.png") == true)
        #expect(result.issues.contains { $0.kind == .image })
    }
}
