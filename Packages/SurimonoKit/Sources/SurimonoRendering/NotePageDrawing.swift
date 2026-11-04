import CoreGraphics
import CoreText
import Foundation
import PDFKit
import SurimonoCore

@MainActor
public enum NotePageDrawing {
    public enum DrawingError: Error, Equatable {
        case emptyDocument, invalidStyle, invalidGeometry, pdfCreationFailed
    }

    public static func document(
        style: NotePaperStyle, pageSize: CGSize, pageNumbers: [Int] = [1]
    ) async throws -> PDFDocument {
        guard !pageNumbers.isEmpty else { throw DrawingError.emptyDocument }
        try validate(style: style, pageSize: pageSize)
        do {
            return try await PDFDrawing.document(pageSize: pageSize) { context in
                for number in pageNumbers {
                    try Task.checkCancellation()
                    context.beginPDFPage(nil)
                    try draw(style: style, pageSize: pageSize, pageNumber: number, in: context)
                    context.endPDFPage()
                    await Task.yield()
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DrawingError {
            throw error
        } catch {
            throw DrawingError.pdfCreationFailed
        }
    }

    public static func draw(
        style: NotePaperStyle, pageSize: CGSize, pageNumber: Int = 1, in context: CGContext
    ) throws {
        try validate(style: style, pageSize: pageSize)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: pageSize))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pageSize))
        // Millimetres keep the printed ruling independent of resolution and paper size.
        let pointsPerMillimeter = 72.0 / 25.4
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: pointsPerMillimeter, y: -pointsPerMillimeter)
        context.setLineDash(phase: 0, lengths: [])
        context.setLineCap(.butt)
        let canvas = NotePaperCanvas(
            context: context, width: pageSize.width / pointsPerMillimeter,
            height: pageSize.height / pointsPerMillimeter, style: style)
        try canvas.draw(pageNumber: pageNumber)
    }

    /// The top of a note page as a small picture for the sheet's shelves.
    /// - Parameters:
    ///   - size: The size of the picture in points of the screen.
    ///   - lineScale: How much thicker the lines are than on paper, which would all but vanish at this size.
    public static func swatch(
        style: NotePaperStyle, pageSize: CGSize, size: CGSize, lineScale: Double = 1, pixelScale: CGFloat = 2
    ) -> CGImage? {
        var style = style
        style.weightInMillimeters = min(style.weightInMillimeters * lineScale, 5)
        let width = Int((size.width * pixelScale).rounded(.up))
        let height = Int((size.height * pixelScale).rounded(.up))
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = CGFloat(width) / pageSize.width
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: CGFloat(height) / scale - pageSize.height)
        guard (try? draw(style: style, pageSize: pageSize, in: context)) != nil else { return nil }
        return context.makeImage()
    }

    private static func validate(style: NotePaperStyle, pageSize: CGSize) throws {
        // Bound density before iterating: malformed persisted settings must not stall printing.
        guard style.weightInMillimeters.isFinite, (0.01...5).contains(style.weightInMillimeters),
            style.spacingInMillimeters.isFinite, (0.5...100).contains(style.spacingInMillimeters),
            style.marginInMillimeters.isFinite, style.marginInMillimeters >= 0,
            NotePaperCanvas.color(style.colorHex) != nil
        else { throw DrawingError.invalidStyle }
        guard PDFDrawing.validGeometry(pageSize: pageSize, margin: style.marginInMillimeters * 72 / 25.4),
            pageSize.width <= 6000, pageSize.height <= 6000
        else { throw DrawingError.invalidGeometry }
        let canvasSize = CGSize(width: pageSize.width * 25.4 / 72, height: pageSize.height * 25.4 / 72)
        let box = try NotePaperCanvas.contentRect(size: canvasSize, style: style)
        let headerHeight =
            (style.header.date || style.header.title ? 10.0 : 0) + (style.decoration == .minutes ? 24 : 0)
        let spacing = style.spacingInMillimeters
        let minimum: (width: CGFloat, height: CGFloat) =
            switch style.kind {
            case .staff: (10, spacing * 1.4)
            case .genko: (max(10, spacing), spacing)
            default: (10, spacing)
            }
        let rulingHeight = box.height - headerHeight - (style.header.pageNumber ? 6 : 0)
        guard box.width + NotePaperCanvas.geometryTolerance >= minimum.width,
            rulingHeight + NotePaperCanvas.geometryTolerance >= minimum.height
        else { throw DrawingError.invalidGeometry }
    }
}

@MainActor
struct NotePaperCanvas {
    let context: CGContext
    let width: CGFloat
    let height: CGFloat
    let style: NotePaperStyle

    static func color(_ hex: String) -> CGColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6,
            digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
            let value = UInt32(digits, radix: 16), let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGColor(
            colorSpace: space,
            components: [
                CGFloat((value >> 16) & 255) / 255,
                CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255, 1,
            ])
    }

    // Unit conversion can put an exact fit just below an integer cell or staff count.
    static let geometryTolerance: CGFloat = 1e-9

    static func contentRect(size: CGSize, style: NotePaperStyle) throws -> CGRect {
        let inset: (top: CGFloat, bottom: CGFloat, side: CGFloat) =
            switch style.decoration {
            case .gingham: (21, 19, 19)
            case .ichigo: (30, 16, 0)
            case .hoshizora: (32, 18, 0)
            case .kumo: (29, 18, 0)
            case .ribbon: (32, 15, 0)
            case .nikukyu: (28, 24, 0)
            case .hana: (19, 19, 19)
            default: (0, 0, 0)
            }
        let margin = CGFloat(style.marginInMillimeters)
        let x = max(margin, inset.side)
        let y = max(margin, inset.top)
        let remainingWidth = size.width - 2 * x
        let remainingHeight = size.height - y - max(margin, inset.bottom)
        // CGRect's width and height standardize negative dimensions, hiding an exhausted page.
        guard remainingWidth > 0, remainingHeight > 0 else { throw NotePageDrawing.DrawingError.invalidGeometry }
        return CGRect(x: x, y: y, width: remainingWidth, height: remainingHeight)
    }

    func draw(pageNumber: Int) throws {
        var box = try Self.contentRect(size: CGSize(width: width, height: height), style: style)
        decorations(overlay: false)
        let ink = Self.color(style.colorHex) ?? CGColor(gray: 0.5, alpha: 1)
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.setLineWidth(style.weightInMillimeters)
        if style.header.date || style.header.title {
            if style.header.title {
                let end = style.header.date ? box.maxX - min(50, box.width * 0.42) : box.maxX
                line(box.minX, box.minY + 7, end, box.minY + 7)
                text("タイトル", x: box.minX, y: box.minY + 2, size: 2.5)
            }
            if style.header.date {
                let start = box.maxX - min(44, box.width * 0.38)
                line(start, box.minY + 7, box.maxX, box.minY + 7)
                text("年　　月　　日", x: box.maxX, y: box.minY + 2, size: 2.5, right: true)
            }
            box.origin.y += 10
            box.size.height -= 10
        }
        if style.decoration == .minutes {
            let labels = ["日時", "出席者", "議題"]
            for row in 0..<3 {
                let y = box.minY + CGFloat(row) * 8
                line(box.minX, y, box.maxX, y)
                text(labels[row], x: box.minX + 1.5, y: y + 2.7, size: 2.6)
            }
            let mid = box.minX + box.width * 0.55
            line(mid, box.minY, mid, box.minY + 8)
            text("場所", x: mid + 1.5, y: box.minY + 2.7, size: 2.6)
            line(box.minX, box.minY, box.minX, box.minY + 24)
            line(box.maxX, box.minY, box.maxX, box.minY + 24)
            line(box.minX, box.minY + 24, box.maxX, box.minY + 24)
            box.origin.y += 24
            box.size.height -= 24
        }
        if style.header.pageNumber { box.size.height -= 6 }
        context.saveGState()
        context.clip(to: box.insetBy(dx: -style.weightInMillimeters, dy: -style.weightInMillimeters))
        ruling(in: box)
        context.restoreGState()
        // Opaque motifs cover any ruling that reaches into their border.
        decorations(overlay: true)
        if style.header.pageNumber {
            text(String(pageNumber), x: box.maxX, y: box.maxY + 3, size: 2.7, right: true)
        }
    }

    func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
        context.move(to: CGPoint(x: x0, y: y0))
        context.addLine(to: CGPoint(x: x1, y: y1))
        context.strokePath()
    }

    func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, right: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "HiraginoSans-W3" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Self.color(style.colorHex)
                ?? CGColor(gray: 0.5, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: x - (right ? CTLineGetTypographicBounds(line, nil, nil, nil) : 0), y: y + size)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
    }

    private func ruling(in box: CGRect) {
        let spacing = CGFloat(style.spacingInMillimeters)
        let weight = CGFloat(style.weightInMillimeters)
        switch style.kind {
        case .plain: break
        case .ruled, .dotted, .dashed:
            if style.kind == .dotted {
                context.setLineCap(.round)
                // A dash of no length at all draws nothing on a bitmap, however round its caps.
                context.setLineDash(phase: 0, lengths: [0.01, max(weight * 3, 1)])
            } else if style.kind == .dashed {
                context.setLineDash(phase: 0, lengths: [weight * 5 + 1.6, weight * 3 + 1.2])
            }
            rows(in: box, start: box.minY + spacing, spacing: spacing)
        case .wavy:
            let wave = max(4, spacing * 0.7)
            let amplitude = min(1.1, 0.35 + spacing * 0.06)
            for y in stride(from: box.minY + spacing, through: box.maxY, by: spacing) {
                context.move(to: CGPoint(x: box.minX, y: y))
                for (index, x) in stride(from: box.minX, to: box.maxX, by: wave / 2).enumerated() {
                    context.addQuadCurve(
                        to: CGPoint(x: x + wave / 2, y: y),
                        control: CGPoint(x: x + wave / 4, y: y + (index.isMultiple(of: 2) ? -amplitude : amplitude)))
                }
                context.strokePath()
            }
        case .grid:
            let grid = CGRect(
                x: box.minX, y: box.minY, width: floor(box.width / spacing) * spacing,
                height: floor(box.height / spacing) * spacing)
            gridLines(in: grid, spacing: spacing)
            if spacing <= 6 {
                context.setLineWidth(weight * 1.8)
                gridLines(in: grid, spacing: spacing * 5)
            }
        case .dot:
            let diameter = max(weight * 1.5, 0.3)
            for y in stride(from: box.minY, through: box.maxY, by: spacing) {
                for x in stride(from: box.minX, through: box.maxX, by: spacing) {
                    context.fillEllipse(
                        in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
                }
            }
        case .cornell:
            let cue = box.minX + box.width * 0.3
            let summary = box.minY + box.height * 0.8
            rows(
                in: CGRect(x: cue, y: box.minY, width: box.maxX - cue, height: summary - box.minY - spacing * 0.5),
                start: box.minY + spacing, spacing: spacing)
            context.setLineWidth(weight * 2)
            line(cue, box.minY, cue, summary)
            line(box.minX, summary, box.maxX, summary)
            text("手がかり", x: box.minX, y: box.minY + 1.5, size: 2.5)
            text("ノート", x: cue + 2, y: box.minY + 1.5, size: 2.5)
            text("まとめ", x: box.minX, y: summary + 2, size: 2.5)
        case .genko:
            let column = spacing * 1.26
            let columns = Int(floor((box.width + spacing * 0.26 + Self.geometryTolerance) / column))
            let count = floor((box.height + Self.geometryTolerance) / spacing)
            let left = box.midX - (CGFloat(columns) * column - spacing * 0.26) / 2
            let top = box.midY - count * spacing / 2
            for index in 0..<columns {
                let rect = CGRect(x: left + CGFloat(index) * column, y: top, width: spacing, height: count * spacing)
                context.stroke(rect)
                rows(in: rect, start: top + spacing, spacing: spacing)
            }
        case .staff:
            let count = max(0, Int(floor((box.height - spacing * 1.4 + Self.geometryTolerance) / (spacing * 2.25))) + 1)
            for group in 0..<count {
                let y = box.minY + spacing * 0.4 + CGFloat(group) * spacing * 2.25
                for index in 0..<5 {
                    line(box.minX, y + CGFloat(index) * spacing / 4, box.maxX, y + CGFloat(index) * spacing / 4)
                }
                line(box.minX, y, box.minX, y + spacing)
                line(box.maxX, y, box.maxX, y + spacing)
            }
        case .table:
            let head = max(spacing, 7)
            let bottom = box.minY + head + floor((box.height - head) / spacing) * spacing
            rows(
                in: CGRect(x: box.minX, y: box.minY, width: box.width, height: bottom - box.minY),
                start: box.minY + head + spacing, spacing: spacing)
            context.setLineWidth(weight * 1.6)
            context.stroke(CGRect(x: box.minX, y: box.minY, width: box.width, height: bottom - box.minY))
            line(box.minX, box.minY + head, box.maxX, box.minY + head)
            let fractions: [CGFloat] = [0, 0.17, 0.70, 0.85]
            for (index, label) in ["日付", "内容", "担当", "期限"].enumerated() {
                let x = box.minX + box.width * fractions[index]
                if index > 0 { line(x, box.minY, x, bottom) }
                text(label, x: x + 1.8, y: box.minY + head / 2 - 1.3, size: 2.6)
            }
        }
    }

    private func rows(in box: CGRect, start: CGFloat, spacing: CGFloat) {
        for y in stride(from: start, through: box.maxY, by: spacing) { line(box.minX, y, box.maxX, y) }
    }

    private func gridLines(in box: CGRect, spacing: CGFloat) {
        rows(in: box, start: box.minY, spacing: spacing)
        for x in stride(from: box.minX, through: box.maxX, by: spacing) { line(x, box.minY, x, box.maxY) }
    }
}
