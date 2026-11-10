import CoreFoundation
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
        // Text with enough kana is Japanese beyond doubt. A round trip alone proves nothing: Western, Korean and
        // Chinese bytes also round-trip through Shift_JIS or EUC-JP, as other characters.
        let candidates: [(String, String.Encoding, Int)] = [String.Encoding.shiftJIS, .japaneseEUC].compactMap {
            encoding in
            guard let text = roundTripped(data, encoding), let score = japaneseScore(text) else { return nil }
            return (text, encoding, score)
        }
        if let best = candidates.max(by: { $0.2 < $1.2 }) { return result(best.0, best.1) }
        // English with curly double quotes: before a letter the opening quote also reads as a kanji ("“no”"), and
        // the system then takes the text for Japanese.
        if let western = String(data: data, encoding: .windowsCP1252), isEnglishWithTypographicMarks(western) {
            return result(western, .windowsCP1252)
        }
        // Without kana, the system tells the encodings apart far better than byte ranges can (it knows which
        // characters are common in each language). Asked twice, plainly and expecting Japanese, it agrees on nearly
        // everything. Where it does not ("Windows版", or half-width kana alone, which read as Western or Chinese
        // when asked plainly), a Japanese reading wins: this is first a viewer for Japanese documents.
        let plain = guess(data, language: nil)
        if let japanese = guess(data, language: "ja"), japanese.encoding != plain?.encoding,
            [.shiftJIS, .japaneseEUC].contains(japanese.encoding), japaneseScore(japanese.text, needsKana: false) != nil
        {
            return result(japanese.text, japanese.encoding)
        }
        if let plain { return result(plain.text, plain.encoding) }
        // None of the encodings this app knows well fits; whatever the system makes of it, as before.
        var converted: NSString?
        let raw = NSString.stringEncoding(
            for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if raw != 0, let converted { return result(converted as String, String.Encoding(rawValue: raw)) }
        return result(String(decoding: data, as: UTF8.self), .utf8)
    }

    /// Whether this is English with a pair of curly double quotes: everything beyond ASCII is punctuation a word
    /// processor puts into English, each where English puts it, few among many letters, and every “ is closed by a
    /// ” on its line. The pair is what Japanese bytes do not make by accident. One mark alone is no evidence
    /// (堀 reads as –x, 徹 as “O, and 担当 as ’S“–), and without a pair the system's guess is asked instead.
    private static func isEnglishWithTypographicMarks(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var letters = 0
        var marks = 0
        var pairs = 0
        var isOpen = false
        for (index, scalar) in scalars.enumerated() {
            if scalar.value < 0x80 {
                if isLetter(scalar) { letters += 1 }
                if scalar == "\n", isOpen { return false }
                continue
            }
            let before = index > 0 ? scalars[index - 1] : nil
            guard isPlaced(scalar, after: before, before: scalars[(index + 1)...]) else { return false }
            marks += 1
            if scalar.value == 0x201C {
                guard !isOpen else { return false }
                isOpen = true
            } else if scalar.value == 0x201D {
                guard isOpen else { return false }
                isOpen = false
                pairs += 1
            }
        }
        return pairs > 0 && !isOpen && letters >= marks * 4
    }

    private static func isLetter(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return isLetter(scalar) || (0x30...0x39).contains(value)
    }

    /// Whether the mark stands where English puts it.
    private static func isPlaced(
        _ mark: Unicode.Scalar, after before: Unicode.Scalar?, before rest: ArraySlice<Unicode.Scalar>
    ) -> Bool {
        let next = rest.first
        let opens = before == nil || before.map { " \n\t([".unicodeScalars.contains($0) } == true
        let closes = next == nil || next.map { !isLetterOrDigit($0) } == true
        switch mark.value {
        case 0xA0, 0x2026: return true
        case 0x2013, 0x2014:
            return (before == nil || before == " " || isLetterOrDigit(before))
                && (next == nil || next == " " || next == "\n" || isLetterOrDigit(next))
        case 0x2018, 0x201C: return opens && (isLetterOrDigit(next) || next?.value == 0x2018)
        case 0x201D:
            return closes && (isLetterOrDigit(before) || before.map { ".,!?’…".unicodeScalars.contains($0) } == true)
        case 0x2019:
            if before.map({ ".,!?".unicodeScalars.contains($0) }) == true { return closes }
            guard isLetter(before) else { return false }
            if closes { return true }
            // Inside a word, only as an apostrophe before the endings English contracts to.
            let ending = String(String.UnicodeScalarView(rest.prefix { isLetter($0) }))
            return ["s", "t", "d", "m", "re", "ve", "ll"].contains(ending)
        case 0x2022: return before == nil || before == "\n" || before == " "
        default: return false
        }
    }

    private static func roundTripped(_ data: Data, _ encoding: String.Encoding) -> String? {
        guard let text = String(data: data, encoding: encoding), text.data(using: encoding) == data else { return nil }
        return text
    }

    private static let guessedEncodings: [UInt] =
        ([String.Encoding.shiftJIS, .japaneseEUC, .iso2022JP, .windowsCP1252]
        + [CFStringEncodings.EUC_KR, .big5, .GB_18030_2000].map {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding($0.rawValue)))
        }).map(\.rawValue)

    private static func guess(_ data: Data, language: String?) -> (text: String, encoding: String.Encoding)? {
        var options: [StringEncodingDetectionOptionsKey: Any] = [
            .suggestedEncodingsKey: guessedEncodings, .useOnlySuggestedEncodingsKey: true, .allowLossyKey: false,
        ]
        if let language { options[.likelyLanguageKey] = language }
        var converted: NSString?
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(
            for: data, encodingOptions: options, convertedString: &converted, usedLossyConversion: &lossy)
        guard raw != 0, !lossy.boolValue, let converted else { return nil }
        return (converted as String, String.Encoding(rawValue: raw))
    }

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func result(_ text: String, _ encoding: String.Encoding) -> DecodedText {
        DecodedText(text: normalizeNewlines(text), encoding: encoding)
    }

    /// How Japanese the text reads, or nil when it does not: control characters, or too little kana among the
    /// other characters. With `needsKana` off, only the control characters rule a text out.
    private static func japaneseScore(_ text: String, needsKana: Bool = true) -> Int? {
        var kana = 0
        var kanji = 0
        var halfWidth = 0
        var other = 0
        var score = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F:
                kana += 1
                score += 5
            case 0x30A0...0x30FF:
                kana += 1
                score += 3
            case 0x3000...0x303F: score += 3
            case 0x4E00...0x9FFF:
                kanji += 1
                score += 2
            case 0xFF61...0xFF9F:
                halfWidth += 1
                score -= 1
            case 0...8, 11...12, 14...31, 0x7F...0x9F, 0xFFFD: return nil
            case 0x80...: other += 1
            default: break
            }
        }
        guard needsKana else { return score }
        guard kana > 0, halfWidth <= kana * 3, kana * 5 >= kana + kanji + halfWidth + other else { return nil }
        return score
    }
}
