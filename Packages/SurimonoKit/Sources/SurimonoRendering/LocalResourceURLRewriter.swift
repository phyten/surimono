import Foundation

enum LocalResourceURLRewriter {
    // Text and script bodies must remain verbatim even when they contain example file URLs.
    static func html(_ text: String) -> String {
        replacing(
            text,
            pattern: #"<!--[\s\S]*?-->|<script\b[^>]*>[\s\S]*?</script\s*>|<style\b[^>]*>[\s\S]*?</style\s*>|<[^>]+>"#
        ) { token in
            if token.hasPrefix("<!--") { return token }
            if token.lowercased().hasPrefix("<script"), let end = token.firstIndex(of: ">") {
                let next = token.index(after: end)
                return attributes(String(token[..<next])) + token[next...]
            }
            if token.lowercased().hasPrefix("<style"), let end = token.firstIndex(of: ">") {
                let next = token.index(after: end)
                return attributes(String(token[..<next])) + css(String(token[next...]))
            }
            return attributes(token)
        }
    }

    static func css(_ text: String) -> String {
        replacing(
            text, pattern: #"/\*[\s\S]*?\*/|\burl\(\s*(?:"[^"]*"|'[^']*'|[^)]*)\s*\)|@import\s+(?:"[^"]*"|'[^']*')"#
        ) {
            $0.hasPrefix("/*") ? $0 : fileURLs($0)
        }
    }

    private static func attributes(_ tag: String) -> String {
        replacing(
            tag,
            pattern: #"\b(?:href|xlink:href|src|srcset|poster|data|action|style)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#
        ) { attribute in
            if attribute.lowercased().hasPrefix("style") { return css(attribute) }
            return fileURLs(attribute)
        }
    }

    private static func fileURLs(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"file:(?://(?:localhost)?/|/(?!/))"#,
            with: "\(LocalResourceSchemeHandler.scheme)://document/",
            options: [.regularExpression, .caseInsensitive])
    }

    private static func replacing(_ text: String, pattern: String, transform: (String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
