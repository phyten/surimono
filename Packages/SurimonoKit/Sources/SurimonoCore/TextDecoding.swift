import Foundation

public struct DecodedText: Equatable, Sendable {
    public let text: String
    public let encoding: String.Encoding
}

public enum TextDecoding {
    public static func decode(_ data: Data) -> DecodedText {
        // Check longer BOMs first because UTF-32 LE shares its first two bytes with UTF-16 LE.
        let signatures: [([UInt8], String.Encoding)] = [
            ([0xFF, 0xFE, 0, 0], .utf32LittleEndian), ([0, 0, 0xFE, 0xFF], .utf32BigEndian),
            ([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (signature, encoding) in signatures where data.starts(with: signature) {
            let content = data.dropFirst(signature.count)
            return result(
                String(data: content, encoding: encoding) ?? String(decoding: content, as: UTF8.self), encoding)
        }
        // ISO-2022-JP is also valid ASCII, so prioritize it over UTF-8 only when ESC is present.
        if data.contains(0x1B), data.allSatisfy({ $0 < 0x80 }),
            let text = String(data: data, encoding: .iso2022JP), !text.contains("\u{1B}")
        {
            return result(text, .iso2022JP)
        }
        if let text = String(data: data, encoding: .utf8) { return result(text, .utf8) }
        let candidates: [(String, String.Encoding, Int)] = [String.Encoding.shiftJIS, .japaneseEUC].compactMap {
            encoding in
            guard let text = String(data: data, encoding: encoding),
                let roundTrip = text.data(using: encoding), roundTrip == data
            else { return nil }
            return (text, encoding, japaneseScore(text))
        }
        if let best = candidates.max(by: { $0.2 < $1.2 }) { return result(best.0, best.1) }
        var converted: NSString?
        let raw = NSString.stringEncoding(
            for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if raw != 0, let converted { return result(converted as String, String.Encoding(rawValue: raw)) }
        return result(String(decoding: data, as: UTF8.self), .utf8)
    }

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func result(_ text: String, _ encoding: String.Encoding) -> DecodedText {
        DecodedText(text: normalizeNewlines(text), encoding: encoding)
    }

    private static func japaneseScore(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { score, scalar in
            switch scalar.value {
            case 0x3040...0x309F: score + 5
            case 0x30A0...0x30FF, 0x3000...0x303F: score + 3
            case 0x4E00...0x9FFF: score + 2
            case 0xFF61...0xFF9F: score - 1
            case 0...8, 11...12, 14...31, 0x7F...0x9F, 0xFFFD: score - 20
            default: score
            }
        }
    }
}
