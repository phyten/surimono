import CryptoKit
import Foundation
import Testing

@testable import SurimonoFormats

struct AppMathCorpusTests {
    @Test("サンプルと fixture の全数式が変更前と同じ SVG または原文になる")
    func formulaBytes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let list = environment["SURIMONO_MATH_CORPUS"] else { return }
        var root = URL(filePath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let files = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n")
        let pattern = try NSRegularExpression(
            pattern:
                #"<svg\b[^>]*\baria-label="[\s\S]*?</svg>|<(?:code|pre) class="math-error">[\s\S]*?</(?:code|pre)>"#)
        var rows: [String] = []
        for path in files {
            let url = root.appendingPathComponent(String(path))
            let data = try Data(contentsOf: url)
            let text = url.pathExtension == "docx" ? "" : TextDecoding.decode(data).text
            let body: String
            do {
                switch url.pathExtension.lowercased() {
                case "tex", "ltx", "latex":
                    body =
                        LaTeXConverter.convert(text, directory: url.deletingLastPathComponent(), documentURL: url).body
                case "md", "markdown", "mkd", "mkdn", "mdown": body = MarkdownConverter.convert(text).body
                case "qmd", "rmd", "rmarkdown": body = ComputationalMarkdown.convert(text).body
                case "org": body = OrgConverter.convert(text).body
                case "rst", "rest": body = RSTConverter.convert(text).body
                case "ipynb": body = try NotebookConverter.convert(text).body
                case "adoc", "asciidoc": body = try AsciiDocConverter.convert(text).body
                case "dj", "djot": body = try DjotConverter.convert(text).body
                case "textile": body = try TextileConverter.convert(text).body
                case "wiki", "wikitext", "mediawiki": body = MediaWikiConverter.convert(text).body
                case "docx": body = try DocxConverter.convert(data).body
                default: throw CocoaError(.fileReadUnknown)
                }
            } catch {
                // Keep the named converter failure in the oracle for intentionally damaged fixtures.
                guard path.contains("/Robustness/") else { throw error }
                rows.append("\(path)\tconversion-error\t\(String(reflecting: error))")
                continue
            }
            let html = body as NSString
            for match in pattern.matches(in: body, range: NSRange(location: 0, length: html.length)) {
                let element = html.substring(with: match.range)
                let digest = SHA256.hash(data: Data(element.utf8)).map { String(format: "%02x", $0) }.joined()
                rows.append("\(path)\t\(element.hasPrefix("<svg") ? "svg" : "source")\t\(digest)")
            }
        }
        let actual = rows.joined(separator: "\n") + "\n"
        let reference = try #require(
            Bundle.module.url(forResource: "app-math", withExtension: "tsv", subdirectory: "Fixtures"))
        #expect(actual == (try String(contentsOf: reference, encoding: .utf8)))
    }
}
