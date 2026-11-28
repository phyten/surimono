import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

/// Outside the sandbox, a document reads the text it names under its own folder, and what lies outside only under a
/// folder the reader allowed.
@MainActor
struct OutsideFolderResourceTests {
    private struct Workspace {
        let root: URL
        let documents: URL

        init() throws {
            let manager = FileManager.default
            root = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                .resolvingSymlinksInPath()
            documents = root.appending(path: "doc", directoryHint: .isDirectory)
            try manager.createDirectory(at: documents, withIntermediateDirectories: true)
            try manager.createDirectory(
                at: root.appending(path: "assets", directoryHint: .isDirectory), withIntermediateDirectories: true)
        }

        func write(_ text: String, to path: String) throws -> URL {
            let url = root.appending(path: path)
            try Data(text.utf8).write(to: url)
            return url
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private let settings = RenderSettings(
        layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
        preset: HTMLCleanupPreset(id: "none", name: "None"))

    /// A renderer that keeps the HTML it was asked to lay out, as the unsandboxed app gives it to WebKit.
    private func renderer(keeping html: SharedValue<String>) -> DocumentRenderer {
        DocumentRenderer(
            isSandboxed: { false },
            paginateWithResult: { request in
                if case .html(let body, _) = request.source { html.value = body }
                return WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
            })
    }

    @Test("文書のフォルダーの外の文献は許可するまで読まず、外のフォルダーを許可すると組まれて確認が消える")
    func markdownBibliography() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        _ = try workspace.write("@book{key, title={Outside edition}}", to: "assets/s.bib")
        let markdown = "---\nbibliography: ../assets/s.bib\n---\n[@key]\n"
        let file = try workspace.write(markdown, to: "doc/a.md")
        var source = DocumentSource(data: Data(markdown.utf8), fileURL: file, format: .markdown)
        let html = SharedValue("")
        let renderer = renderer(keeping: html)

        let denied = try await renderer.prepare(source, settings: settings)
        #expect(denied.requiredFolderAccess?.standardizedFileURL == workspace.documents.standardizedFileURL)
        let issues = denied.issues.filter { $0.kind == .bibliography }
        #expect(issues.count == 1)
        #expect(issues.first?.outsideFile == "../assets/s.bib")
        #expect(!html.value.contains("Outside edition"))
        #expect(html.value.contains("key?"))

        source.allowedResourceFolders = [workspace.root]
        let allowed = try await renderer.prepare(source, settings: settings)
        #expect(allowed.requiredFolderAccess == nil)
        #expect(allowed.issues.isEmpty)
        #expect(html.value.contains("Outside edition"))
        #expect(try Data(contentsOf: file) == Data(markdown.utf8))
    }

    @Test("文書のフォルダーの中の文献は今までどおり許可なしで読み、見つからない外の文献は許可を求めない")
    func ownFolderAndMissingFile() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        _ = try workspace.write("@book{key, title={Inside edition}}", to: "doc/s.bib")
        let markdown = "---\nbibliography: [s.bib, ../assets/missing.bib]\n---\n[@key]\n"
        let file = try workspace.write(markdown, to: "doc/a.md")
        let source = DocumentSource(data: Data(markdown.utf8), fileURL: file, format: .markdown)
        let html = SharedValue("")
        let prepared = try await renderer(keeping: html).prepare(source, settings: settings)
        #expect(html.value.contains("Inside edition"))
        #expect(prepared.requiredFolderAccess == nil)
        #expect(prepared.issues.allSatisfy { $0.outsideFile == nil })
    }

    @Test("許可したフォルダーの外へ出るリンクと .. は、許可があっても読まない")
    func grantDoesNotWiden() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let manager = FileManager.default
        let area = workspace.root.appending(path: "area", directoryHint: .isDirectory)
        try manager.createDirectory(
            at: area.appending(path: "doc", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try manager.createDirectory(
            at: area.appending(path: "assets", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let secret = try workspace.write("@book{key, title={Secret edition}}", to: "assets/s.bib")
        try manager.createSymbolicLink(at: area.appending(path: "assets/link.bib"), withDestinationURL: secret)
        for reference in ["../assets/link.bib", "../../assets/s.bib"] {
            let markdown = "---\nbibliography: \(reference)\n---\n[@key]\n"
            let file = try workspace.write(markdown, to: "area/doc/a.md")
            var source = DocumentSource(data: Data(markdown.utf8), fileURL: file, format: .markdown)
            source.allowedResourceFolders = [area]
            let html = SharedValue("")
            let prepared = try await renderer(keeping: html).prepare(source, settings: settings)
            #expect(!html.value.contains("Secret edition"), "\(reference)")
            #expect(prepared.requiredFolderAccess != nil, "\(reference)")
        }
    }

    @Test("LaTeX の外の文献も、許可するまで読まず、許可すると組まれて確認が消える")
    func latexBibliography() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        _ = try workspace.write(
            "@book{key, author={Ann Author}, title={Outside edition}, year={2020}}", to: "assets/s.bib")
        let latex = #"""
            \documentclass{article}
            \begin{document}
            See \cite{key}.
            \bibliographystyle{plain}
            \bibliography{../assets/s}
            \end{document}
            """#
        let file = try workspace.write(latex, to: "doc/a.tex")
        var source = DocumentSource(data: Data(latex.utf8), fileURL: file, format: .latex)
        let html = SharedValue("")
        let renderer = renderer(keeping: html)

        let denied = try await renderer.prepare(source, settings: settings)
        #expect(denied.requiredFolderAccess != nil)
        let outside = denied.issues.filter { $0.outsideFile != nil }
        #expect(outside.count == 1)
        #expect(outside.first?.outsideFile == "../assets/s.bib")
        #expect(!html.value.contains("Outside edition"))

        source.allowedResourceFolders = [workspace.root]
        let allowed = try await renderer.prepare(source, settings: settings)
        #expect(allowed.requiredFolderAccess == nil)
        #expect(!allowed.issues.contains { $0.detail.contains("s.bib") })
        #expect(html.value.contains("Outside edition"))
    }

    @Test("紙に出た LaTeX のファイルの注記は、読み取りの注記と重ねて確認に 2 件出さない")
    func latexFileNoteOnce() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        _ = try workspace.write("@book{key, title={Outside edition}}", to: "assets/s.bib")
        let latex = #"\documentclass{article}\begin{document}\cite{key}\bibliography{../assets/s}\end{document}"#
        let file = try workspace.write(latex, to: "doc/a.tex")
        let source = DocumentSource(data: Data(latex.utf8), fileURL: file, format: .latex)
        let renderer = DocumentRenderer(
            isSandboxed: { false },
            paginateWithResult: { _ in
                // The printed note's anchor, as the preparation script reports it.
                var result = WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
                result.issues = [
                    PrintIssue(
                        id: "latex-0", kind: .latex, detail: "../assets/s.bib could not be read", pageNumber: 1)
                ]
                return result
            })
        let prepared = try await renderer.prepare(source, settings: settings)
        let notes = prepared.issues.filter { $0.detail == "../assets/s.bib could not be read" }
        #expect(notes.count == 1)
        #expect(notes.first?.pageNumber == 1)
        #expect(notes.first?.outsideFile == "../assets/s.bib")
    }
}
