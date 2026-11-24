import PDFKit
import Testing

func baseFonts(in pageData: Data) -> [String] {
    let names = String(decoding: pageData, as: UTF8.self).matches(
        of: #/\/BaseFont\s*\/(?:[A-Z]{6}\+)?([^/\s<>]+)/#)
    return Set(names.map { String($0.output.1) }).sorted()
}

enum PrintedInkColor { case any, chromatic, black }

// PDFKit's selection bounds include the font's ascenders and descenders even for a single dot.
// Sample just the selected word in page coordinates so the test measures the printed outline.
@MainActor
func printedInk(
    of text: String, in pdf: PDFDocument, on page: PDFPage, scale: CGFloat = 10, color: PrintedInkColor = .any
) throws -> CGRect {
    let selection = try #require(pdf.findString(text).first { $0.pages.contains(page) })
    let rect = selection.bounds(for: page).insetBy(dx: -0.25, dy: 0)
    return try printedInk(in: rect, on: page, scale: scale, color: color)
}

@MainActor
func printedInk(
    in rect: CGRect, on page: PDFPage, scale: CGFloat = 10, color: PrintedInkColor = .any
) throws -> CGRect {
    let width = Int(ceil(rect.width * scale))
    let height = Int(ceil(rect.height * scale))
    let stride = color == .any ? 1 : 4
    var pixels = [UInt8](repeating: 255, count: width * height * stride)
    try pixels.withUnsafeMutableBytes { buffer in
        let context = try #require(
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * stride,
                space: color == .any ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: (color == .any ? CGImageAlphaInfo.none : .premultipliedLast).rawValue))
        context.scaleBy(x: scale, y: scale)
        // Selections use page coordinates, while PDFPage.draw already removes the media box origin.
        let box = page.bounds(for: .mediaBox)
        context.translateBy(x: box.minX - rect.minX, y: box.minY - rect.minY)
        page.draw(with: .mediaBox, to: context)
    }
    var left = width
    var top = height
    var right = -1
    var bottom = -1
    for index in 0..<(width * height) {
        let offset = index * stride
        switch color {
        case .any: guard pixels[offset] < 160 else { continue }
        case .black, .chromatic:
            let channels = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
            let hi = max(channels.0, channels.1, channels.2)
            let lo = min(channels.0, channels.1, channels.2)
            guard color == .black ? hi < 160 && hi - lo < 32 : hi - lo > 50 else { continue }
        }
        let row = index / width
        let column = index % width
        left = min(left, column)
        right = max(right, column)
        top = min(top, row)
        bottom = max(bottom, row)
    }
    try #require(right >= left, "ink=\(color) box=\(rect)")
    return CGRect(
        x: rect.minX + CGFloat(left) / scale, y: rect.minY + CGFloat(height - bottom - 1) / scale,
        width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
}
