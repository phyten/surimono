import Foundation
import RobustnessSupport
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXResourceTests {
    @Test("通常と校正は前文を共有し、再読み込みと文書の変更で全ての組み方を読み直す")
    func compositionCache() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let preamble = folder.appending(path: "preamble.tex")
        let main = folder.appending(path: "main.tex")
        let data = Data(#"\input{preamble}\begin{document}x\end{document}"#.utf8)
        let source = DocumentSource(data: data, fileURL: main, format: .latex)
        let renderer = DocumentRenderer(isSandboxed: { false })
        try Data(#"\documentclass{article}"#.utf8).write(to: preamble)
        #expect(!renderer.latexClassInfo(for: source).hasChapters)
        try Data(#"\documentclass{book}"#.utf8).write(to: preamble)
        let proof = renderer.latexClassInfo(for: source, composition: .proof)
        #expect(proof.composition == .proof && !proof.hasChapters)
        #expect(renderer.latexClassInfo(for: source, composition: .twoColumn).hasChapters)
        #expect(!renderer.latexClassInfo(for: source).hasChapters)
        renderer.clearCache()
        #expect(renderer.latexClassInfo(for: source, composition: .proof).hasChapters)
        try Data(#"\documentclass{article}"#.utf8).write(to: preamble)
        let edited = DocumentSource(data: data + Data(" ".utf8), fileURL: main, format: .latex)
        #expect(!renderer.latexClassInfo(for: edited).hasChapters)
        #expect(!renderer.latexClassInfo(for: edited, composition: .proof).hasChapters)
        #expect(!renderer.latexClassInfo(for: edited, composition: .twoColumn).hasChapters)
    }

    @Test("フォルダーの許可を求め、許可後は章を読み、再読み込みで章の変更が本文に反映される")
    func grantAndReload() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let chapter = folder.appending(path: "chapter.tex")
        let preamble = folder.appending(path: "preamble.tex")
        try Data(#"\documentclass{ltjsarticle}"#.utf8).write(to: preamble)
        try Data("BeforeEdit".utf8).write(to: chapter)
        let main = folder.appending(path: "main.tex")
        let text = Data(#"\input{preamble}\begin{document}\input{chapter}\end{document}"#.utf8)
        try text.write(to: main)
        var source = DocumentSource(data: text, fileURL: main, format: .latex)
        var body = ""
        let renderer = DocumentRenderer(
            isSandboxed: { true },
            paginateWithResult: { request in
                if case .sandboxed(let html, _, _) = request.source { body = html ?? "" }
                return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
            })
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let denied = try await renderer.render(source, settings: settings)
        #expect(!renderer.latexClassInfo(for: source).isJapanese)
        #expect(denied.requiredFolderAccess?.path == folder.path)
        #expect(!body.contains("BeforeEdit"))
        source.allowedResourceFolders = [folder]
        #expect(renderer.latexClassInfo(for: source).isJapanese)
        let allowed = try await renderer.render(source, settings: settings)
        #expect(allowed.requiredFolderAccess == nil)
        #expect(body.contains("BeforeEdit"))
        try Data("AfterEdit".utf8).write(to: chapter)
        try Data(#"\documentclass{report}"#.utf8).write(to: preamble)
        renderer.clearCache()
        #expect(renderer.latexClassInfo(for: source).hasChapters)
        #expect(!renderer.latexClassInfo(for: source).isJapanese)
        _ = try await renderer.render(source, settings: settings)
        #expect(body.contains("AfterEdit"))
        #expect(try Data(contentsOf: main) == text)
    }

    @Test("切り抜きに使う元画像の寸法は画像の向きに従う")
    func graphicDimensions() throws {
        let regular = try #require(DocumentRenderer.imageSizeInPoints(RenderingFixtures.image()))
        let rotated = try #require(DocumentRenderer.imageSizeInPoints(RenderingFixtures.image(orientation: 6)))
        #expect(regular.width == 2 * regular.height)
        #expect(rotated.width == regular.height)
        #expect(rotated.height == regular.width)
    }

    @Test("許可フォルダー外への相対パスとシンボリックリンクから本文を読めない")
    func outsideFolder() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let folder = root.appending(path: "paper", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let outside = root.appending(path: "outside.tex")
        try Data("OutsideContent".utf8).write(to: outside)
        try manager.createSymbolicLink(at: folder.appending(path: "link.tex"), withDestinationURL: outside)
        let main = folder.appending(path: "main.tex")
        let text = Data(#"\input{link}\input{../outside}"#.utf8)
        try text.write(to: main)
        let source = DocumentSource(data: text, fileURL: main, format: .latex)
        let denied = Locked(false)
        let fragment = try #require(
            try DocumentRenderer.themedFragment(
                source, access: LocalResourceAccess(documentURL: main, folders: [folder]),
                onDenied: { denied.value = true }))
        #expect(denied.value)
        #expect(!fragment.body.contains("OutsideContent"))
        #expect(fragment.readingIssues.count == 2)
    }
}
