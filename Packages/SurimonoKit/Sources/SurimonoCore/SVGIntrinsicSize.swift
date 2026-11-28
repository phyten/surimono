import Foundation

/// The size an SVG file draws at by itself, in CSS pixels, read from its root element without drawing it. ImageIO
/// cannot read SVG, so an SVG opened as an image is drawn by WebKit; the paper takes its shape from this size.
public enum SVGIntrinsicSize {
    /// What reading the bytes as SVG found. Bytes that do not start with markup are no SVG and get no reading.
    public enum Reading: Equatable, Sendable {
        case size(CGSize)
        case unusable(Problem)
    }

    public enum Problem: Equatable, Sendable {
        /// Over `maximumBytes`; refused before any parsing.
        case tooLarge
        /// Not an SVG root within `prologLimit`, or a size that is not a finite, positive number in range.
        case unreadable
        /// Draws more than `SVGComplexity.maximumDrawnElements` once references are followed, or refers to itself.
        case tooComplex
    }

    /// The size an image without dimensions takes in CSS (a replaced element's default object size).
    public static let defaultSize = CGSize(width: 300, height: 150)
    /// Larger files are refused before they are parsed or copied into a page as a data URL.
    public static let maximumBytes = 50_000_000
    /// The root element has to start within this many bytes, so the parse is a small, bounded piece of work.
    static let prologLimit = 65_536
    static let largestSide: CGFloat = 10_000_000
    static let namespace = "http://www.w3.org/2000/svg"

    /// The root element's size, or nil when the bytes are no usable SVG document.
    public static func of(_ data: Data) -> CGSize? {
        if case .size(let size)? = read(data) { return size }
        return nil
    }

    /// Nil for bytes that are not markup, which ImageIO may still decode. Markup is never an image ImageIO reads, so
    /// anything else that is not a usable SVG is unusable rather than passed on.
    public static func read(_ data: Data) -> Reading? {
        guard let start = markupStart(data) else { return nil }
        guard data.count <= maximumBytes else { return .unusable(.tooLarge) }
        let reader = RootReader()
        let parser = XMLParser(data: data.prefix(start + prologLimit))
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        parser.parse()
        guard let attributes = reader.attributes, let size = size(attributes), usable(size) else {
            return .unusable(.unreadable)
        }
        guard SVGComplexity.withinLimit(data) else { return .unusable(.tooComplex) }
        return .size(size)
    }

    /// Whether a computed size (or a rectangle fitted from it) can place an image on paper.
    public static func usable(_ size: CGSize) -> Bool {
        [size.width, size.height].allSatisfy { $0.isFinite && $0 > 0 && $0 <= largestSide }
    }

    /// Where the markup starts after a byte order mark and white space, or nil when the bytes start with something
    /// else. UTF-16 documents are recognised by their mark; their white space is two bytes wide.
    private static func markupStart(_ data: Data) -> Int? {
        let bytes = data.prefix(prologLimit)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let littleEndian = bytes.starts(with: [0xFF, 0xFE])
            var index = bytes.startIndex + 2
            while index + 1 < bytes.endIndex {
                let unit = littleEndian ? bytes[index] : bytes[index + 1]
                let high = littleEndian ? bytes[index + 1] : bytes[index]
                if high != 0 { return nil }
                if unit == UInt8(ascii: "<") { return index - bytes.startIndex }
                guard [0x20, 0x09, 0x0A, 0x0D].contains(unit) else { return nil }
                index += 2
            }
            return nil
        }
        var index = bytes.startIndex
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index += 3 }
        while index < bytes.endIndex {
            if bytes[index] == UInt8(ascii: "<") { return index - bytes.startIndex }
            guard [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) else { return nil }
            index += 1
        }
        return nil
    }

    private static func size(_ attributes: [String: String]) -> CGSize? {
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
        guard let value = decimal(number.trimmingCharacters(in: .whitespaces)) else { return nil }
        return usable(value * scale)
    }

    /// Exactly four finite numbers, or none: a token that is not a number is not dropped to make four.
    private static func viewBox(_ text: String) -> CGSize? {
        let tokens = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        let numbers = tokens.compactMap { decimal(String($0)) }
        guard tokens.count == 4, numbers.count == 4, let width = usable(numbers[2]), let height = usable(numbers[3])
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// A finite decimal number as SVG writes one; Swift would also read hexadecimal, "nan" and "inf".
    private static func decimal(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ "0123456789.eE+-".contains($0) }), let value = Double(text),
            value.isFinite
        else { return nil }
        return value
    }

    private static func usable(_ value: Double) -> CGFloat? {
        value > 0 && value <= Double(largestSide) ? CGFloat(value) : nil
    }

    private final class RootReader: NSObject, XMLParserDelegate {
        var attributes: [String: String]?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            // WebKit draws only an `svg` root in the SVG namespace, so nothing else is given a page.
            if elementName == "svg", namespaceURI == SVGIntrinsicSize.namespace { self.attributes = attributes }
            // Only the root element matters; the rest of the file is never read.
            parser.abortParsing()
        }
    }
}
