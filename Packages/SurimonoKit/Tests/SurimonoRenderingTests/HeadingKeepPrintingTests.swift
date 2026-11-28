import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

/// Headings on WebKit's own pages: each is checked by where its text and the text after it are printed, never by a
/// page number, so that the tests hold for any WebKit that keeps headings better by itself.
@MainActor
@Suite(.serialized)
struct HeadingKeepPrintingTests {
    private func settings() throws -> RenderSettings {
        let themes = try PrintThemeLibrary.load()
        return RenderSettings(
            layout: .a4Single, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    /// Variants that each start a page of their own (`\newpage`) with a block of `k` lines before a heading, so that
    /// for some `k` the heading falls at the foot of the page whatever the exact line height, and a correction in one
    /// variant cannot move another. Each heading and the first word of its text carry a token of their own.
    private func variants(_ range: ClosedRange<Int>, heading: (Int) -> String) -> String {
        range.map { k in
            let filler = (0..<k).map { "Filler line \($0) of variant \(k)." }.joined(separator: "\\\n")
            let words = (0..<120).map { "word\($0 % 10)" }.joined(separator: " ")
            return "\(filler)\n\n\(heading(k))\n\nHKB\(k)x \(words)\n"
        }.joined(separator: "\n\\newpage\n\n")
    }

    private let lines = 30...75

    private func render(
        _ markdown: String, settings: RenderSettings, mode: HeadingKeepPasses.Mode = .correct
    ) async throws -> (PDFDocument, WebPaginator) {
        let paginator = WebPaginator()
        paginator.headingKeepMode = mode
        let renderer = DocumentRenderer(paginateWithResult: { try await paginator.paginate($0) })
        let prepared = try await renderer.prepare(
            DocumentSource(data: Data(markdown.utf8), format: .markdown), settings: settings)
        return (prepared.logicalDocument, paginator)
    }

    /// The page of each token, read from the printed text.
    private func page(of token: String, in document: PDFDocument) -> Int? {
        (0..<document.pageCount).first { document.page(at: $0)?.string?.contains(token) == true }
    }

    private func separated(in document: PDFDocument) -> [Int] {
        lines.filter { n in
            guard let heading = page(of: "HKH\(n)x", in: document), let text = page(of: "HKB\(n)x", in: document)
            else { return true }
            return heading != text
        }
    }

    @Test("見出しを測るだけのときは、ページの文字で数えたのと同じ数の見出しを離れたと見つける", .timeLimit(.minutes(1)))
    func detectionAgreesWithPageText() async throws {
        let text = variants(lines) { "## Heading HKH\($0)x" }
        let (document, paginator) = try await render(text, settings: try settings(), mode: .detect)
        let report = try #require(paginator.headingKeepReports.last)
        let initial = try #require(report.initial)
        #expect(report.extraPrints == 0)
        #expect(initial.groups == lines.count)
        #expect(initial.unmeasuredCount == 0)
        #expect(initial.separated == separated(in: document).count)
    }

    @Test("組み直した後は、どの見出しも本文の最初の行と同じページにある", .timeLimit(.minutes(1)))
    func headingsShareTheirPage() async throws {
        let text = variants(lines) { "## Heading HKH\($0)x" }
        let (document, paginator) = try await render(text, settings: try settings())
        #expect(separated(in: document).isEmpty)
        let report = try #require(paginator.headingKeepReports.last)
        #expect(report.extraPrints <= 2)
        #expect(report.final?.separated == 0)
    }

    @Test("続けて並んだ見出しは、上の見出しから本文まで同じページに置く", .timeLimit(.minutes(1)))
    func consecutiveHeadingsMoveTogether() async throws {
        let text = variants(lines) { "## Part HKP\($0)x\n\n### Heading HKH\($0)x" }
        let (document, _) = try await render(text, settings: try settings())
        for k in lines {
            let part = page(of: "HKP\(k)x", in: document)
            #expect(part != nil && part == page(of: "HKH\(k)x", in: document))
            #expect(part != nil && part == page(of: "HKB\(k)x", in: document))
        }
    }

    @Test("離れた見出しのない文書は一度だけ組む", .timeLimit(.minutes(1)))
    func keptDocumentPrintsOnce() async throws {
        let text = "## Heading\n\n" + (0..<6).map { "Paragraph \($0) of a short document." }.joined(separator: "\n\n")
        let (document, paginator) = try await render(text, settings: try settings())
        #expect(document.pageCount == 1)
        #expect(paginator.printStartCount == 1)
        #expect(paginator.headingKeepReports.last?.extraPrints == 0)
    }

    @Test("見出しを本文と離さない設定を切ると、見出しを測らない", .timeLimit(.minutes(1)))
    func switchedOff() async throws {
        var settings = try settings()
        settings.finish.breaks.keepsHeadingsWithText = false
        let (_, paginator) = try await render(variants(30...31) { "## Heading HKH\($0)x" }, settings: settings)
        #expect(paginator.headingKeepReports.isEmpty)
    }
}
