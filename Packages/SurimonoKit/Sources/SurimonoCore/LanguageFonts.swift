import Foundation

public enum LanguageFonts {
    private enum Family: Int {
        case gothic, mincho, rounded, textbook, mono
    }

    private static let families: [String: Family] = {
        let groups: [(Family, [String])] = [
            (
                .gothic,
                [
                    "Surimono JS Gothic", "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic", "YuGothic",
                    "BIZ UDGothic",
                    "BIZ UDPGothic", "Osaka", "Toppan Bunkyu Gothic", "Toppan Bunkyu Midashi Gothic",
                ]
            ),
            (
                .mincho,
                [
                    "Hiragino Mincho ProN", "YuMincho", "Yu Mincho", "BIZ UDMincho", "Toppan Bunkyu Mincho",
                    "Toppan Bunkyu Midashi Mincho", "Surimono Title Mincho", "Surimono Author Mincho",
                    "Surimono Abstract Mincho", "Surimono Caption Mincho", "Surimono Note Mincho",
                ]
            ),
            (.rounded, ["Hiragino Maru Gothic ProN", "Tsukushi A Round Gothic", "Tsukushi B Round Gothic"]),
            (.textbook, ["YuKyokasho", "YuKyokasho Yoko", "Klee"]),
            (.mono, ["Osaka-Mono"]),
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { group in group.1.map { ($0.lowercased(), group.0) } })
    }()

    /// Adapts font lists while preserving every byte outside insertion points, including embedded fonts.
    public static func adapt(_ css: String, language: String) -> String {
        let code = DocumentLanguage.normalized(language) ?? language
        let replacements: [String]
        switch code.lowercased() {
        case "zh-hans": replacements = ["PingFang SC", "Songti SC", "Yuanti SC", "Kaiti SC", "PingFang SC"]
        case "zh-hant": replacements = ["PingFang TC", "Songti TC", "Yuanti TC", "Kaiti TC", "PingFang TC"]
        default:
            switch DocumentLanguage.primary(code) {
            case "ko":
                replacements = [
                    "Apple SD Gothic Neo", "AppleMyungjo", "Apple SD Gothic Neo", "AppleMyungjo", "Apple SD Gothic Neo",
                ]
            case "ru", "uk", "bg", "sr", "mk", "be", "kk", "ky", "mn", "tg", "el":
                replacements = ["Helvetica Neue", "Times New Roman", "Helvetica Neue", "Times New Roman", "Menlo"]
            default: return css
            }
        }
        return inserting(in: css) { declaration, _ in
            insertion(in: declaration, replacements: replacements).map { ($0.0, "\"\($0.1)\", ") }
        }
    }

    // Keep the fallback stack as an inherited property: a user's "pre { font: inherit }" takes
    // its parent's fallback fonts, but still starts with the typewriter face.
    static func prefixTypeface(in css: String) -> String {
        // A shorthand can live in a custom property. Keep a parallel family list for those variables
        // so the browser still resolves competing definitions, including ones inside media queries.
        let shorthandVariables = Set(
            css.matches(of: /(?i:font)\s*:\s*(?i:var)\(\s*(--[\w-]+)\s*\)/).map { String($0.1) })
        let bytes = Array(css.utf8)
        return inserting(in: css) { declaration, end in
            guard let name = declaration.first?.value,
                declaration.dropFirst().first?.value == ":"
            else { return nil }
            let property = name.lowercased()
            guard property == "font" || property == "font-family" || shorthandVariables.contains(name) else {
                return nil
            }
            let values = declaration.dropFirst(2)
            guard let first = values.first else { return nil }
            let important =
                (values.last?.value.lowercased() == "!important"
                    || values.suffix(2).map(\.value).joined().lowercased() == "!important")
                ? " !important" : ""
            if shorthandVariables.contains(name) {
                guard let start = shorthandFamily(in: values) else { return nil }
                let list = String(decoding: bytes[start.offset..<end], as: UTF8.self)
                return (end, "; --surimono-family" + name + ": " + list)
            }
            if property == "font" {
                let fallback: String?
                if ["caption", "icon", "menu", "message-box", "small-caption", "status-bar"].contains(
                    first.value.lowercased())
                    || first.value.hasPrefix("-apple-system-")
                {
                    fallback = "system-ui"
                } else if !first.isFamily,
                    let variable = String(decoding: bytes[first.offset..<end], as: UTF8.self)
                        .wholeMatch(of: /(?i:var)\(\s*(--[\w-]+)\s*\)\s*(?:!\s*(?i:important)\s*)?/)
                {
                    fallback = "var(--surimono-family" + variable.1 + ", serif)"
                } else {
                    fallback = nil
                }
                if let fallback {
                    return (
                        end,
                        "; --surimono-style-family: " + fallback + important
                            + "; font-family: var(--surimono-western) var(--surimono-style-family)" + important
                    )
                }
            }
            let family: Token
            var prefix = ""
            switch first.value.lowercased() {
            case "inherit", "unset", "initial", "revert", "revert-layer":
                family = first
                if property == "font" { prefix = first.value + important + "; font-family: " }
            default:
                if property == "font" {
                    guard let start = shorthandFamily(in: values) else { return nil }
                    family = start
                } else {
                    family = first
                }
            }
            // Keep the priority on both declarations. WebKit resolves custom properties and nested
            // var() fallbacks at the original selector, in its original media query and cascade layer.
            prefix +=
                "var(--surimono-western) var(--surimono-style-family, serif)" + important
                + "; --surimono-style-family: "
            return (family.offset, prefix)
        }
    }

    private static func shorthandFamily(in values: ArraySlice<Token>) -> Token? {
        // The family follows the size and optional /line-height in the font shorthand.
        let sizes = [
            "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large",
            "larger", "smaller", "math",
        ]
        guard
            let size = values.firstIndex(where: {
                let value = $0.value.lowercased().prefix { $0 != "/" }
                return !$0.isFamily || sizes.contains(String(value)) || value == "0"
                    || (value.first?.isNumber == true || value.first == ".") && Double(value) == nil
            })
        else { return nil }
        var rest = values.suffix(from: size + 1)
        if rest.first?.value == "/" {
            rest = rest.dropFirst(2)
        } else if rest.first?.value.hasPrefix("/") == true || values[size].value.hasSuffix("/") {
            rest = rest.dropFirst()
        }
        return rest.first
    }

    private static func inserting(
        in css: String, _ insertion: (ArraySlice<Token>, Int) -> (Int, String)?
    ) -> String {
        let bytes = Array(css.utf8)
        let tokens = tokens(bytes)
        var blocked: [Bool] = []
        var start = 0
        var insertions: [(Int, String)] = []
        for (index, token) in tokens.enumerated() {
            if token.isSymbol && token.value == "{" {
                let fontFace = tokens[start..<index].contains { $0.value.lowercased() == "@font-face" }
                blocked.append((blocked.last ?? false) || fontFace)
                start = index + 1
            } else if token.isSymbol && (token.value == ";" || token.value == "}") {
                if !blocked.isEmpty && blocked.last != true,
                    let insertion = insertion(tokens[start..<index], token.offset)
                {
                    insertions.append(insertion)
                }
                if token.value == "}" { _ = blocked.popLast() }
                start = index + 1
            }
        }
        guard !insertions.isEmpty else { return css }
        var result = ""
        var offset = 0
        for (position, prefix) in insertions {
            result += String(decoding: bytes[offset..<position], as: UTF8.self) + prefix
            offset = position
        }
        return result + String(decoding: bytes[offset...], as: UTF8.self)
    }

    private struct Token {
        var value: String
        var offset: Int
        var isFamily: Bool = true
        var isSymbol: Bool = false
    }

    private static func insertion(in declaration: ArraySlice<Token>, replacements: [String]) -> (Int, String)? {
        guard let colon = declaration.firstIndex(where: { $0.isSymbol && $0.value == ":" }),
            let property = declaration.first?.value.lowercased(),
            property == "font-family" || property == "font" || property.hasPrefix("--")
        else { return nil }
        var group: [Token] = []
        var preceding: Set<String> = []
        func inspect() -> (Int, String)? {
            guard !group.isEmpty, group.allSatisfy(\.isFamily) else { return nil }
            let full = group.map(\.value).joined(separator: " ").lowercased()
            // Only a shorthand's first family may follow size, line height and weight tokens.
            let starts = property == "font" && preceding.isEmpty ? Array(group.indices.suffix(5)) : [0]
            for start in starts {
                let name = group[start...].map(\.value).joined(separator: " ").lowercased()
                if let kind = families[name] {
                    let replacement = replacements[kind.rawValue]
                    return preceding.contains(replacement.lowercased()) ? nil : (group[start].offset, replacement)
                }
            }
            preceding.insert(full)
            if property == "font" && preceding.count == 1 {
                for start in group.indices.suffix(5) {
                    preceding.insert(group[start...].map(\.value).joined(separator: " ").lowercased())
                }
            }
            return nil
        }
        for token in declaration[declaration.index(after: colon)...] {
            if token.isSymbol && token.value == "," {
                if let found = inspect() { return found }
                // A matching family already preceded by its replacement ends this list's search too.
                if families[group.map(\.value).joined(separator: " ").lowercased()] != nil { return nil }
                group = []
            } else {
                group.append(token)
            }
        }
        return inspect()
    }

    /// Quotes, comments and balanced functions are read once; a data URL is one opaque token.
    private static func tokens(_ bytes: [UInt8]) -> [Token] {
        var result: [Token] = []
        var index = 0
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func quoted() {
            let quote = bytes[index]
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 {
                    index = min(index + 2, bytes.count)
                } else if bytes[index] == quote {
                    index += 1
                    return
                } else {
                    index += 1
                }
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 32 || (9...13).contains(byte) {
                index += 1
                continue
            }
            if byte == 47 && index + 1 < bytes.count && bytes[index + 1] == 42 {
                index += 2
                while index + 1 < bytes.count && !(bytes[index] == 42 && bytes[index + 1] == 47) { index += 1 }
                index = min(index + 2, bytes.count)
                continue
            }
            let start = index
            if byte == 34 || byte == 39 {
                quoted()
                let end = index > start + 1 && bytes[index - 1] == byte ? index - 1 : index
                result.append(Token(value: string((start + 1)..<end), offset: start))
            } else if [UInt8(123), 125, 58, 59, 44].contains(byte) {
                index += 1
                result.append(Token(value: string(start..<index), offset: start, isFamily: false, isSymbol: true))
            } else {
                while index < bytes.count
                    && ![UInt8(32), 9, 10, 13, 12, 123, 125, 58, 59, 44, 40, 34, 39].contains(bytes[index])
                {
                    if bytes[index] == 47 && index + 1 < bytes.count && bytes[index + 1] == 42 { break }
                    index += 1
                }
                if index < bytes.count && bytes[index] == 40 {
                    var depth = 1
                    index += 1
                    while index < bytes.count && depth > 0 {
                        if bytes[index] == 34 || bytes[index] == 39 {
                            quoted()
                            continue
                        }
                        if bytes[index] == 92 {
                            index = min(index + 2, bytes.count)
                            continue
                        }
                        if bytes[index] == 40 { depth += 1 }
                        if bytes[index] == 41 { depth -= 1 }
                        index += 1
                    }
                    result.append(Token(value: "", offset: start, isFamily: false))
                } else {
                    if index == start { index += 1 }
                    result.append(Token(value: string(start..<index), offset: start))
                }
            }
        }
        return result
    }
}
