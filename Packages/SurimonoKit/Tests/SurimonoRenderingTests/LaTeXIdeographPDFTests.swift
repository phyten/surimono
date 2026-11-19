import CoreText
import PDFKit
import SurimonoCore
import Testing

@MainActor
struct LaTeXIdeographPDFTests {
    @Test("中国語スタイルが指定する代替書体は、字形だけを PDF に描いても元の漢字を抽出できる")
    func glyphOnlyPDF() throws {
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-zh" })
        let text = (0x2F00...0x2FD5).compactMap { UnicodeScalar($0) }.map {
            String($0).precomposedStringWithCompatibilityMapping
        }.joined()
        let characters = Array(text.utf16)
        let page = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(text), format: .latex, theme: style)
        let rules = page.matches(
            of: /@font-face \{\s*font-family: "Surimono (?:Song SC|Song TC|Hei|Mincho) Ideographs"; src: ([^;]+);/)
        #expect(!rules.isEmpty)
        for rule in rules {
            let names = rule.1.matches(of: /local\("([^"]+)"\)/).map { String($0.1) }
            let font = try #require(
                names.lazy.compactMap { name -> CTFont? in
                    let font = CTFontCreateWithName(name as CFString, 16, nil)
                    return CTFontCopyPostScriptName(font) as String == name ? font : nil
                }.first)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            #expect(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
            let positions = characters.indices.map { CGPoint(x: 8 + 16 * $0, y: 16) }
            let data = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: data))
            var box = CGRect(x: 0, y: 0, width: CGFloat(16 * characters.count + 16), height: 48)
            let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            // Drawing an attributed CTLine would also supply the source string and mask the font's reverse mapping.
            CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)
            context.endPDFPage()
            context.closePDF()
            #expect(PDFDocument(data: data as Data)?.page(at: 0)?.string == text)
        }
    }
}
