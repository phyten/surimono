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
    private func renderer(keeping html: SharedValue<String>, sandboxed: Bool = false) -> DocumentRenderer {
        DocumentRenderer(
            isSandboxed: { sandboxed },
            paginateWithResult: { request in
                switch request.source {
                case .html(let body, _): html.value = body
                case .sandboxed(let body, _, _): html.value = body ?? ""
                default: break
                }
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
        let html = SharedValue("")
        let renderer = DocumentRenderer(
            isSandboxed: { false },
            paginateWithResult: { request in
                if case .html(let body, _) = request.source { html.value = body }
                // The printed note's anchor, as the preparation script reports it from the note's attribute.
                var result = WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1))
                var anchor = PrintIssue(
                    id: "latex-0", kind: .latex, detail: "../assets/s.bib could not be read", pageNumber: 1)
                anchor.unreadFile = "unread-0"
                result.issues = [anchor]
                return result
            })
        let prepared = try await renderer.prepare(source, settings: settings)
        #expect(html.value.contains(#"data-unread-file="unread-0""#))
        let notes = prepared.issues.filter { $0.detail == "../assets/s.bib could not be read" }
        #expect(notes.count == 1)
        #expect(notes.first?.pageNumber == 1)
        #expect(notes.first?.outsideFile == "../assets/s.bib")
    }

    @Test("取り込んだ章の .tex が外のファイルを入力すると、その章のフォルダーから解いた場所で許可を求め、許可すると読む")
    func nestedLaTeXInput() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try FileManager.default.createDirectory(
            at: workspace.documents.appending(path: "chapters", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        let outside = try workspace.write("Outside paragraph.", to: "assets/s.tex")
        _ = try workspace.write(#"Chapter text. \input{../../assets/s}"#, to: "doc/chapters/a.tex")
        let latex = #"\documentclass{article}\begin{document}\input{chapters/a}\end{document}"#
        let file = try workspace.write(latex, to: "doc/main.tex")
        var source = DocumentSource(data: Data(latex.utf8), fileURL: file, format: .latex)
        let html = SharedValue("")
        let renderer = renderer(keeping: html)

        let denied = try await renderer.prepare(source, settings: settings)
        #expect(denied.requiredFolderAccess != nil)
        let marked = denied.issues.filter { $0.outsideFile != nil }
        #expect(marked.count == 1)
        #expect(marked.first?.outsideFile == "../../assets/s.tex")
        #expect(marked.first?.outsideURL?.standardizedFileURL == outside.standardizedFileURL)
        #expect(!html.value.contains("Outside paragraph"))

        source.allowedResourceFolders = [workspace.root]
        let allowed = try await renderer.prepare(source, settings: settings)
        #expect(allowed.requiredFolderAccess == nil)
        #expect(allowed.issues.allSatisfy { $0.outsideFile == nil })
        #expect(html.value.contains("Outside paragraph"))
    }

    @Test("見つからない拡張子なしのコードと、外にある同じ名前の .bib を取り違えない")
    func missingListingBesideOutsideBibliography() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        _ = try workspace.write("@book{key, title={Outside edition}}", to: "assets/s.bib")
        let latex = #"""
            \documentclass{article}
            \usepackage{listings}
            \begin{document}
            \cite{key}
            \lstinputlisting{../assets/s}
            \bibliographystyle{plain}
            \bibliography{../assets/s}
            \end{document}
            """#
        let file = try workspace.write(latex, to: "doc/a.tex")
        let source = DocumentSource(data: Data(latex.utf8), fileURL: file, format: .latex)
        let prepared = try await renderer(keeping: SharedValue("")).prepare(source, settings: settings)
        let listing = prepared.issues.filter { $0.detail == "../assets/s could not be read" }
        let bibliography = prepared.issues.filter { $0.detail == "../assets/s.bib could not be read" }
        #expect(listing.count == 1)
        #expect(listing.allSatisfy { $0.outsideFile == nil })
        #expect(bibliography.count == 1)
        #expect(bibliography.first?.outsideFile == "../assets/s.bib")
    }

    @Test("サンドボックスで親のフォルダーを許可済みなら、見つからない外の文献に許可を求めない")
    func sandboxMissingBibliographyAsksNothing() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let markdown = "---\nbibliography: ../assets/missing.bib\n---\n[@key]\n"
        let file = try workspace.write(markdown, to: "doc/a.md")
        var source = DocumentSource(data: Data(markdown.utf8), fileURL: file, format: .markdown)
        source.allowedResourceFolders = [workspace.root]
        let prepared = try await renderer(keeping: SharedValue(""), sandboxed: true).prepare(source, settings: settings)
        #expect(prepared.requiredFolderAccess == nil)
        #expect(prepared.issues.contains { $0.kind == .bibliography && $0.detail.contains("missing.bib") })
        #expect(prepared.issues.allSatisfy { $0.outsideFile == nil })
    }

    @Test("合本に入れても、外の文献の問題は外のファイルの情報を保ったまま一覧に出る")
    func binderKeepsOutsideFile() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        _ = try workspace.write("@book{key, title={Outside edition}}", to: "assets/s.bib")
        let markdown = "---\nbibliography: ../assets/s.bib\n---\n[@key]\n"
        let outsideChild = try workspace.write(markdown, to: "doc/a.md")
        let plainChild = try workspace.write("Plain text.\n", to: "doc/b.md")
        let binder = DocumentSource.binder([
            DocumentSource(data: Data(markdown.utf8), fileURL: outsideChild, format: .markdown),
            DocumentSource(data: Data("Plain text.\n".utf8), fileURL: plainChild, format: .markdown),
        ])
        let prepared = try await renderer(keeping: SharedValue("")).prepare(binder, settings: settings)
        let marked = prepared.issues.filter { $0.outsideFile != nil }
        #expect(marked.count == 1)
        #expect(marked.first?.outsideFile == "../assets/s.bib")
        #expect(marked.first?.outsideURL?.lastPathComponent == "s.bib")
        #expect(prepared.requiredFolderAccess?.standardizedFileURL == workspace.documents.standardizedFileURL)
    }

    @Test("同じ文の注記になる 2 つの入力でも、見つからないだけの側に別の入力の拒否先を付けず、許可すると拒否された側だけが消える")
    func sameWordsTwoFailures() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let manager = FileManager.default
        let documents = workspace.root.appending(path: "project/doc", directoryHint: .isDirectory)
        try manager.createDirectory(
            at: documents.appending(path: "deep", directoryHint: .isDirectory), withIntermediateDirectories: true)
        // From doc/deep the input is project/part.tex, outside the document's folder; from doc it is part.tex at
        // the root, which is not there.
        let refused = try workspace.write("Deep part.", to: "project/part.tex")
        _ = try workspace.write(#"\input{../../part}"#, to: "project/doc/shallow.tex")
        _ = try workspace.write(#"\input{../../part}"#, to: "project/doc/deep/chapter.tex")
        let latex = #"\documentclass{article}\begin{document}\input{shallow}\input{deep/chapter}\end{document}"#
        let file = try workspace.write(latex, to: "project/doc/main.tex")
        var source = DocumentSource(data: Data(latex.utf8), fileURL: file, format: .latex)
        let html = SharedValue("")
        let renderer = renderer(keeping: html)
        let note = "../../part.tex could not be read"

        let denied = try await renderer.prepare(source, settings: settings)
        let notes = denied.issues.filter { $0.detail == note }
        #expect(notes.count == 2)
        #expect(notes.filter { $0.outsideURL == nil }.count == 1)
        #expect(notes.compactMap(\.outsideURL).map(\.standardizedFileURL) == [refused.standardizedFileURL])

        source.allowedResourceFolders = [workspace.root.appending(path: "project", directoryHint: .isDirectory)]
        let allowed = try await renderer.prepare(source, settings: settings)
        let left = allowed.issues.filter { $0.detail == note }
        #expect(left.count == 1)
        #expect(left.first?.outsideURL == nil)
        #expect(allowed.requiredFolderAccess == nil)
        #expect(html.value.contains("Deep part."))
    }

    @Test("許可したフォルダーの中でもファイルの権限で読めない文献には、許可を案内しない")
    func systemDeniedFileAsksNothing() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let bib = try workspace.write("@book{key, title={Locked edition}}", to: "assets/s.bib")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bib.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bib.path) }
        let markdown = "---\nbibliography: ../assets/s.bib\n---\n[@key]\n"
        let file = try workspace.write(markdown, to: "doc/a.md")
        var source = DocumentSource(data: Data(markdown.utf8), fileURL: file, format: .markdown)
        source.allowedResourceFolders = [workspace.root]
        let prepared = try await renderer(keeping: SharedValue("")).prepare(source, settings: settings)
        #expect(prepared.requiredFolderAccess == nil)
        #expect(prepared.issues.contains { $0.kind == .bibliography })
        #expect(prepared.issues.allSatisfy { $0.outsideFile == nil })
    }
}
