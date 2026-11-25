import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreviewImages {
    static let maximumCount = 32
    static let maximumBytes = 8_000_000
    // A codec may temporarily decode one 32 MP source. The separate 8 MP budget covers images in the reply.
    private static let maximumSourcePixels = 32_000_000
    // A 1,600 px still covers the default preview at 2x. Eight million pixels is 32 MB at four bytes per pixel.
    static let maximumSide = 1_600
    static let maximumTotalPixels = 8_000_000
    private var remainingPixels = maximumTotalPixels
    let directory: URL?
    private(set) var attachments: [String: FinderPreview.Attachment] = [:]
    private var references: [String: (id: String, pixels: Int)] = [:]
    private var attempts = 0
    private var remainingBytes = maximumBytes

    init(directory: URL?) {
        self.directory = directory
    }

    mutating func source(_ reference: String) -> String? {
        // Reuse the encoded attachment, but budget every visible occurrence at its intrinsic size.
        if let cached = references[reference] {
            guard cached.pixels <= remainingPixels else { return nil }
            remainingPixels -= cached.pixels
            return "cid:" + cached.id
        }
        guard !PreviewConversion.expired, remainingPixels > 0, remainingBytes > 0,
            attachments.count < Self.maximumCount,
            attempts < 128
        else { return nil }
        let data: Data
        let expected: UTType
        if reference.hasPrefix("data:image/") {
            guard let comma = reference.firstIndex(of: ","), reference[..<comma].hasSuffix(";base64"),
                reference.utf8.count <= (remainingBytes + 2) / 3 * 4 + 64
            else { return nil }
            let mime = reference[..<comma].dropFirst("data:".count).dropLast(";base64".count)
            guard let type = Self.mimeTypes[String(mime)] else { return nil }
            expected = type
            attempts += 1
            guard let bytes = Data(base64Encoded: String(reference[reference.index(after: comma)...])),
                bytes.count <= remainingBytes
            else { return nil }
            data = bytes
        } else {
            guard let directory, reference.utf8.count <= 4096,
                let parts = URLComponents(string: reference), parts.scheme == nil, parts.host == nil,
                !parts.path.hasPrefix("/"), !parts.path.contains("\\"), !parts.path.contains("\0"),
                !parts.path.split(separator: "/").contains(".."), !parts.path.isEmpty
            else { return nil }
            let url = directory.appendingPathComponent(parts.path)
            guard let type = Self.extensions[url.pathExtension.lowercased()] else { return nil }
            expected = type
            attempts += 1
            guard let bytes = try? ConfinedFile.read(url, within: directory.path, maximumSize: remainingBytes) else {
                return nil
            }
            data = bytes
        }
        // Release codec temporaries before considering the next attachment.
        let image = autoreleasepool { expected == .svg ? boundedSVG(data) : raster(data, expected: expected) }
        guard let (attachment, pixels) = image, pixels <= remainingPixels, attachment.data.count <= remainingBytes,
            !PreviewConversion.expired
        else { return nil }
        remainingPixels -= pixels
        let id = "image-\(attachments.count + 1)"
        remainingBytes -= attachment.data.count
        attachments[id] = attachment
        references[reference] = (id, pixels)
        return "cid:" + id
    }

    private func fitted(width: Double, height: Double) -> (width: Int, height: Int)? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let scale = min(1, Double(Self.maximumSide) / max(width, height))
        let w = min(Self.maximumSide, max(1, Int((width * scale).rounded(.up))))
        let h = min(Self.maximumSide, max(1, Int((height * scale).rounded(.up))))
        return w * h <= remainingPixels ? (w, h) : nil
    }

    private func raster(_ data: Data, expected: UTType) -> (FinderPreview.Attachment, Int)? {
        var sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false, kCGImageSourceTypeIdentifierHint: expected.identifier,
        ]
        if #available(macOS 27, *) {
            sourceOptions[kCGImageSourceAllowableTypes] =
                expected == .heif ? [expected.identifier, UTType.heic.identifier] : [expected.identifier]
        }
        // On older systems the hint is advisory. Verify the detected type before querying frame metadata.
        let options = sourceOptions as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
            type == expected || (expected == .heif && type == .heic),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= Self.maximumSourcePixels / height,
            let size = fitted(width: Double(width), height: Double(height))
        else { return nil }
        if CGImageSourceGetCount(source) == 1, max(width, height) <= Self.maximumSide {
            return (.init(data: data, type: type), width * height)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard !PreviewConversion.expired,
            let still = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
            max(still.width, still.height) <= Self.maximumSide, still.width * still.height <= remainingPixels,
            !PreviewConversion.expired
        else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, still, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= remainingBytes else { return nil }
        return (.init(data: encoded as Data, type: .png), still.width * still.height)
    }

    /// Standalone SVG is vector data. Assign a bounded intrinsic viewport, including when the file only has a viewBox.
    private func boundedSVG(_ data: Data) -> (FinderPreview.Attachment, Int)? {
        guard let text = String(data: data, encoding: .utf8),
            let clean = try? PreviewMarkup.clean(text, svgOnly: true, imageSource: { _ in nil })
                .trimmingCharacters(in: .whitespacesAndNewlines),
            clean.hasPrefix("<svg "), let end = clean.firstIndex(of: ">"),
            clean.hasSuffix("</svg>") || clean.hasSuffix("/>")
        else { return nil }
        let root = String(clean[...end])
        var width: Double?
        var height: Double?
        var box: [Double] = []
        var attributes = ""
        HTMLScanner.visitAttributes(in: root) { name, raw in
            switch name {
            case "width": width = Double(raw.hasSuffix("px") ? String(raw.dropLast(2)) : raw)
            case "height": height = Double(raw.hasSuffix("px") ? String(raw.dropLast(2)) : raw)
            case "viewbox": box = raw.split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) }
            case "style":
                // The root styles have already been sanitized. Keep text and color styling inside the viewport.
                let style = raw.split(separator: ";").filter { declaration in
                    let property = declaration.prefix { $0 != ":" }
                    return !["width", "height", "max-width", "max-height"].contains(property)
                }.joined(separator: ";")
                if !style.isEmpty { attributes += " style=\"\(style)\"" }
            default: attributes += " \(name)=\"\(raw)\""
            }
            return true
        }
        let hasBox = box.count == 4 && box.allSatisfy(\.isFinite) && box[2] > 0 && box[3] > 0
        let w = width ?? (hasBox ? box[2] : 300)
        let h = height ?? (hasBox ? box[3] : 150)
        guard let size = fitted(width: w, height: h) else { return nil }
        let viewBox = (hasBox ? box : [0, 0, w, h]).map { String($0) }.joined(separator: " ")
        let viewport = " width=\"\(size.width)\" height=\"\(size.height)\" viewBox=\"\(viewBox)\""
        let body =
            "<svg" + attributes + viewport + (root.hasSuffix("/>") ? "/>" : ">") + clean[clean.index(after: end)...]
        return (.init(data: Data(body.utf8), type: .svg), size.width * size.height)
    }

    static let extensions: [String: UTType] = [
        "png": .png, "jpg": .jpeg, "jpeg": .jpeg, "gif": .gif, "tif": .tiff, "tiff": .tiff, "bmp": .bmp,
        "webp": .webP, "heic": .heic, "heif": .heif, "svg": .svg,
    ]
    private static let mimeTypes: [String: UTType] = [
        "image/png": .png, "image/jpeg": .jpeg, "image/gif": .gif, "image/tiff": .tiff, "image/bmp": .bmp,
        "image/webp": .webP, "image/heic": .heic, "image/heif": .heif, "image/svg+xml": .svg,
    ]
}
