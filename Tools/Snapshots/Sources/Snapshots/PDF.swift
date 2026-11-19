import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum Imaging {
    static let dpi = 100.0
    static let space = CGColorSpace(name: CGColorSpace.sRGB)
    static let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    static func draw(_ w: Int, _ h: Int, paint: (CGContext) -> Void) throws -> Raster {
        guard w > 0, h > 0, w <= 20000, h <= 20000, w * h <= 60_000_000, let space else {
            throw SnapshotError("Unsupported image dimensions \(w) × \(h)")
        }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard
                let ctx = CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: space, bitmapInfo: info)
            else { throw SnapshotError("Cannot allocate bitmap") }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            paint(ctx)
        }
        return try Raster(width: w, height: h, bytes: bytes)
    }
    static func load(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw SnapshotError("Invalid PNG: \(url.lastPathComponent)") }
        return try draw(image.width, image.height) {
            $0.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }
    static func save(_ raster: Raster, _ url: URL) throws {
        guard let space, let provider = CGDataProvider(data: Data(raster.bytes) as CFData),
            let image = CGImage(
                width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: raster.width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw SnapshotError("Cannot create \(url.lastPathComponent)") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotError("Cannot finish \(url.lastPathComponent)") }
    }
}

struct PDFInput {
    let pdf: PDFDocument
    init(_ url: URL) throws {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else {
            throw SnapshotError("Unreadable PDF: \(url.lastPathComponent)")
        }
        self.pdf = pdf
    }
    private func geometry(_ index: Int) throws -> (PDFPage, CGPDFPage, CGRect, CGAffineTransform) {
        guard let page = pdf.page(at: index), let ref = page.pageRef else {
            throw SnapshotError("Missing PDF page \(index+1)")
        }
        let crop = ref.getBoxRect(.cropBox)
        let rotated = abs(Int(ref.rotationAngle)) % 180 == 90
        let rect = CGRect(origin: .zero, size: rotated ? CGSize(width: crop.height, height: crop.width) : crop.size)
        guard rect.width > 0, rect.height > 0, rect.width <= 14400, rect.height <= 14400 else {
            throw SnapshotError("Unsupported PDF page size")
        }
        return (page, ref, rect, ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
    }
    func raster(_ index: Int) throws -> Raster {
        let (_, ref, rect, transform) = try geometry(index)
        let scale = Imaging.dpi / 72
        return try Imaging.draw(Int(ceil(rect.width * scale)), Int(ceil(rect.height * scale))) { ctx in
            ctx.translateBy(x: 0, y: ceil(rect.height * scale) - rect.height * scale)
            ctx.scaleBy(x: scale, y: scale)
            ctx.clip(to: rect)
            ctx.concatenate(transform)
            ctx.drawPDFPage(ref)
        }
    }
    func document() throws -> Document {
        var pages: [Page] = []
        var fonts = Set<String>()
        for i in 0..<pdf.pageCount {
            let (page, _, rect, transform) = try geometry(i)
            var lines: [Line] = []
            var box = CGRect.null
            if let text = page.attributedString {
                text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    if let font = value as? NSFont { fonts.insert(font.fontName) }
                }
            }
            if page.numberOfCharacters > 0,
                let all = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))
            {
                for selection in all.selectionsByLine() {
                    let text = normalized(selection.string ?? "")
                    guard !text.isEmpty else { continue }
                    let bounds = selection.bounds(for: page).applying(transform)
                    guard !bounds.isNull, !bounds.isInfinite else { throw SnapshotError("Invalid PDF line bounds") }
                    let r = CGRect(
                        x: bounds.minX, y: rect.height - bounds.maxY, width: bounds.width, height: bounds.height)
                    box = box.union(r)
                    lines.append(
                        Line(text: text, x: pt(r.minX), y: pt(r.minY), width: pt(r.width), height: pt(r.height)))
                }
            }
            pages.append(
                Page(
                    width: pt(rect.width), height: pt(rect.height), textLeft: box.isNull ? nil : pt(box.minX),
                    textTop: box.isNull ? nil : pt(box.minY), textWidth: box.isNull ? nil : pt(box.width),
                    textHeight: box.isNull ? nil : pt(box.height), firstY: lines.first?.y, lastY: lines.last?.y,
                    lineCount: lines.count, lines: lines))
        }
        var result = Document(pages: pages, pageCount: pages.count, textSHA256: "", fonts: fonts.sorted())
        result.textSHA256 = digest(Data(result.text.utf8))
        return result
    }
}
