import Foundation
import LaTeXCorpusSupport
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXLatinCorpusInputs {
    @Test("段落比較を指定したときだけ実際のコーパスの版面と準備スクリプトを書き出す")
    func exportInputs() throws {
        guard let directory = ProcessInfo.processInfo.environment["SURIMONO_LATEX_LINE_INPUTS"], !directory.isEmpty
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        let themes = try PrintThemeLibrary.load()
        func write(
            _ fragment: HTMLFragment, to base: URL, width: Double, height: Double, paperHeight: Double, left: Double,
            right: Double, flow: Bool, documentMeasure: Bool = true
        ) throws {
            let info = try #require(fragment.latexClass)
            let style = PrintThemeLibrary.defaultLaTeXStyle(for: info)
            let theme = try #require(themes.first { $0.id == style })
            let html = HTMLDocumentBuilder.build(
                fragment: fragment, format: .latex, theme: theme,
                finish: documentMeasure ? RenderSettings.documentWidthCSS : "")
            let ratio = WebPaginator.printPixelsPerPoint
            let input: [String: Any] = [
                "width": width * ratio, "bodyHeight": height * ratio, "paperHeight": paperHeight * ratio,
                "leftMargin": left * ratio, "rightMargin": right * ratio, "flow": flow, "timing": !documentMeasure,
                "eligibleClass": html.contains(" data-latex-line-breaking=\""),
                "preparation": LaTeXGraphicPreparation.script(
                    in: fragment.body, layoutWidth: width * ratio, layoutHeight: height * ratio) ?? "",
            ]
            try Data(html.utf8).write(to: base.appendingPathExtension("html"))
            try JSONSerialization.data(withJSONObject: input).write(to: base.appendingPathExtension("json"))
        }
        try LaTeXCorpus.forEachDocument { name, fragment in
            let info = try #require(fragment.latexClass)
            let box = info.pageBox
            try write(
                fragment, to: output.appendingPathComponent(name),
                width: box.textWidth, height: box.textHeight, paperHeight: box.paperHeight, left: box.left,
                right: box.right,
                flow: info.resolvedStyle != nil || info.usesPublicationGrid || info.profile.usesGridFlow
                    || LaTeXFlowPaginator.needed(in: fragment.body))
        }
        let timing = output.appendingPathComponent("timing", isDirectory: true)
        try FileManager.default.createDirectory(at: timing, withIntermediateDirectories: true)
        let paper = PaperSize.a4.size
        let margin = WebPaginator.Margins.uniform(millimeters: 20)
        for count in [12, 100] {
            let fragment = LaTeXConverter.convert(LaTeXFlowPrintingTests.timingSource(pages: count))
            try write(
                fragment, to: timing.appendingPathComponent(String(count)),
                width: paper.width - margin.left - margin.right, height: paper.height - margin.top - margin.bottom,
                paperHeight: paper.height, left: margin.left, right: margin.right, flow: true, documentMeasure: false)
        }
    }
    @Test("計時用の段落が Chromium の測定値を使う段割りでも十二・百ページに収まる")
    func measuredPageCounts() throws {
        guard let directory = ProcessInfo.processInfo.environment["SURIMONO_LATEX_TIMING_MEASUREMENTS"],
            !directory.isEmpty
        else { return }
        struct Report: Decodable {
            let flowMeasurement: LaTeXFlowLayout.Measurement
            let width, bodyHeight: CGFloat
        }
        for count in [12, 100] {
            let file = URL(fileURLWithPath: directory).appendingPathComponent("\(count).json")
            let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: file))
            let pages = try LaTeXFlowLayout.pages(
                report.flowMeasurement, width: report.width, height: report.bodyHeight)
            #expect(pages.count == count)
        }
    }

}
