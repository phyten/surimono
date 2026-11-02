import AppKit
import CoreText
import PDFKit
import SurimonoCore

@MainActor
public struct DuplexTestRenderer {
    public struct Labels {
        public var front: String
        public var back: String
        public var top: String
        public var binding: String
        public var printer: String
        public var instruction: String

        public init(front: String, back: String, top: String, binding: String, printer: String, instruction: String) {
            self.front = front
            self.back = back
            self.top = top
            self.binding = binding
            self.printer = printer
            self.instruction = instruction
        }
    }

    public init() {}

    public func layout(for layout: PrintLayout) throws -> PrintLayout {
        try PrintLayout(id: "duplexTest", kind: .normal, sheet: layout.sheet, duplex: layout.duplex)
    }

    public func document(sheet: PaperSize, labels: Labels) async throws -> PDFDocument {
        let size = sheet.size
        return try await PDFDrawing.document(pageSize: size) { context in
            for face in [labels.front, labels.back] {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                // Drawing the arrow avoids relying on a font's arrow glyph or fallback metrics.
                let center = size.width / 2
                let tip = size.height * 0.76
                context.move(to: CGPoint(x: center, y: tip))
                context.addLine(to: CGPoint(x: center - 55, y: tip - 70))
                context.addLine(to: CGPoint(x: center - 18, y: tip - 70))
                context.addLine(to: CGPoint(x: center - 18, y: tip - 180))
                context.addLine(to: CGPoint(x: center + 18, y: tip - 180))
                context.addLine(to: CGPoint(x: center + 18, y: tip - 70))
                context.addLine(to: CGPoint(x: center + 55, y: tip - 70))
                context.closePath()
                context.fillPath()
                draw(
                    labels.top, size: 28, in: CGRect(x: 36, y: tip + 12, width: size.width - 72, height: 55),
                    context: context)
                draw(
                    face, size: 64, in: CGRect(x: 36, y: tip - 285, width: size.width - 72, height: 90),
                    context: context)
                draw(
                    labels.binding + "\n" + labels.printer + "\n\n" + labels.instruction, size: 15,
                    in: CGRect(x: 36, y: 36, width: size.width - 72, height: max(130, tip - 340)), context: context)
                context.endPDFPage()
            }
        }
    }

    private func draw(_ text: String, size: CGFloat, in rect: CGRect, context: CGContext) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(
            setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }
}
