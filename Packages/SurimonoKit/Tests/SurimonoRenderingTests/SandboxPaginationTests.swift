import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct SandboxPaginationTests {
    @Test(
        "許可前も本文を刷れ許可後は隣の画像を描く", .timeLimit(.minutes(1)),
        arguments: [DocumentFormat.markdown, .html, .latex])
    func neighboringImage(format: DocumentFormat) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let svg =
            #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="red"/></svg>"#
        try Data(svg.utf8).write(to: folder.appending(path: "graph.svg"))
        let text: String
        switch format {
        case .markdown: text = "Body\n\n![Graph](graph.svg)"
        case .latex: text = #"Body \includegraphics{graph}"#
        default: text = "<!doctype html><p>Body</p><img src='graph.svg'>"
        }
        let file = folder.appending(path: format == .html ? "report.html" : "report.txt")
        try Data(text.utf8).write(to: file)
        var source = DocumentSource(data: Data(text.utf8), fileURL: file, format: format)
        let renderer = DocumentRenderer(isSandboxed: { true })
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"), allowsJavaScriptInHTML: true)
        let denied = try await renderer.render(source, settings: settings)
        #expect(denied.requiredFolderAccess?.path == folder.path)
        #expect(denied.logicalDocument.string?.contains("Body") == true)
        let before = try PagePixels(try #require(denied.logicalDocument.page(at: 0)))
        #expect(before.bounds { $0 > 200 && $1 < 50 && $2 < 50 } == nil)
        source.allowedResourceFolders = [folder]
        let granted = try await renderer.render(source, settings: settings)
        #expect(granted.requiredFolderAccess == nil)
        let after = try PagePixels(try #require(granted.logicalDocument.page(at: 0)))
        #expect(after.bounds { $0 > 200 && $1 < 50 && $2 < 50 } != nil)
        #expect(try Data(contentsOf: file) == Data(text.utf8))
    }
}
