import AppKit
import CoreGraphics
import Foundation

/// Small documents built in memory for app tests; they contain no personal data.
enum TestFixtures {
    /// A PDF of empty A4 pages; the title makes the bytes, and so the content hash, differ between labels.
    static func pdf(_ label: String, pages: Int = 4) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(
                consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: label] as CFDictionary)
        else { return Data() }
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A tiny PNG in one colour; different colours give different bytes.
    static func png(red: CGFloat, green: CGFloat = 0.5, blue: CGFloat = 0.5) -> Data {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return Data() }
        let color = NSColor(deviceRed: red, green: green, blue: blue, alpha: 1)
        for x in 0..<4 {
            for y in 0..<3 { bitmap.setColor(color, atX: x, y: y) }
        }
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    /// A ZIP archive with stored (uncompressed) entries, in the given order; paths may repeat.
    static func storedZip(_ entries: [(path: String, data: Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(archive.count)
            archive.append(le32(0x0403_4B50))
            archive.append(le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0))
            archive.append(le32(crc) + le32(UInt32(entry.data.count)) + le32(UInt32(entry.data.count)))
            archive.append(le16(UInt16(name.count)) + le16(0) + name + entry.data)
            directory.append(le32(0x0201_4B50))
            directory.append(le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0))
            directory.append(le32(crc) + le32(UInt32(entry.data.count)) + le32(UInt32(entry.data.count)))
            directory.append(le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0))
            directory.append(le32(offset) + name)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x0605_4B50) + le16(0) + le16(0))
        archive.append(le16(UInt16(entries.count)) + le16(UInt16(entries.count)))
        archive.append(le32(UInt32(directory.count)) + le32(directoryOffset) + le16(0))
        return archive
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
