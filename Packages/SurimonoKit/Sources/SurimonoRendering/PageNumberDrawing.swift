import AppKit
import CoreText
import SurimonoCore

/// Shared by imposed sheets and the view-only PDF copies. Coordinates are page points, bottom-up.
@MainActor
public enum PageNumberDrawing {
    public static func draw(
        _ number: Int, in rect: CGRect, margin: CGFloat, scale: CGFloat = 1, context: CGContext
    ) {
        let text = NSAttributedString(
            string: String(number),
            attributes: [.font: NSFont.systemFont(ofSize: 8 * scale), .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.textMatrix = .identity
        // With zero margins, keep the label inside the page instead of clipping it below the media box.
        let centerY = rect.minY + max(margin / 2, (ascent + descent) / 2 + 2)
        context.textPosition = CGPoint(x: rect.midX - width / 2, y: centerY - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }
}

/// The header and footer of a page, in the same type as the plain page number.
@MainActor
enum PageFurnitureDrawing {
    private struct Row {
        let lines: [CTLine?]
        let height: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Draws above and below the text area; `margins` are in the units of `rect`.
    static func draw(
        _ lines: PageFurniture.Lines, in rect: CGRect, margins: WebPaginator.Margins, scale: CGFloat,
        context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.textMatrix = .identity
        // With no margin, the text stays inside the page instead of being cut off by its edge.
        let inset = 2 * scale
        let left = rect.minX + max(margins.left, inset)
        let right = rect.maxX - max(margins.right, inset)
        let center = rect.minX + margins.left + (rect.width - margins.left - margins.right) / 2
        func draw(_ texts: [String], centerY: (CGFloat) -> CGFloat) {
            let row = row(texts, width: right - left, scale: scale)
            let y = centerY(row.height) - (row.ascent - row.descent) / 2
            for (index, line) in row.lines.enumerated() {
                guard let line else { continue }
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                let x = index == 0 ? left : index == 1 ? center - width / 2 : right - width
                context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, context)
            }
        }
        draw(lines.top) { rect.maxY - max(margins.top / 2, $0 / 2 + 2) }
        draw(lines.bottom) { rect.minY + max(margins.bottom / 2, $0 / 2 + 2) }
    }

    /// One line of the handout's page: the text of the three places around its slot, in `space` above or below it.
    static func drawHandoutRow(
        _ texts: [String], beside rect: CGRect, above: Bool, space: CGFloat, padding: CGFloat, context: CGContext
    ) {
        let row = row(texts, width: rect.width, scale: 1)
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        let fits = space >= row.height + 2 * padding
        if !fits && above { return }
        for (index, line) in row.lines.enumerated() {
            guard let line else { continue }
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let x = index == 0 ? rect.minX : index == 1 ? rect.midX - width / 2 : rect.maxX - width
            if fits {
                let center = above ? rect.maxY + space / 2 : rect.minY - space / 2
                context.textPosition = CGPoint(x: x, y: center - (row.ascent - row.descent) / 2)
            } else {
                // The last slot has no usable footer with zero or tiny margins; white backing preserves contrast.
                let start = index == 1 ? rect.minX : x
                let backing = CGRect(
                    x: start, y: rect.minY, width: width + 2 * padding, height: row.height + 2 * padding)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(backing)
                context.textPosition = CGPoint(x: backing.minX + padding, y: backing.minY + padding + row.descent)
            }
            CTLineDraw(line, context)
        }
    }

    /// The lines of a row, each kept to its share of `width` so that long names do not run into each other.
    private static func row(_ texts: [String], width: CGFloat, scale: CGFloat) -> Row {
        let font = NSFont.systemFont(ofSize: 8 * scale)
        func line(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        }
        // What does not fit its place stays out: drawn whole, it would run into the place beside it.
        func fitted(_ text: String, to limit: CGFloat) -> CTLine? {
            guard !text.isEmpty, limit > 0 else { return nil }
            let whole = line(text)
            guard CTLineGetTypographicBounds(whole, nil, nil, nil) > limit else { return whole }
            return CTLineCreateTruncatedLine(whole, limit, .end, line("…"))
        }
        func natural(_ text: String) -> CGFloat {
            text.isEmpty ? 0 : CGFloat(CTLineGetTypographicBounds(line(text), nil, nil, nil))
        }
        let gap = 8 * scale
        let middle = fitted(
            texts[1],
            to: PageFurniture.centerLimit(left: natural(texts[0]), right: natural(texts[2]), available: width, gap: gap)
        )
        let middleWidth = middle.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
        let bothSides = !texts[0].isEmpty && !texts[2].isEmpty
        let side = middle != nil ? (width - middleWidth) / 2 - gap : bothSides ? (width - gap) / 2 : width
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line("0"), &ascent, &descent, nil)
        return Row(
            lines: [fitted(texts[0], to: side), middle, fitted(texts[2], to: side)], height: ascent + descent,
            ascent: ascent, descent: descent)
    }
}
