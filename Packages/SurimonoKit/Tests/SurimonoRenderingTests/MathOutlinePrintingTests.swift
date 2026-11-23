import AppKit
import CoreText
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct MathOutlinePrintingTests {
    @Test("数式の三点リーダーは一文字の送りを保ち、点の輪郭は実TeXの大きさになる")
    func dots() throws {
        let data = try #require(MathRenderer.fontData(family: "KaTeX_Main", weight: "normal", style: "normal"))
        let provider = try #require(CGDataProvider(data: data as CFData))
        let graphics = try #require(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(graphics, 1000, nil, nil)
        // At 1000 units/em the CMSY centred dot and CMR period are 106 units across.
        for (code, width, height, advance) in [
            (0x22C5, 106, 106, 278), (0x2026, 995, 106, 1172), (0x22EF, 995, 106, 1172),
            (0x22EE, 106, 906, 278), (0x22F1, 883, 706, 1282),
        ] {
            var character = UniChar(code)
            var glyph = CGGlyph()
            try #require(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
            let path = try #require(CTFontCreatePathForGlyph(font, glyph, nil))
            #expect(abs(path.boundingBoxOfPath.width - CGFloat(width)) < 1)
            #expect(abs(path.boundingBoxOfPath.height - CGFloat(height)) < 1)
            #expect(abs(CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1) - Double(advance)) < 1)
        }
    }

    @Test("数式見本を読むPDFに保存しても検索でき、紙面の墨量が実TeXに近い", .timeLimit(.minutes(1)))
    func formulaSheet() async throws {
        _ = NSApplication.shared
        func fixture(_ name: String, _ ext: String) throws -> URL {
            try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        }
        let url = try fixture("math-outlines", "tex")
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let prepared = try await DocumentRenderer().prepare(
            DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .latex),
            settings: RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: "")))
        let reading = try ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Math", furniture: prepared.viewFurniture)
        let data = try ReadingPDFExporter.data(from: reading)
        let pdf = try #require(PDFDocument(data: data))
        let reference = try #require(PDFDocument(url: try fixture("math-outlines-reference", "pdf")))
        let expected = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: try fixture("math-outlines-search", "json")))
        let extracted = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
        // PDFKit may infer a space between the separately positioned f and its opening parenthesis.
        // Keep the rest of each page exact, including line breaks, operators and reading order.
        func caseFormula(_ page: String) -> String {
            page.replacingOccurrences(of: "\nf (x) = {x", with: "\nf(x) = {x")
        }
        #expect(extracted.map { caseFormula($0) } == expected.map { caseFormula($0) })
        for (query, count) in [
            ("√", 3), ("∑", 1), ("(x)", 5), ("x + 1", 1), ("k=1", 1), ("a ≲ b", 1), ("R + L + g", 1),
        ] {
            #expect(pdf.findString(query).count == count)
        }
        let groups = [
            ["Fraction", "Limits", "Delimiters", "Extensible", "Roots", "Accents"],
            ["Alphabets", "Relations", "Arrows and braces", "Matrix", "Cases", "Aligned"],
        ]
        for (index, labels) in groups.enumerated() {
            func measurements(_ document: PDFDocument) throws -> [Double] {
                let page = try #require(document.page(at: index))
                let cuts: [CGFloat] =
                    try labels.map { label in
                        // TeX delimiter pieces can extend the bottom of a PDFKit
                        // text selection. The top of the heading remains stable.
                        let match = try #require(document.findString(label).first)
                        return match.bounds(for: page).maxY - 4
                    } + [100]
                return try zip(cuts, cuts.dropFirst()).map { top, bottom in
                    // The left labels and the body of each centred formula occupy disjoint columns.
                    try ink(page, in: CGRect(x: 215, y: bottom, width: 200, height: top - bottom))
                }
            }
            for (label, pair) in try zip(labels, zip(measurements(pdf), measurements(reference))) {
                let ratio = pair.0 / pair.1
                // The engine draws stacked delimiters and stretchy accents with its own SVG paths.
                let upperBound = ["Extensible", "Accents"].contains(label) ? 1.13 : 1.06
                #expect((0.94...upperBound).contains(ratio), "\(label) \(ratio)")
            }
        }
    }

    @Test("数式の四辺に余白があり、印刷した字形がクリップを外した紙面と一致する", .timeLimit(.minutes(1)))
    func unclippedInk() async throws {
        _ = NSApplication.shared
        let sheet = try #require(
            Bundle.module.url(forResource: "math-outlines", withExtension: "tex", subdirectory: "Fixtures"))
        let extra = #"""
            \[ \begin{pmatrix}0&-1\\1&0\end{pmatrix}\begin{bmatrix}1\\0\end{bmatrix}
               = \begin{bmatrix}0\\1\end{bmatrix}. \]
            \[ \sum_{k=1}^n k = (n+1)^2-1 \]
            \[ f_{g_j} \qquad j \qquad V \qquad \Gamma f \]
            """#
        let source = try String(contentsOf: sheet, encoding: .utf8)
            .replacingOccurrences(of: #"\end{document}"#, with: #"\newpage"# + "\n" + extra + "\n" + #"\end{document}"#)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        func printSheet(unclipped: Bool) async throws -> PDFDocument {
            // A fine stroke beyond glyph outlines makes even a tangent clip cut ink.
            var css =
                theme.css + "\n.math svg text { stroke: currentColor; stroke-width: .3px; stroke-linejoin: round; }"
            if unclipped {
                css += "\n.math svg { overflow: visible !important; } .math svg > g { clip-path: none !important; }"
            }
            let variant = PrintTheme(id: theme.id, name: theme.name, css: css, isBuiltIn: theme.isBuiltIn)
            let result = try await DocumentRenderer().prepare(
                DocumentSource(data: Data(source.utf8), format: .latex),
                settings: RenderSettings(layout: .letterSingle, theme: variant, preset: .init(id: "none", name: "")))
            return result.viewDocument
        }
        let printed = try await printSheet(unclipped: false)
        let control = try await printSheet(unclipped: true)
        try #require(printed.pageCount == 3 && control.pageCount == printed.pageCount)
        for index in 0..<printed.pageCount {
            let page = try #require(printed.page(at: index))
            let other = try #require(control.page(at: index))
            let rect = page.bounds(for: .mediaBox)
            let actual = try pixels(page, in: rect)
            let expected = try pixels(other, in: rect)
            #expect(actual.elementsEqual(expected), "page \(index + 1)")
        }
    }

    private func ink(_ page: PDFPage, in crop: CGRect) throws -> Double {
        Double(try pixels(page, in: crop).reduce(0) { $0 + Int(255 - $1) })
    }

    private func pixels(_ page: PDFPage, in crop: CGRect) throws -> Data {
        let scale = 600.0 / 72
        let width = Int(ceil(crop.width * scale))
        let height = Int(ceil(crop.height * scale))
        let bitmap = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.translateBy(x: -crop.minX, y: -crop.minY)
        bitmap.drawPDFPage(try #require(page.pageRef))
        let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        return Data(bytes: pixels, count: width * height)
    }
}
