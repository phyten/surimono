import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct SandboxResourceTests {
    @Test("文書自身と許可したフォルダ内だけを配り拒否を記録する")
    func boundaries() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = folder.appending(path: "report.html")
        let image = folder.appending(path: "image.png")
        let outside = root.appending(path: "secret.txt")
        for url in [document, image, outside] { try Data("fixture".utf8).write(to: url) }
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "escape"), withDestinationURL: outside)
        let handler = LocalResourceSchemeHandler(access: LocalResourceAccess(documentURL: document, folders: [folder]))
        #expect(try handler.resource(at: LocalResourceSchemeHandler.url(for: document)).data == Data("fixture".utf8))
        #expect(try handler.resource(at: LocalResourceSchemeHandler.url(for: image)).data == Data("fixture".utf8))
        for url in [folder.appending(path: "../secret.txt"), folder.appending(path: "escape"), outside] {
            #expect(throws: (any Error).self) { try handler.resource(at: LocalResourceSchemeHandler.url(for: url)) }
        }
        #expect(handler.requiredFolderAccess?.path == folder.path)
        let ungranted = LocalResourceSchemeHandler(access: LocalResourceAccess(documentURL: document))
        #expect(try ungranted.resource(at: LocalResourceSchemeHandler.url(for: document)).data == Data("fixture".utf8))
        #expect(throws: (any Error).self) { try ungranted.resource(at: LocalResourceSchemeHandler.url(for: image)) }
        #expect(ungranted.requiredFolderAccess?.path == folder.path)
    }

    @Test("差し込みがなければ透明なページを使わない")
    func publicAPIOnlyByDefault() {
        #expect(WebPaginator.clearBackground == nil)
        #expect(!WebPaginator.drawsClearPages)
    }

    @Test("サンドボックスの読み込みと許可要求は組版結果とキャッシュに残る", arguments: [true, false])
    func rendering(sandboxed: Bool) async throws {
        let file = URL(fileURLWithPath: "/documents/report.md")
        let folder = file.deletingLastPathComponent()
        let renderer = DocumentRenderer(
            isSandboxed: { sandboxed },
            paginateWithResult: { request in
                if sandboxed {
                    guard case .sandboxed(_, let access) = request.source else {
                        Issue.record("専用schemeで読み込む")
                        return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
                    }
                    #expect(access.documentURL == file)
                } else {
                    guard case .html = request.source else {
                        Issue.record("従来の読み込みを保つ")
                        return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
                    }
                }
                return WebPaginator.Result(
                    document: try RenderingFixtures.pdf(count: 1), requiredFolderAccess: sandboxed ? folder : nil)
            })
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let source = DocumentSource(data: Data("body".utf8), fileURL: file, format: .markdown)
        for _ in 0..<2 {
            let result = try await renderer.render(source, settings: settings)
            #expect(result.requiredFolderAccess == (sandboxed ? folder : nil))
        }
        #expect(renderer.logicalRenderCount == 1)
    }
    @Test("LaTeXの拡張子探索で許可のない画像を読まず本文と許可要求を返す")
    func latexImageSearch() async throws {
        let file = URL(fileURLWithPath: "/documents/report.tex")
        let renderer = DocumentRenderer(
            isSandboxed: { true },
            paginateWithResult: { request in
                guard case .sandboxed(let html, _) = request.source else {
                    Issue.record("専用schemeで読み込む")
                    return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
                }
                #expect(html?.contains("Body") == true)
                return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
            })
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let source = DocumentSource(
            data: Data(#"Body \includegraphics{images/graph}"#.utf8), fileURL: file, format: .latex)
        let result = try await renderer.render(source, settings: settings)
        #expect(result.requiredFolderAccess?.path == "/documents")
        #expect(result.logicalDocument.pageCount == 1)
    }

    @Test("透明な背景の差し込みがなければ紙を本文に残す")
    func paperFallback() async throws {
        let renderer = DocumentRenderer(paginateWithResult: { request in
            #expect(request.drawsBackground)
            guard case .html(let html, _) = request.source else {
                Issue.record("HTMLが必要")
                return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
            }
            #expect(!html.contains("<style id=\"surimono-paper\">"))
            return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1), preparationResult: "paper")
        })
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: "html { background: #fcfaf5 }"),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        _ = try await renderer.render(DocumentSource(data: Data("body".utf8), format: .markdown), settings: settings)
    }

    @Test("ローカルURLだけを配信用に置換し本文と外部URLを保つ")
    func preservesTextAndExternalResources() throws {
        let html = #"""
            <base href="file:///documents/">
            <p>file:///documents/example.png</p>
            <img src="file:///documents/image.png"><img src="https://example.com/image.png">
            <style>body { background: url('file:///documents/paper.png') }</style>
            <script>const example = "file:///documents/example.png";</script>
            """#
        let file = URL(fileURLWithPath: "/documents/report.md")
        let handler = LocalResourceSchemeHandler(access: LocalResourceAccess(documentURL: file), html: html)
        let result = String(
            decoding: try handler.resource(at: LocalResourceSchemeHandler.url(for: file)).data, as: UTF8.self)
        #expect(result.contains(#"<base href="surimono-local://document/documents/">"#))
        #expect(result.contains("<p>file:///documents/example.png</p>"))
        #expect(result.contains(#"src="surimono-local://document/documents/image.png""#))
        #expect(result.contains(#"src="https://example.com/image.png""#))
        #expect(result.contains("url('surimono-local://document/documents/paper.png')"))
        #expect(result.contains(#"const example = "file:///documents/example.png";"#))
    }

    @Test("紙のローカルリンクは専用schemeをPDFに残さない")
    func restoresFileLinks() throws {
        let document = try RenderingFixtures.pdf(count: 1)
        let page = try #require(document.page(at: 0))
        let local = PDFAnnotation(bounds: .zero, forType: .link, withProperties: nil)
        local.url = URL(string: "surimono-local://document/documents/next.md#section")
        page.addAnnotation(local)
        let external = PDFAnnotation(bounds: .zero, forType: .link, withProperties: nil)
        external.url = URL(string: "https://example.com/")
        page.addAnnotation(external)
        LocalResourceSchemeHandler.restoreFileLinks(in: document)
        #expect(local.url?.absoluteString == "file:///documents/next.md#section")
        #expect(external.url?.absoluteString == "https://example.com/")
    }

    @Test("許可後のLaTeX画像探索は存在しない候補拡張子で許可を求めない")
    func permittedLatexImageSearch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("image".utf8).write(to: folder.appending(path: "graph.svg"))
        let renderer = DocumentRenderer(
            isSandboxed: { true },
            paginateWithResult: { request in
                guard case .sandboxed(let html, _) = request.source else {
                    Issue.record("専用schemeで読み込む")
                    return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
                }
                #expect(html?.contains("graph.svg") == true)
                return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
            })
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        var source = DocumentSource(
            data: Data(#"Body \includegraphics{graph}"#.utf8), fileURL: folder.appending(path: "report.tex"),
            format: .latex)
        source.allowedResourceFolders = [folder]
        let result = try await renderer.render(source, settings: settings)
        #expect(result.requiredFolderAccess == nil)
    }

    @Test("検査直後にファイルや途中のフォルダを外へのリンクに差し替えても元の記述子から読む", arguments: [false, true])
    func replacementAfterValidation(replacesDirectory: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "docs")
        let images = folder.appending(path: "images")
        let outside = root.appending(path: "other-document")
        for directory in [images, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let file = images.appending(path: "graph.bin")
        let secret = outside.appending(path: "graph.bin")
        try Data("allowed".utf8).write(to: file)
        try Data("secret".utf8).write(to: secret)
        let handler = LocalResourceSchemeHandler(
            access: LocalResourceAccess(documentURL: folder.appending(path: "report.md"), folders: [folder]))
        let result = try handler.resource(at: LocalResourceSchemeHandler.url(for: file)) {
            if replacesDirectory {
                try FileManager.default.moveItem(at: images, to: folder.appending(path: "old-images"))
                try FileManager.default.createSymbolicLink(at: images, withDestinationURL: outside)
            } else {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
            }
        }
        #expect(result.data == Data("allowed".utf8))
    }

    @Test("許可範囲内へのシンボリックリンクは引き続き配る")
    func permittedSymbolicLink() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "image.bin")
        let link = folder.appending(path: "link.bin")
        try Data("allowed".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let handler = LocalResourceSchemeHandler(
            access: LocalResourceAccess(documentURL: folder.appending(path: "report.md"), folders: [folder]))
        #expect(try handler.resource(at: LocalResourceSchemeHandler.url(for: link)).data == Data("allowed".utf8))
    }

    @Test("開いたファイルが上限を超えている場合と検査後に上限を超えて伸びた場合は配らない", arguments: [false, true])
    func oversizedResource(growsAfterValidation: Bool) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "large.bin")
        try Data("small".utf8).write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        if !growsAfterValidation { try writer.truncate(atOffset: 50 * 1024 * 1024 + 1) }
        let handler = LocalResourceSchemeHandler(
            access: LocalResourceAccess(documentURL: folder.appending(path: "report.md"), folders: [folder]))
        #expect(throws: (any Error).self) {
            _ = try handler.resource(at: LocalResourceSchemeHandler.url(for: file)) {
                if growsAfterValidation { try writer.truncate(atOffset: 50 * 1024 * 1024 + 1) }
            }
        }
        #expect(handler.requiredFolderAccess?.path == folder.path)
    }

}
