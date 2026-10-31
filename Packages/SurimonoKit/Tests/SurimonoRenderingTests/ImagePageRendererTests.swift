import Foundation
import ImageIO
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct ImagePageRendererTests {
    @Test("8000×6000画像の埋め込み画素数を配置領域の300dpi以下に抑える")
    func limitsLargeImageResolution() async throws {
        let data = try largeImage()
        let result = try await ImagePageRenderer().render(data, pageSize: PaperSize.a4.size)
        let size = try #require(embeddedImageSizes(in: result).first)
        // A4 minus 15 mm on each edge fits a 4:3 image in 180 × 135 mm.
        #expect(size.width > 2100 && size.width <= 2126)
        #expect(size.height > 1575 && size.height <= 1595)
    }

    @Test("EXIFと用紙の自動回転を考慮した配置領域で解像度を制限する", arguments: [1, 6])
    func limitsOrientedImageResolution(orientation: Int) async throws {
        let data = try largeImage(orientation: orientation)
        let result = try await ImagePageRenderer().render(data, pageSize: PaperSize.a4.size, autoRotatesPage: true)
        let size = try #require(embeddedImageSizes(in: result).first)
        // Both orientations fit in 240 × 180 mm, with axes swapped for EXIF 6.
        let longEdge = max(size.width, size.height)
        let shortEdge = min(size.width, size.height)
        #expect(longEdge > 2800 && longEdge <= 2835)
        #expect(shortEdge > 2100 && shortEdge <= 2126)
        #expect(orientation == 1 ? size.width > size.height : size.width < size.height)
    }

    @Test("小さい画像の埋め込み画素数を拡大しない", arguments: [1, 6])
    func preservesSmallImageResolution(orientation: Int) async throws {
        let result = try await ImagePageRenderer().render(
            RenderingFixtures.image(orientation: orientation), pageSize: PaperSize.a4.size)
        let sizes = try embeddedImageSizes(in: result)
        #expect(sizes == [orientation == 1 ? CGSize(width: 80, height: 40) : CGSize(width: 40, height: 80)])
    }

    @Test("キャンセル済みの画像描画はCancellationErrorを返す")
    func cancellation() async throws {
        let data = try RenderingFixtures.image()
        let task = Task {
            _ = try await ImagePageRenderer().render(data, pageSize: PaperSize.a4.size)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func largeImage(orientation: Int = 1) throws -> Data {
        try autoreleasepool {
            let context = try #require(
                CGContext(
                    data: nil, width: 8000, height: 6000, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 8000, height: 6000))
            let image = try #require(context.makeImage())
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
    }

    private func embeddedImageSizes(in document: PDFDocument) throws -> [CGSize] {
        let page = try #require(document.page(at: 0)?.pageRef)
        let dictionary = try #require(page.dictionary)
        var resources: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        var objects: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(try #require(resources), "XObject", &objects))
        let imageObjects = try #require(objects)
        var sizes: [CGSize] = []
        withUnsafeMutablePointer(to: &sizes) { pointer in
            CGPDFDictionaryApplyFunction(
                imageObjects,
                { _, object, info in
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                        let dictionary = CGPDFStreamGetDictionary(stream), let info
                    else { return }
                    var width: CGPDFInteger = 0
                    var height: CGPDFInteger = 0
                    if CGPDFDictionaryGetInteger(dictionary, "Width", &width),
                        CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                    {
                        info.assumingMemoryBound(to: [CGSize].self).pointee.append(CGSize(width: width, height: height))
                    }
                }, pointer)
        }
        #expect(sizes.count == 1)
        return sizes
    }

    @Test("画像を余白内で縦横比を保って最大化し中央に置く")
    func fitsImage() async throws {
        let result = try await ImagePageRenderer().render(
            RenderingFixtures.image(), pageSize: CGSize(width: 200, height: 300), marginsInMillimeters: 25.4 / 72 * 20)
        #expect(result.pageCount == 1)
        let page = try #require(result.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 200, height: 300))
        let red = try RenderingFixtures.pixel(page, x: 25, y: 150)
        let blue = try RenderingFixtures.pixel(page, x: 175, y: 150)
        #expect(red[0] > 240 && red[1] < 20 && red[2] < 20, "red: \(red)")
        #expect(blue[0] < 20 && blue[1] < 20 && blue[2] > 240, "blue: \(blue)")
        #expect(try RenderingFixtures.pixel(page, x: 100, y: 100)[0...2] == [255, 255, 255])
        #expect(try RenderingFixtures.pixel(page, x: 10, y: 150)[0...2] == [255, 255, 255])
    }

    @Test("画像と余白の範囲をページの内容の枠にし、縦横比の違いで余る用紙を含めない", arguments: [0, 20])
    func contentBox(marginInPoints: Double) async throws {
        let result = try await ImagePageRenderer().render(
            RenderingFixtures.image(), pageSize: CGSize(width: 200, height: 300),
            marginsInMillimeters: 25.4 / 72 * marginInPoints)
        let page = try #require(result.page(at: 0))
        // The 2:1 image fills the width inside the margins and leaves paper above and below it.
        let imageHeight = (200 - 2 * marginInPoints) / 2
        let expected = CGRect(
            x: 0, y: 150 - imageHeight / 2 - marginInPoints, width: 200, height: imageHeight + 2 * marginInPoints)
        let box = page.bounds(for: .artBox)
        #expect(abs(box.minX - expected.minX) < 0.01 && abs(box.minY - expected.minY) < 0.01)
        #expect(abs(box.width - expected.width) < 0.01 && abs(box.height - expected.height) < 0.01)
        #expect(page.bounds(for: .cropBox).size == CGSize(width: 200, height: 300))
    }

    @Test("EXIF適用後に横長の画像だけページを横置きにする", arguments: [1, 6, 8])
    func orientation(value: Int) async throws {
        let result = try await ImagePageRenderer().render(
            RenderingFixtures.image(orientation: value), pageSize: CGSize(width: 200, height: 300),
            marginsInMillimeters: 0, autoRotatesPage: true)
        let page = try #require(result.page(at: 0))
        #expect(
            page.bounds(for: .mediaBox).size
                == (value == 1 ? CGSize(width: 300, height: 200) : CGSize(width: 200, height: 300)))
        if value != 1 {
            let top = try RenderingFixtures.pixel(page, x: 100, y: 250)
            #expect(value == 6 ? top[0] > 240 : top[2] > 240)
        }
    }

    @Test("複数フレームのTIFFから先頭の1ページだけを作る")
    func firstFrame() async throws {
        let result = try await ImagePageRenderer().render(
            RenderingFixtures.image(frames: 2), pageSize: CGSize(width: 200, height: 300))
        #expect(result.pageCount == 1)
    }

    @Test("EXIFの左右反転を画像に適用する")
    func mirrored() async throws {
        let result = try await ImagePageRenderer().render(
            RenderingFixtures.image(orientation: 2), pageSize: CGSize(width: 200, height: 100), marginsInMillimeters: 0)
        let page = try #require(result.page(at: 0))
        let left = try RenderingFixtures.pixel(page, x: 20, y: 50)
        let right = try RenderingFixtures.pixel(page, x: 180, y: 50)
        #expect(left[2] > 240 && left[0] < 20)
        #expect(right[0] > 240 && right[2] < 20)
    }

    @Test("破損画像と描画領域のない余白を拒否する")
    func invalidInput() async throws {
        await #expect(throws: ImagePageRenderer.RenderingError.invalidImage) {
            _ = try await ImagePageRenderer().render(Data([0, 1]), pageSize: CGSize(width: 200, height: 300))
        }
        let data = try RenderingFixtures.image()
        await #expect(throws: ImagePageRenderer.RenderingError.invalidGeometry) {
            _ = try await ImagePageRenderer().render(
                data, pageSize: CGSize(width: 200, height: 300), marginsInMillimeters: 100)
        }
    }
}
