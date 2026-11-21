import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@Suite(.serialized)
@MainActor
struct LaTeXWebKitLineDumpTests {
    nonisolated static func inputs() throws -> [URL?] {
        guard ProcessInfo.processInfo.environment["SURIMONO_LATEX_WEBKIT_LINE_DUMP"]?.isEmpty == false else {
            return [nil]
        }
        let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let corpus = root.appendingPathComponent("Snapshots/corpus/latex", isDirectory: true)
        let folders = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("main.tex").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!folders.isEmpty)
        return folders
    }

    @Test("指定したときだけ実際の印刷経路でコーパスの各段落とPDFを書き出す", .timeLimit(.minutes(1)), arguments: try inputs())
    func export(_ folder: URL?) async throws {
        guard let folder else { return }
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["SURIMONO_LATEX_WEBKIT_LINE_DUMP"])
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let pdfs = output.appendingPathComponent("pdf", isDirectory: true)
        let writesPDF = env["SURIMONO_LATEX_WEBKIT_PDFS"] == "1"
        try FileManager.default.createDirectory(at: writesPDF ? pdfs : output, withIntermediateDirectories: true)
        let themes = try PrintThemeLibrary.load()
        let directory = folder.resolvingSymlinksInPath()
        let id = try #require(directory.lastPathComponent.split(separator: "-").first.map(String.init))
        let file = directory.appendingPathComponent("main.tex")
        var source = DocumentSource(data: try Data(contentsOf: file), fileURL: file, format: .latex)
        source.allowedResourceFolders = [directory]
        let paginator = WebPaginator()
        paginator.collectsLatinLineDiagnostics = true
        paginator.collectsLatinBoxDiagnostics = env["SURIMONO_LATEX_WEBKIT_BOXES"] == "1"
        var passes: [[String: Any]] = []
        var final: [String: Any]?
        var route: String?
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let result = try await paginator.paginate(request)
            for pass in paginator.latinLinePasses {
                passes.append(try #require(JSONSerialization.jsonObject(with: Data(pass.utf8)) as? [String: Any]))
            }
            if let record = paginator.latinLineDiagnostics {
                final = try #require(JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any])
            }
            if let actual = paginator.latinLineRoute { route = actual }
            return result
        })
        let info = renderer.latexClassInfo(for: source)
        let style = PrintThemeLibrary.defaultLaTeXStyle(for: info)
        let theme = try #require(themes.first { $0.id == style })
        // The comparison exports open each file with the A4 simplex preference. Journal classes choose
        // their own trim in the same way as a newly opened document in the app.
        let layout = PrintLayout.defaultLaTeXLayout(for: info) ?? .a4Single
        let settings = RenderSettings(layout: layout, theme: theme, preset: .init(id: "none", name: ""))
        let readingSettings = settings.forReadingLaTeX(info)
        let started = ContinuousClock.now
        let prepared = try await renderer.prepare(source, settings: readingSettings)
        var savedPageText: [String]?
        if writesPDF {
            let outline = await ReadingPDFExporter.outline(
                of: source, in: prepared.logicalDocument, proof: settings.finish.proof,
                includesSourceContents: settings.finish.toc.showsSourceContents)
            let document = try ReadingPDFExporter.document(
                from: prepared.viewDocument, entries: outline.entries,
                title: prepared.facts?.title ?? outline.title ?? directory.lastPathComponent,
                headings: outline.headings, sourceURL: file, furniture: prepared.viewFurniture)
            let url = pdfs.appendingPathComponent(id + ".pdf")
            try #require(document.write(to: url))
            // PDFKit infers a reading order on reopened pages, including their furniture.
            let saved = try #require(PDFDocument(url: url))
            savedPageText = try (0..<saved.pageCount).map { index in
                let page = try #require(saved.page(at: index))
                return page.string ?? ""
            }
        }
        var report: [String: Any] =
            final ?? [
                "qualifying": 0, "composed": 0, "fallbacks": 0, "paragraphs": [], "milliseconds": 0,
            ]
        report["document"] = directory.lastPathComponent
        report["engine"] = "WebKit"
        report["route"] = final?["route"] ?? route ?? "vertical"
        report["hasLatinDiagnostics"] = final?["hasLatinDiagnostics"] ?? (final != nil)
        report["layout"] = readingSettings.layout.id
        report["style"] = style
        report["pageCount"] = prepared.viewDocument.pageCount
        report["pdfKitPageText"] = savedPageText
        report["passes"] = passes
        report["issues"] = prepared.issues.map(\.id)
        let elapsed = started.duration(to: .now).components
        report["wallMilliseconds"] = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        try json.write(
            to: output.appendingPathComponent(directory.lastPathComponent + ".json"), options: .atomic)
    }
}
