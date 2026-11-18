import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct MarkdownBibliographyResourceTests {
    @Test("文献フォルダーの許可で番号付き引用に変わり、再読み込みでは編集した文献を読む")
    func grantAndReload() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let file = folder.appending(path: "notes.md")
        let bib = folder.appending(path: "refs.bib")
        let data = Data("---\nbibliography: refs.bib\n---\n[@book]".utf8)
        try data.write(to: file)
        try Data("@book{book, title={First edition}}".utf8).write(to: bib)
        var source = DocumentSource(data: data, fileURL: file, format: .markdown)
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        var html = ""
        let renderer = DocumentRenderer(
            isSandboxed: { true },
            paginateWithResult: { request in
                if case .sandboxed(let body, _) = request.source { html = body ?? "" }
                return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
            })
        let denied = try await renderer.prepare(source, settings: settings)
        #expect(denied.requiredFolderAccess?.path == folder.path)
        #expect(denied.issues.contains { $0.kind == .bibliography && $0.detail.contains("refs.bib") })
        #expect(!html.contains("First edition"))
        source.allowedResourceFolders = [folder]
        let allowed = try await renderer.prepare(source, settings: settings)
        #expect(allowed.requiredFolderAccess == nil)
        #expect(allowed.issues.isEmpty)
        #expect(html.contains("First edition"))
        try Data("@book{book, title={Second edition}}".utf8).write(to: bib)
        renderer.clearCache()
        _ = try await renderer.prepare(source, settings: settings)
        #expect(html.contains("Second edition"))
        #expect(try Data(contentsOf: file) == data)
    }
}
