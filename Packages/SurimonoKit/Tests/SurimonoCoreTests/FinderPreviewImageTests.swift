import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import SurimonoCore

extension FinderPreviewTests {
    // A flat one-bit image keeps even the 5,600 px fixture inexpensive to generate.
    private func encodedImage(_ type: UTType, width: Int, height: Int, fills: [UInt8] = [0]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, type.identifier as CFString, fills.count, nil))
        let stride = (width + 7) / 8
        for fill in fills {
            let provider = try #require(CGDataProvider(data: Data(repeating: fill, count: stride * height) as CFData))
            let frame = try #require(
                CGImage(
                    width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1,
                    bytesPerRow: stride, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            CGImageDestinationAddImage(destination, frame, nil)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func still(_ attachment: FinderPreview.Attachment) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("圧縮のよい大画像 32 枚も長辺と合計画素数で制限し、残りは代替文字になる")
    func decodedBudget() throws {
        try withDirectory { directory in
            let canonical = URL(fileURLWithPath: try ConfinedFile.canonicalPath(directory), isDirectory: true)
            let png = try encodedImage(.png, width: 5600, height: 5600)
            #expect(png.count * 32 < PreviewImages.maximumBytes)
            var images = PreviewImages(directory: canonical)
            var body = ""
            for n in 1...32 {
                try png.write(to: canonical.appendingPathComponent("\(n).png"))
                body += "<img src=\"\(n).png\" alt=\"[\(n)]\">"
            }
            let html = try PreviewMarkup.clean(body) { images.source($0) }
            let count = PreviewImages.maximumTotalPixels / (PreviewImages.maximumSide * PreviewImages.maximumSide)
            #expect(images.attachments.count == count)
            var repeated = PreviewImages(directory: canonical)
            for n in 1...32 {
                #expect(repeated.source("1.png") == (n <= count ? "cid:image-1" : nil))
            }
            #expect(repeated.attachments.count == 1)
            for n in 1...32 {
                if n <= count {
                    let attachment = try #require(images.attachments["image-\(n)"])
                    let image = try still(attachment)
                    #expect(image.width == PreviewImages.maximumSide && image.height == PreviewImages.maximumSide)
                    #expect(html.contains("src=\"cid:image-\(n)\""))
                } else {
                    #expect(html.contains("[\(n)]"))
                }
            }
        }
    }

    @Test("アニメーション GIF は先頭の白いフレームだけを PNG として渡す")
    func animatedGIF() throws {
        let gif = try encodedImage(.gif, width: 16, height: 8, fills: [255, 0])
        let input = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
        #expect(CGImageSourceGetCount(input) == 2)
        var images = PreviewImages(directory: nil)
        #expect(images.source("data:image/gif;base64," + gif.base64EncodedString()) == "cid:image-1")
        let attachment = try #require(images.attachments["image-1"])
        #expect(attachment.type == .png)
        let frame = try still(attachment)
        #expect(frame.width == 16 && frame.height == 8)
        let context = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let sample = try #require(context.data)
        #expect(sample.load(as: UInt8.self) > 240)
    }

    @Test("Notebook に埋め込まれた PNG にも同じ縮小処理を適用する")
    func notebookRaster() throws {
        try withDirectory { directory in
            let image = try encodedImage(.png, width: 3200, height: 800).base64EncodedString()
            let notebook: [String: Any] = [
                "nbformat": 4, "nbformat_minor": 5,
                "cells": [
                    [
                        "cell_type": "code", "source": ["42"], "metadata": [:], "execution_count": 1,
                        "outputs": [["output_type": "display_data", "metadata": [:], "data": ["image/png": image]]],
                    ]
                ],
            ]
            let file = directory.appendingPathComponent("saved.ipynb")
            try JSONSerialization.data(withJSONObject: notebook).write(to: file)
            let preview = FinderPreview.make(for: file)
            let attachment = try #require(preview.attachments["image-1"])
            let frame = try still(attachment)
            #expect(frame.width == 1600 && frame.height == 400)
            #expect(preview.html.contains("src=\"cid:image-1\""))
        }
    }

    @Test("画像を開いた場所と実際の形式を確かめる")
    func confinedImages() throws {
        try withDirectory { directory in
            let root = directory.appendingPathComponent("document")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let png = try encodedImage(.png, width: 2, height: 2)
            try png.write(to: directory.appendingPathComponent("outside.png"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("alias"), withDestinationURL: directory)
            try png.write(to: root.appendingPathComponent("wrong.jpg"))
            try Data("plain text".utf8).write(to: root.appendingPathComponent("text.png"))
            var images = PreviewImages(
                directory: URL(fileURLWithPath: try ConfinedFile.canonicalPath(root), isDirectory: true))
            for name in [
                "%2e%2e/outside.png", "alias/outside.png", "wrong.jpg", "text.png",
                "data:image/jpeg;base64," + png.base64EncodedString(),
            ] {
                #expect(images.source(name) == nil)
            }
            #expect(images.attachments.isEmpty)
        }
    }
}
