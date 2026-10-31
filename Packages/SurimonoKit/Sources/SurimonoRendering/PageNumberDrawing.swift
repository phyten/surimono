import AppKit
import CoreText

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
