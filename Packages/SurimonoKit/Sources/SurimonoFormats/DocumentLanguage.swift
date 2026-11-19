import Foundation
import NaturalLanguage

/// A document's language, independent of the application's interface language.
public struct DocumentLanguage: Equatable, Sendable {
    public let code: String

    package init(code: String) { self.code = code }

    public var isRightToLeft: Bool {
        ["ar", "fa", "ur", "he", "yi", "ps", "sd", "ug", "dv"].contains(Self.primary(code))
    }

    package static func primary(_ code: String) -> String {
        String(code.split(separator: "-").first ?? "").lowercased()
    }

    package static func normalized(_ value: String) -> String? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        func asciiLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        guard let first = parts.first, (2...3).contains(first.utf8.count), first.utf8.allSatisfy(asciiLetter),
            parts.dropFirst().allSatisfy({ part in
                (2...8).contains(part.utf8.count) && part.utf8.allSatisfy { asciiLetter($0) || (48...57).contains($0) }
            })
        else { return nil }
        let code = ([first.lowercased()] + parts.dropFirst().map(String.init)).joined(separator: "-")
        switch code.lowercased() {
        case "zh", "zh-cn", "zh-sg", "zh-hans": return "zh-Hans"
        case "zh-tw", "zh-hk", "zh-mo", "zh-hant": return "zh-Hant"
        default: return code
        }
    }

    public static func detect(html: String, declared: String? = nil, fallback: String = "ja") -> DocumentLanguage {
        if let declared, let code = normalized(declared) { return Self(code: code) }
        let fallback = normalized(fallback) ?? "ja"
        let text = visibleText(html)
        var counts = [Int](repeating: 0, count: Script.allCases.count)
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if let script = Script.of(scalar.value) { counts[script.rawValue] += 1 }
        }
        func count(_ script: Script) -> Int { counts[script.rawValue] }
        let total = counts.reduce(0, +)
        guard total > 0 else { return Self(code: fallback) }
        let kana = count(.kana)
        let han = count(.han)
        let hangul = count(.hangul)
        let hanFallback = ["ja", "zh"].contains(primary(fallback)) ? fallback : "ja"
        // A kana or a kanji says about as much as a Latin word, so by letters a Japanese note full of English terms
        // ("Kubernetes の Deployment を設定する") is mostly Latin. A small share is enough: such a note stays
        // Japanese, as every document was before languages were told apart.
        if (kana + han + hangul) * 100 >= total * 8 {
            if hangul > kana && hangul > 0 { return Self(code: "ko") }
            if kana * 50 >= kana + han { return Self(code: "ja") }
            // Kanji without kana is as likely a Japanese list (names, addresses, chapter titles) as Chinese, and a
            // recognizer asked to choose reads such a list as Chinese. Chinese prose gives itself away by its
            // function words, which Japanese does not write in kanji.
            let markers = text.unicodeScalars.reduce(0) { $0 + (chineseMarkers.contains($1) ? 1 : 0) }
            guard han >= 20, markers >= max(2, han / 200) else { return Self(code: hanFallback) }
            return Self(code: recognize(text, within: [.simplifiedChinese, .traditionalChinese]) ?? hanFallback)
        }
        let winner = Script.allCases.max { count($0) < count($1) } ?? .latin
        let code: String
        switch winner {
        case .arabic: code = recognize(text, within: [.arabic, .persian, .urdu]) ?? "ar"
        case .hebrew: code = "he"
        case .devanagari: code = recognize(text, within: [.hindi, .marathi]) ?? "hi"
        case .thai: code = "th"
        case .greek: code = "el"
        case .cyrillic: code = recognize(text, within: [.russian, .ukrainian, .bulgarian, .kazakh]) ?? "ru"
        default:
            let short = isLatin(fallback) ? fallback : "en"
            code = count(.latin) >= 20 ? recognize(text, within: [], latinOnly: true) ?? short : short
        }
        return Self(code: code)
    }

    /// Characters frequent in Chinese prose that Japanese text does not use (`的` and `了` are left out: 目的, 完了).
    private static let chineseMarkers = Set("这這们們你吗嗎呢吧没沒么麼她它哪啊很".unicodeScalars)

    private static func isLatin(_ code: String) -> Bool {
        let parts = code.lowercased().split(separator: "-")
        if parts.contains("latn") { return true }
        if parts.contains(where: { ["cyrl", "arab", "deva", "hebr", "hans", "hant"].contains($0) }) { return false }
        return !Set(
            "ja zh ko ar fa ur he yi ps sd ug dv hi mr ne th ru uk bg sr mk be kk ky mn tg el am hy bn my chr ka gu kn km lo ml or pa si ta te bo und"
                .split(separator: " ").map(String.init)
        ).contains(primary(code))
    }

    private static func recognize(_ text: String, within languages: [NLLanguage], latinOnly: Bool = false) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 20)
            .filter { !latinOnly || isLatin($0.key.rawValue) }
            .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .first?.key.rawValue
    }

    private enum Script: Int, CaseIterable {
        case kana, hangul, han, cyrillic, greek, arabic, hebrew, devanagari, thai, latin
        static func of(_ value: UInt32) -> Script? {
            switch value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F, 0x1B000...0x1B16F: return .kana
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF: return .hangul
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return .han
            case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: return .cyrillic
            case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: return .hebrew
            case 0x0900...0x097F, 0xA8E0...0xA8FF: return .devanagari
            case 0x0E00...0x0E7F: return .thai
            case 0x0041...0x007A, 0x00C0...0x02E4, 0x1D00...0x1DBF, 0x1E00...0x1EFF, 0xA720...0xA7FF, 0xAB30...0xAB6F:
                return .latin
            default: return nil
            }
        }
    }

    private static func visibleText(_ html: String) -> String {
        var output = ""
        var remaining = 20_000
        var hidden: [String] = []
        let excluded: Set<String> = ["pre", "code", "svg", "style", "script"]
        let voids: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track",
            "wbr",
        ]
        let bytes = Array(html.utf8.prefix(64 * 1024))
        var index = 0
        func matches(_ text: String, at offset: Int) -> Bool {
            let wanted = Array(text.utf8)
            return offset + wanted.count <= bytes.count
                && wanted.indices.allSatisfy {
                    let byte = bytes[offset + $0]
                    return ((65...90).contains(byte) ? byte + 32 : byte) == wanted[$0]
                }
        }
        func append(_ range: Range<Int>) {
            guard hidden.isEmpty else { return }
            let text = String(decoding: bytes[range], as: UTF8.self)
            let visible = String(HTML.unescape(text).prefix(remaining))
            output += visible
            remaining -= visible.count
        }
        while index < bytes.count && remaining > 0 {
            let start = index
            if let raw = hidden.last, ["script", "style"].contains(raw), !matches("</" + raw, at: index) {
                index += 1
                continue
            }
            if matches("<!--", at: index) {
                index += 4
                while index < bytes.count && !matches("-->", at: index) { index += 1 }
                index = min(index + 3, bytes.count)
                continue
            }
            guard bytes[index] == 60 else {
                while index < bytes.count && bytes[index] != 60 { index += 1 }
                append(start..<index)
                continue
            }
            index += 1
            var quote: UInt8?
            while index < bytes.count {
                let byte = bytes[index]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == 34 || byte == 39 {
                    quote = byte
                } else if byte == 62 {
                    break
                }
                index += 1
            }
            // An unterminated tag consumes the remainder once, even for adversarial repeated '<' input.
            guard index < bytes.count else { break }
            index += 1
            let markup = String(decoding: bytes[start..<index], as: UTF8.self)
            guard case .tag(let tag) = HTMLScanner.tokens(markup).first else { continue }
            if tag.isClosing {
                if hidden.last == tag.name { hidden.removeLast() }
            } else if !tag.isSelfClosing && !voids.contains(tag.name) {
                let classes = Set((tag.attribute("class") ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
                // Plain text uses pre for whitespace preservation, not for source code.
                let skip = excluded.contains(tag.name) && !(tag.name == "pre" && classes.contains("surimono-plain"))
                if !hidden.isEmpty || skip
                    || !classes.isDisjoint(with: [
                        "math", "math-block", "mermaid-block", "graphviz-block", "plantuml-block",
                    ])
                {
                    hidden.append(tag.name)
                }
            }
            if hidden.isEmpty && remaining > 0 {
                output += " "
                remaining -= 1
            }
        }
        return output
    }
}
