import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct TikZHatchRenderingTests {
    @Test("楕円で切り抜いた斜線は書き出す SVG にも印刷用 PDF にも画像を含まない", .timeLimit(.minutes(1)))
    func hatchStaysVector() async throws {
        _ = NSApplication.shared
        let source = #"""
            \documentclass{article}\usetikzlibrary{patterns}\begin{document}
            \begin{tikzpicture}
            \begin{scope}\clip (0,0) ellipse (2.6 and 1.3);
            \fill[pattern=north east lines] (-3,-2) rectangle (3,.15);
            \end{scope}\draw (0,0) ellipse (2.6 and 1.3);
            \end{tikzpicture}\end{document}
            """#
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(source.utf8), format: .latex),
            settings: RenderSettings(
                layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
                preset: HTMLCleanupPreset(id: "none", name: "None")))
        let diagram = try #require(result.diagrams.first)
        let xml = try XMLDocument(xmlString: diagram.svg, options: [])
        #expect(try xml.nodes(forXPath: "//*[local-name()='pattern' or local-name()='image']").isEmpty)
        let hatch = try #require(
            try xml.nodes(forXPath: "//*[local-name()='path' and @clip-path and @stroke='#000000']").first
                as? XMLElement)
        #expect((hatch.attribute(forName: "d")?.stringValue?.filter { $0 == "M" }.count ?? 0) > 40)
        let page = try #require(result.viewDocument.page(at: diagram.pageIndex)?.pageRef?.dictionary)
        var resources: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(page, "Resources", &resources))
        #expect(!Self.containsImage(try #require(resources)))
    }

    // Quartz stores rasterized SVG tiles in Pattern -> Resources -> XObject, outside the page XObject dictionary.
    private static func containsImage(_ resources: CGPDFDictionaryRef, depth: Int = 0) -> Bool {
        guard depth < 32 else { return true }
        for key in ["XObject", "Pattern"] {
            var objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, key, &objects), let objects else { continue }
            var found = false
            CGPDFDictionaryApplyBlock(
                objects,
                { _, object, _ in
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                        let dict = CGPDFStreamGetDictionary(stream)
                    else { return true }
                    var kind: UnsafePointer<CChar>?
                    if CGPDFDictionaryGetName(dict, "Subtype", &kind), let kind, String(cString: kind) == "Image" {
                        found = true
                    }
                    var nested: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &nested), let nested {
                        found = found || containsImage(nested, depth: depth + 1)
                    }
                    return !found
                }, nil)
            if found { return true }
        }
        return false
    }
}
