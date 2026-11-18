import Foundation

struct NotebookImage: Sendable {
    static let mimeTypes = ["image/png", "image/jpeg", "image/gif", "image/svg+xml"]
    let mime: String
    let source: String
    var uri: String {
        let encoded = mime == "image/svg+xml" ? Data(source.utf8).base64EncodedString() : source
        return "data:\(mime);base64,\(encoded)"
    }

    static func first(in bundle: [String: Any]) -> Self? {
        for mime in mimeTypes {
            if let value = bundle[mime], value is String || value is [String] {
                return Self(mime: mime, source: NotebookConverter.string(value))
            }
        }
        return nil
    }

    func html(metadata: [String: Any]) -> String {
        let size = dimensions
        let own = metadata[mime] as? [String: Any] ?? metadata
        func dimension(_ key: String, natural: Double?) -> Double? {
            guard let value = own[key] as? NSNumber, value.doubleValue.isFinite, value.doubleValue > 0 else {
                return natural
            }
            return min(value.doubleValue, natural.map { $0 * 2 } ?? value.doubleValue)
        }
        let width = dimension("width", natural: size?.0)
        let height = dimension("height", natural: size?.1)
        var style = "max-width:100%;width:auto;height:auto;object-fit:contain;"
        if let width { style += "width:\(number(width))px;" }
        if let height, own["height"] != nil { style += "max-height:\(number(height))px;" }
        return
            "<div class=\"notebook-output notebook-image\"><img src=\"\(HTML.escape(uri))\" style=\"\(style)\" alt=\"\"></div>\n"
    }

    private func number(_ value: Double) -> String {
        String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private var dimensions: (Double, Double)? {
        if mime == "image/svg+xml" {
            guard
                let tag = HTMLScanner.tokens(source).compactMap({ token -> HTMLScanner.Tag? in
                    if case .tag(let tag) = token, tag.name == "svg", !tag.isClosing { return tag }
                    return nil
                }).first
            else { return nil }
            func numeric(_ value: String?) -> Double? {
                guard let value else { return nil }
                let stripped = value.hasSuffix("px") ? String(value.dropLast(2)) : value
                guard let number = Double(stripped), number.isFinite, number > 0 else { return nil }
                return number
            }
            if let width = numeric(tag.attribute("width")), let height = numeric(tag.attribute("height")) {
                return (width, height)
            }
            let box = tag.attribute("viewbox")?.split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) } ?? []
            return box.count == 4 && box[2] > 0 && box[3] > 0 ? (box[2], box[3]) : nil
        }
        // Inspect only a bounded header; the original base64 is passed through without decoding/re-encoding the image.
        let prefix = source.utf8.prefix(131_072).filter { $0 > 32 }
        let count = prefix.count / 4 * 4
        guard let data = Data(base64Encoded: Data(prefix.prefix(count)), options: .ignoreUnknownCharacters) else {
            return nil
        }
        let bytes = Array(data)
        func big(_ index: Int, count: Int) -> Int {
            bytes[index..<(index + count)].reduce(0) { ($0 << 8) | Int($1) }
        }
        if mime == "image/png", bytes.count >= 24, bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            return (Double(big(16, count: 4)), Double(big(20, count: 4)))
        }
        if mime == "image/gif", bytes.count >= 10, bytes.starts(with: [71, 73, 70]) {
            return (Double(Int(bytes[6]) | Int(bytes[7]) << 8), Double(Int(bytes[8]) | Int(bytes[9]) << 8))
        }
        if mime == "image/jpeg", bytes.starts(with: [255, 216]) {
            var i = 2
            while i + 4 < bytes.count {
                guard bytes[i] == 255 else { break }
                let marker = bytes[i + 1]
                if marker == 255 {
                    i += 1
                    continue
                }
                if marker == 217 || marker == 218 { break }
                let length = big(i + 2, count: 2)
                guard length >= 2, i + 2 + length <= bytes.count else { break }
                if [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207].contains(marker), length >= 7 {
                    return (Double(big(i + 7, count: 2)), Double(big(i + 5, count: 2)))
                }
                i += 2 + length
            }
        }
        return nil
    }
}
