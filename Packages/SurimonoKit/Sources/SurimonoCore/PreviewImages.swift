import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreviewImages {
    static let maximumCount = 32
    static let maximumBytes = 8_000_000
    let directory: URL?
    private(set) var attachments: [String: FinderPreview.Attachment] = [:]
    private var references: [String: String] = [:]
    private var attempts = 0
    private var remaining = maximumBytes

    init(directory: URL?) {
        self.directory = directory
    }

    mutating func source(_ reference: String) -> String? {
        if let id = references[reference] { return "cid:" + id }
        guard remaining > 0, attachments.count < Self.maximumCount, attempts < 128 else { return nil }
        let data: Data
        let isSVG: Bool
        if reference.hasPrefix("data:image/") {
            guard let comma = reference.firstIndex(of: ","), reference[..<comma].hasSuffix(";base64"),
                reference.utf8.count <= (remaining + 2) / 3 * 4 + 64
            else { return nil }
            attempts += 1
            guard let bytes = Data(base64Encoded: String(reference[reference.index(after: comma)...])),
                bytes.count <= remaining
            else { return nil }
            data = bytes
            isSVG = reference[..<comma] == "data:image/svg+xml;base64"
        } else {
            guard let directory, reference.utf8.count <= 4096,
                let parts = URLComponents(string: reference), parts.scheme == nil, parts.host == nil,
                !parts.path.hasPrefix("/"), !parts.path.contains("\\"), !parts.path.contains("\0"),
                !parts.path.split(separator: "/").contains(".."), !parts.path.isEmpty
            else { return nil }
            let url = directory.appendingPathComponent(parts.path)
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            attempts += 1
            guard let bytes = try? ConfinedFile.read(url, within: directory.path, maximumSize: remaining) else {
                return nil
            }
            data = bytes
            isSVG = url.pathExtension.lowercased() == "svg"
        }
        let attachment: FinderPreview.Attachment
        if isSVG {
            guard let text = String(data: data, encoding: .utf8),
                let clean = try? PreviewMarkup.clean(text, svgOnly: true, imageSource: { _ in nil })
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                clean.hasPrefix("<svg "), clean.hasSuffix("</svg>") || clean.hasSuffix("/>"),
                clean.utf8.count <= remaining
            else { return nil }
            attachment = .init(data: Data(clean.utf8), type: .svg)
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let identifier = CGImageSourceGetType(source) as String?,
                let type = UTType(identifier), Self.rasterTypes.contains(type),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0, width <= 32_000_000 / height
            else { return nil }
            attachment = .init(data: data, type: type)
        }
        let id = "image-\(attachments.count + 1)"
        remaining -= attachment.data.count
        attachments[id] = attachment
        references[reference] = id
        return "cid:" + id
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "webp", "heic", "heif", "svg",
    ]
    private static let rasterTypes: Set<UTType> = [.png, .jpeg, .gif, .tiff, .bmp, .webP, .heic, .heif]
}
