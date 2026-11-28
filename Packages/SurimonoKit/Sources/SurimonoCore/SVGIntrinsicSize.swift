import Foundation

/// The size an SVG file draws at by itself, in CSS pixels, read from its root element without drawing it. ImageIO
/// cannot read SVG, so an SVG opened as an image is drawn by WebKit; the paper takes its shape from this size.
public enum SVGIntrinsicSize {
    /// The size an image without dimensions takes in CSS (a replaced element's default object size).
    public static let defaultSize = CGSize(width: 300, height: 150)

    /// The root element's size, or nil when the bytes are not an SVG document.
    public static func of(_ data: Data) -> CGSize? {
        guard startsWithMarkup(data) else { return nil }
        let reader = RootReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        parser.parse()
        guard let attributes = reader.attributes else { return nil }
        return size(attributes)
    }

    /// Cheap check that keeps a parser off every photo in an image bundle: XML starts with markup.
    private static func startsWithMarkup(_ data: Data) -> Bool {
        var bytes = data.prefix(64)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let first = bytes.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return false }
        return first == UInt8(ascii: "<")
    }

    private static func size(_ attributes: [String: String]) -> CGSize {
        let width = attributes["width"].flatMap(length)
        let height = attributes["height"].flatMap(length)
        let box = attributes["viewBox"].flatMap(viewBox)
        switch (width, height, box) {
        case (let width?, let height?, _): return CGSize(width: width, height: height)
        case (let width?, nil, let box?): return CGSize(width: width, height: width * box.height / box.width)
        case (nil, let height?, let box?): return CGSize(width: height * box.width / box.height, height: height)
        case (nil, nil, let box?): return box
        case (let width?, nil, nil): return CGSize(width: width, height: defaultSize.height)
        case (nil, let height?, nil): return CGSize(width: defaultSize.width, height: height)
        case (nil, nil, nil): return defaultSize
        }
    }

    /// A length in CSS pixels. Percentages depend on a container the image does not have, so they are left out.
    static func length(_ text: String) -> CGFloat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let units: [(String, Double)] = [
            ("px", 1), ("pt", 96.0 / 72), ("pc", 16), ("in", 96), ("cm", 96 / 2.54), ("mm", 96 / 25.4),
            ("em", 16), ("ex", 8),
        ]
        var number = Substring(trimmed)
        var scale = 1.0
        if let (unit, factor) = units.first(where: { trimmed.hasSuffix($0.0) }) {
            number = number.dropLast(unit.count)
            scale = factor
        }
        guard let value = Double(number.trimmingCharacters(in: .whitespaces)) else { return nil }
        return usable(value * scale)
    }

    private static func viewBox(_ text: String) -> CGSize? {
        let parts = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
        guard parts.count == 4, let width = usable(parts[2]), let height = usable(parts[3]) else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Bounds that keep the shape's ratio meaningful when the page fits the image.
    private static func usable(_ value: Double) -> CGFloat? {
        value.isFinite && value > 0 && value <= 10_000_000 ? CGFloat(value) : nil
    }

    private final class RootReader: NSObject, XMLParserDelegate {
        var attributes: [String: String]?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            if elementName.split(separator: ":").last == "svg" { self.attributes = attributes }
            // Only the root element matters; the rest of the file is never read.
            parser.abortParsing()
        }
    }
}
