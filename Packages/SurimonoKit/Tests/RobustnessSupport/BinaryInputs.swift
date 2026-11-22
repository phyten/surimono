import Foundation

/// Hand-built archives, images and PDFs. They are written byte by byte rather than with system encoders so that a
/// test can put a lie in any header field (a size, a flag, a checksum) that a real encoder would never write.
package enum BinaryInputs {
    package struct ZipMember: Sendable {
        package var name: String
        package var data: [UInt8]
        package var deflates = false
        /// Overrides the uncompressed size written in both headers.
        package var declaredSize: UInt32?
        package var encrypted = false
        package var breaksChecksum = false

        package init(
            _ name: String, _ data: [UInt8], deflates: Bool = false, declaredSize: UInt32? = nil,
            encrypted: Bool = false, breaksChecksum: Bool = false
        ) {
            self.name = name
            self.data = data
            self.deflates = deflates
            self.declaredSize = declaredSize
            self.encrypted = encrypted
            self.breaksChecksum = breaksChecksum
        }
    }

    package static func zip(_ members: [ZipMember], comment: [UInt8] = []) -> [UInt8] {
        var output: [UInt8] = []
        var directory: [UInt8] = []
        for member in members {
            let name = Array(member.name.utf8)
            let stored = member.deflates ? deflate(member.data) : member.data
            var crc = crc32(member.data)
            if member.breaksChecksum { crc ^= 0xFFFF_FFFF }
            let size = member.declaredSize ?? UInt32(truncatingIfNeeded: member.data.count)
            let method: UInt16 = member.deflates ? 8 : 0
            let flags: UInt16 = member.encrypted ? 1 : 0
            let offset = UInt32(truncatingIfNeeded: output.count)
            output += le32(0x0403_4B50) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0x21)
            output += le32(crc) + le32(UInt32(truncatingIfNeeded: stored.count)) + le32(size)
            output += le16(UInt16(truncatingIfNeeded: name.count)) + le16(0) + name + stored
            directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0x21)
            directory += le32(crc) + le32(UInt32(truncatingIfNeeded: stored.count)) + le32(size)
            directory += le16(UInt16(truncatingIfNeeded: name.count)) + le16(0) + le16(0) + le16(0) + le16(0)
            directory += le32(0) + le32(offset) + name
        }
        let start = UInt32(truncatingIfNeeded: output.count)
        let count = UInt16(truncatingIfNeeded: members.count)
        output += directory
        output += le32(0x0605_4B50) + le16(0) + le16(0) + le16(count) + le16(count)
        output += le32(UInt32(truncatingIfNeeded: directory.count)) + le32(start)
        output += le16(UInt16(truncatingIfNeeded: comment.count)) + comment
        return output
    }

    /// Raw DEFLATE, as a ZIP member stores it (Apple's zlib algorithm writes no zlib header).
    package static func deflate(_ data: [UInt8]) -> [UInt8] {
        guard !data.isEmpty, let compressed = try? (Data(data) as NSData).compressed(using: .zlib) else {
            return [0x03, 0x00]
        }
        return Array(compressed as Data)
    }

    package static func png(width: UInt32, height: UInt32, idat: [UInt8]? = nil, breaksChecksum: Bool = false)
        -> [UInt8]
    {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            var crc = crc32(typed)
            if breaksChecksum && type == "IHDR" { crc ^= 1 }
            return be32(UInt32(body.count)) + typed + be32(crc)
        }
        // A 1×1 grey pixel, unless the caller passes its own (usually too short) image data.
        let pixels: [UInt8] = idat ?? zlibWrapped([0, 0x80])
        return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            + chunk("IHDR", be32(width) + be32(height) + [8, 0, 0, 0, 0]) + chunk("IDAT", pixels) + chunk("IEND", [])
    }

    package static func zlibWrapped(_ data: [UInt8]) -> [UInt8] {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return [0x78, 0x9C] + deflate(data) + be32(b << 16 | a)
    }

    /// A PDF written as text: the page tree and boxes are whatever the caller says, cross-reference offsets are
    /// computed so that only the intended part is broken.
    package static func pdf(objects: [String]) -> [UInt8] {
        var output = Array("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(output.count)
            output += Array("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let xref = output.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return output + Array(table.utf8)
    }

    package static func onePagePDF(mediaBox: String = "0 0 595 842", text: String = "PaperCrane") -> [UInt8] {
        let content = "BT /F1 24 Tf 72 720 Td (\(text)) Tj ET"
        return pdf(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox)] /Contents 4 0 R "
                + "/Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    package static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    private static func be32(_ value: UInt32) -> [UInt8] {
        (0..<4).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
}
