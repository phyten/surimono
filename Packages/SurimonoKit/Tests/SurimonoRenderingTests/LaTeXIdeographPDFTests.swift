import CoreText
import PDFKit
import SurimonoCore
import Testing

@MainActor
struct LaTeXIdeographPDFTests {
    @Test("中国語スタイルが指定する代替書体は、字形だけを PDF に描いても元の漢字を抽出できる", .timeLimit(.minutes(1)))
    func glyphOnlyPDF() throws {
        let started = ContinuousClock.now
        func phase(_ name: String) { print("ideograph \(name) \(ContinuousClock.now - started)") }
        let style = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-zh" })
        let text = (0x2F00...0x2FD5).compactMap { UnicodeScalar($0) }.map {
            String($0).precomposedStringWithCompatibilityMapping
        }.joined()
        let characters = Array(text.utf16)
        let page = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(text), format: .latex, theme: style)
        phase("page \(page.utf8.count) bytes")
        // The generated page includes megabytes of base64 fonts. Scan for the literal CSS prefix with ICU;
        // only the short src declarations need Swift string captures.
        let pattern = try NSRegularExpression(
            pattern:
                #"@font-face \{\s*font-family: "Surimono (?:Song SC|Song TC|Hei|Mincho) Ideographs"; src: ([^;]+);"#)
        let html = page as NSString
        let rules = pattern.matches(in: page, range: NSRange(location: 0, length: html.length))
        try #require(!rules.isEmpty)
        phase("CSS matched \(rules.count) rules")
        // Looking up a missing face by name may wait for Core Text font auto-activation on a fresh Mac.
        let available = Set(try #require(CTFontManagerCopyAvailablePostScriptNames() as? [String]))
        var tested = Set<String>()
        phase("inventory read")
        for rule in rules {
            let candidates = html.substring(with: rule.range(at: 1))
            let names = candidates.matches(of: /local\("([^"]+)"\)/).map { String($0.1) }
            let name = try #require(names.first { available.contains($0) }, "インストール済みの候補なし: \(names)")
            // Several CSS rules resolve to the same installed face. Its glyph-to-Unicode map is identical.
            guard tested.insert(name).inserted else { continue }
            phase("lookup \(name)")
            let font = CTFontCreateWithNameAndOptions(
                name as CFString, 16, nil, [.preventAutoActivation, .preventAutoDownload])
            try #require(CTFontCopyPostScriptName(font) as String == name)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            #expect(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
            let positions = characters.indices.map { CGPoint(x: 8 + 16 * $0, y: 16) }
            let data = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: data))
            var box = CGRect(x: 0, y: 0, width: CGFloat(16 * characters.count + 16), height: 48)
            let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            phase("draw")
            context.beginPDFPage(nil)
            // Drawing an attributed CTLine would also supply the source string and mask the font's reverse mapping.
            CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)
            context.endPDFPage()
            context.closePDF()
            phase("extract")
            let extracted = PDFDocument(data: data as Data)?.page(at: 0)?.string
            #expect(extracted == text, "書体 \(name)")
            phase("verified")
        }
    }
}
