import AppKit
import CoreText
import SurimonoFormats

/// Review markings use the page's point coordinates, independently of the text captured by WebKit.
struct ConferenceReviewDrawing: Sendable {
    let style: LaTeXResolvedStyle.Review
    let lines: [[CGFloat]]
    let banner: String?
    let corner: String?

    private static let pt = 72.0 / 72.27

    @MainActor
    func draw(
        _ pieces: [LaTeXFlowLayout.Piece], pageIndex: Int, textOrigin: CGPoint, width: CGFloat,
        next: inout Int, in context: CGContext
    ) {
        let pt = Self.pt
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity

        func drawLabel(
            _ string: String, _ font: CTFont, x: CGFloat, y: CGFloat, alignment: CGFloat, fixedDigits: Bool = false
        ) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            // The kit aligns three tabular digit advances; Helvetica otherwise kerns adjacent ones.
            if fixedDigits { attributes[.kern] = 0 }
            let label = NSAttributedString(string: string, attributes: attributes)
            let line = CTLineCreateWithAttributedString(label)
            let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: textOrigin.x + x - advance * alignment, y: textOrigin.y - y)
            CTLineDraw(line, context)
        }

        switch style {
        case .ruler, .leftRuler:
            let leftRuler = style == .leftRuler
            let font = CTFontCreateWithName(
                (leftRuler ? "TimesNewRomanPSMT" : "Helvetica-Bold") as CFString, (leftRuler ? 10 : 8) * pt, nil)
            // The measured kit values are RGB components; Quartz grayscale uses a different transfer curve.
            let gray: CGFloat = 178.0 / 255
            context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
            let count = leftRuler ? 55 : 54
            let x = (leftRuler ? -30 : -35) * pt
            let first: CGFloat = leftRuler ? 9.64 : 5.335
            for i in 0..<count {
                drawLabel(
                    String(format: "%03d", pageIndex * count + i), font, x: x, y: first + CGFloat(i) * 12 * pt,
                    alignment: 0)
            }
        case .textLines, .blueColumnLines, .grayColumnLines:
            let columns = style != .textLines
            let blue = style == .blueColumnLines
            let font = CTFontCreateWithName(
                (columns ? "Helvetica-Bold" : "Helvetica") as CFString, (columns ? 8 : 6) * pt, nil)
            if blue {
                context.setFillColor(red: 127.0 / 255, green: 127.0 / 255, blue: 1, alpha: 1)
                if let banner { drawLabel(banner, font, x: width / 2, y: -28.01, alignment: 0.5) }
                if let corner {
                    let cornerFont = CTFontCreateWithName("Helvetica" as CFString, 9 * pt, nil)
                    drawLabel(corner, cornerFont, x: 36 - 65 * pt, y: -44.14, alignment: 0.5)
                    drawLabel(corner, cornerFont, x: width + 36 - 12 * pt, y: -44.14, alignment: 0.5)
                }
            } else if columns {
                let gray: CGFloat = 191.0 / 255
                context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
            } else {
                context.setFillColor(gray: 0, alpha: 1)
            }
            let separation = columns ? (blue ? 0.75 : 1.6) * 72 / 2.54 : 10 * pt
            forEachBaseline(in: pieces) { leading, trailing, y in
                // lineno right-aligns both labels. The outside right label has its own 10pt box.
                let x = columns && leading > 0.01 ? trailing + separation + 10 * pt : leading - separation
                drawLabel(
                    columns ? String(format: "%03d", next) : String(next), font, x: x, y: y, alignment: 1,
                    fixedDigits: columns)
                next += 1
            }
        }
    }

    @MainActor
    func forEachBaseline(in pieces: [LaTeXFlowLayout.Piece], _ visit: (CGFloat, CGFloat, CGFloat) -> Void) {
        let ratio = WebPaginator.printPixelsPerPoint
        for piece in pieces where lines.indices.contains(piece.slice.strip) {
            let positions = lines[piece.slice.strip]
            var low = 0
            var high = positions.count
            while low < high {
                let mid = (low + high) / 2
                if positions[mid] < piece.slice.start { low = mid + 1 } else { high = mid }
            }
            for y in positions[low...] {
                if y >= piece.slice.end { break }
                visit(
                    piece.x / ratio, (piece.x + piece.slice.width * piece.scale) / ratio,
                    (piece.y + (y - piece.slice.start) * piece.scale) / ratio)
            }
        }
    }
}
