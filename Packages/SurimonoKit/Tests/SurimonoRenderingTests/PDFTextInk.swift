import PDFKit
import Testing

// PDFKit's selection bounds include the font's ascenders and descenders even for a single dot.
// Sample just the selected word in page coordinates so the test measures the printed outline.
@MainActor
func printedInk(of text: String, in pdf: PDFDocument, on page: PDFPage) throws -> CGRect {
    let selection = try #require(pdf.findString(text).first { $0.pages.contains(page) })
    let rect = selection.bounds(for: page).insetBy(dx: -0.25, dy: 0)
    let scale: CGFloat = 10
    let width = Int(ceil(rect.width * scale))
    let height = Int(ceil(rect.height * scale))
    var pixels = [UInt8](repeating: 255, count: width * height)
    try pixels.withUnsafeMutableBytes { buffer in
        let context = try #require(
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .mediaBox, to: context)
    }
    var ink = CGRect.null
    for (index, pixel) in pixels.enumerated() where pixel < 160 {
        ink = ink.union(CGRect(x: index % width, y: height - 1 - index / width, width: 1, height: 1))
    }
    try #require(!ink.isNull)
    return CGRect(
        x: rect.minX + ink.minX / scale, y: rect.minY + ink.minY / scale,
        width: ink.width / scale, height: ink.height / scale)
}
