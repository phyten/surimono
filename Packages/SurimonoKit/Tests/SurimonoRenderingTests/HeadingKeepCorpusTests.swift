import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

/// An opt-in measurement over local documents: each file is printed without the heading passes, with them only
/// measuring, and with them correcting. `SURIMONO_HEADING_KEEP_CORPUS` names a file with one document path a line,
/// `SURIMONO_HEADING_KEEP_OUT` the folder for the report and the PDFs. Nothing runs without them.
@MainActor
@Suite(.serialized)
struct HeadingKeepCorpusTests {
    nonisolated static func inputs() throws -> [String?] {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["SURIMONO_HEADING_KEEP_CORPUS"], !list.isEmpty else { return [nil] }
        return try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty }
    }

    @Test("指定したときだけ、文書ごとに見出しの補正の前後を測って書き出す", .timeLimit(.minutes(5)), arguments: try inputs())
    func measure(_ path: String?) async throws {
        guard let path else { return }
        let output = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SURIMONO_HEADING_KEEP_OUT"]),
            isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: path)
        let format = try #require(DocumentFormat(fileExtension: file.pathExtension))
        var source = DocumentSource(data: try Data(contentsOf: file), fileURL: file, format: format)
        source.allowedResourceFolders = [file.deletingLastPathComponent()]
        let themes = try PrintThemeLibrary.load()
        var settings = RenderSettings(
            layout: .a4Single, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        if format == .latex {
            let info = DocumentRenderer().latexClassInfo(for: source)
            let style = PrintThemeLibrary.defaultLaTeXStyle(for: info)
            settings.theme = try #require(themes.first { $0.id == style })
            settings.layout = PrintLayout.defaultLaTeXLayout(for: info) ?? .a4Single
            settings = settings.forReadingLaTeX(info)
        }
        struct Run {
            var pages = 0
            var seconds = 0.0
            var prints = 0
            var report: HeadingKeepPasses.Report?
            var document: PDFDocument?
        }
        func run(_ mode: HeadingKeepPasses.Mode?) async throws -> Run {
            var settings = settings
            settings.finish.breaks.keepsHeadingsWithText = mode != nil
            let paginator = WebPaginator()
            paginator.headingKeepMode = mode ?? .correct
            paginator.collectsHeadingKeepDetails = true
            let renderer = DocumentRenderer(paginateWithResult: { try await paginator.paginate($0) })
            let started = ContinuousClock.now
            let prepared = try await renderer.prepare(source, settings: settings)
            let elapsed = ContinuousClock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return Run(
                pages: prepared.logicalDocument.pageCount, seconds: seconds, prints: paginator.printStartCount,
                report: paginator.headingKeepReports.last, document: prepared.logicalDocument)
        }
        let off = try await run(nil)
        let detected = try await run(.detect)
        let corrected = try await run(.correct)
        let name = file.deletingPathExtension().lastPathComponent + "." + file.pathExtension
        try detected.document?.dataRepresentation()?.write(to: output.appendingPathComponent(name + ".before.pdf"))
        try corrected.document?.dataRepresentation()?.write(to: output.appendingPathComponent(name + ".after.pdf"))
        func seconds(_ duration: Duration?) -> Double {
            guard let duration else { return 0 }
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        func summary(_ summary: HeadingKeep.Summary?) -> [String: Any] {
            guard let summary else { return [:] }
            return [
                "groups": summary.groups, "together": summary.together, "separated": summary.separated,
                "uncorrectable": summary.uncorrectable, "alone": summary.alone, "unmeasured": summary.unmeasured,
            ]
        }
        let record: [String: Any] = [
            "file": path, "format": format.rawValue,
            "pagesOff": off.pages, "pagesDetect": detected.pages, "pagesCorrect": corrected.pages,
            "secondsOff": off.seconds, "secondsDetect": detected.seconds, "secondsCorrect": corrected.seconds,
            "printsOff": off.prints, "printsDetect": detected.prints, "printsCorrect": corrected.prints,
            "detectMeasuring": seconds(detected.report?.measuring),
            "detect": summary(detected.report?.initial),
            "detectUnmeasured": detected.report?.unmeasured?.rawValue ?? "",
            "correctInitial": summary(corrected.report?.initial), "correctFinal": summary(corrected.report?.final),
            "extraPrints": corrected.report?.extraPrints ?? 0, "breaks": corrected.report?.breaks.count ?? 0,
            "stop": corrected.report?.stop.map { "\($0)" } ?? "", "reused": corrected.report?.reused ?? false,
            "correctMeasuring": seconds(corrected.report?.measuring),
            "detectDetails": detected.report?.details ?? [], "correctDetails": corrected.report?.details ?? [],
            "printingCorrect": seconds(corrected.report?.printing),
        ]
        let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let report = output.appendingPathComponent("report.jsonl")
        if !FileManager.default.fileExists(atPath: report.path) {
            FileManager.default.createFile(atPath: report.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: report)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line + Data("\n".utf8))
    }
}
