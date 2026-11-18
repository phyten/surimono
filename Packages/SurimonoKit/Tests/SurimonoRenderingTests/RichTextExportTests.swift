import AppKit
import JavaScriptCore
import Testing

@testable import SurimonoRendering

@MainActor
struct RichTextExportTests {
    @Test("貼り付け用の書式は紙幅・背景・埋め込み書体を持たず表とコードを整える")
    func stylesheet() {
        let css = RichTextExport.styleSheet
        for expected in ["color: black", "underline", "0.5pt solid", "Menlo", "2em"] {
            #expect(css.contains(expected))
        }
        for excluded in ["background", "max-width", "@font-face", "@page"] {
            #expect(!css.contains(excluded))
        }
    }

    @Test("装飾を数えず400個までを画像にして残りは数式や図の代替文字にする")
    func selection() throws {
        let js = try #require(JSContext())
        js.evaluateScript(
            """
            let replacements = [], removed = 0, nodes = [];
            const document = {body:{querySelectorAll: () => nodes}, createElement: () => ({})};
            function add(label, title, icon=false) {
              nodes.push({getAttribute:()=>label,querySelector:()=>({textContent:title}),
                matches:()=>icon, closest:()=>null,getBoundingClientRect:()=>({width:10,height:10}),
                replaceWith:span=>replacements.push(span.textContent),remove:()=>removed++});
            }
            add('', '', true);
            for (let i=0;i<400;i++) add('x','');
            add(' x^2 ',''); add(null,' Figure '); add(null,'');
            """)
        let count = js.evaluateScript("(function(limit){\(RichTextGraphics.selection)})(\(RichTextGraphics.limit))")
        #expect(count?.toInt32() == 400)
        #expect(js.evaluateScript("removed").toInt32() == 1)
        #expect(js.evaluateScript("replacements.join('|')").toString() == "x^2|Figure|diagram")
        #expect(WebGraphicSnapshot.scale(for: CGSize(width: 25, height: 10)) == 2)
        #expect(WebGraphicSnapshot.scale(for: CGSize(width: 10, height: 8000)) == 0.5)
    }

    @Test("同名の添付を表示寸法で別名にし書式付きの本文に代替文字を残す")
    func attachments() throws {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let text = NSMutableAttributedString(string: "")
        for _ in 0..<2 {
            let file = FileWrapper(regularFileWithContents: data)
            file.preferredFilename = "unknown.png"
            text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: file)))
        }
        let plain = try RichTextExport.prepare(
            text,
            figures: [
                RichTextFigure(size: CGSize(width: 20, height: 10), alt: "x"),
                RichTextFigure(size: CGSize(width: 16, height: 8), alt: "y"),
            ])
        #expect(plain.string == "xy")
        for (i, name, width) in [(0, "image-001.png", 20.0), (1, "image-002.png", 16.0)] {
            let a = try #require(text.attribute(.attachment, at: i, effectiveRange: nil) as? NSTextAttachment)
            #expect(a.fileWrapper?.preferredFilename == name)
            #expect(a.bounds.size == CGSize(width: width, height: width / 2))
        }
        let wrapper = try text.fileWrapper(
            from: NSRange(location: 0, length: 2),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtfd
            ])
        #expect(Set(wrapper.fileWrappers?.keys.map { $0 } ?? []) == ["TXT.rtf", "image-001.png", "image-002.png"])
        let flat = try #require(wrapper.serializedRepresentation)
        let readback = try #require(NSAttributedString(rtfd: flat, documentAttributes: nil))
        for (i, width) in [(0, 20.0), (1, 16.0)] {
            let a = try #require(readback.attribute(.attachment, at: i, effectiveRange: nil) as? NSTextAttachment)
            let size = a.bounds.isEmpty ? a.attachmentCell?.cellSize() : a.bounds.size
            let display = try #require(size)
            #expect(abs(display.width - width) <= 1)
            #expect(abs(display.height - width / 2) <= 1)
        }
    }
}
