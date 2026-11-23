import Foundation

/// Splits the converter's escaped text after change detection. The only tags inside it are color and change spans.
enum SourcePageMarkup {
    // Each page uses one set of outlines. Empty use elements carry no digits into PDF selection or HTML textContent.
    private static let digitDefinitions: String = {
        let outlines = [
            "M4.5 1.5c-2.4 0-3.1 2.4-3.1 5.8s.7 5.8 3.1 5.8 3.1-2.4 3.1-5.8-.7-5.8-3.1-5.8Z",
            "M2 3.8l2.6-2.2V13M2 13h5",
            "M1.4 4.4c.2-1.9 1.4-2.9 3.2-2.9 2 0 3 1.3 3 3 0 2-1.2 3.3-3.3 5.4L1.4 13h6.3",
            "M1.5 2.6c.8-.8 1.7-1.1 3-1.1 1.8 0 3 1 3 2.7S6.2 7 4.2 7h-.9m.9 0c2.1 0 3.5 1 3.5 3.1s-1.6 3.1-3.5 3.1c-1.4 0-2.3-.4-3.1-1.2",
            "M6.2 13V1.6L.9 9.6h7.2",
            "M7.4 1.7H2l-.5 5.4c.8-.5 1.7-.8 2.8-.8 2.1 0 3.3 1.3 3.3 3.3 0 2.2-1.5 3.6-3.6 3.6-1.2 0-2.1-.4-3-1.1",
            "M7.1 1.7C3 .9 1.3 4.6 1.3 8.5c0 2.9 1.1 4.7 3.4 4.7 2 0 3-1.6 3-3.6s-1.2-3.5-3-3.5c-1.5 0-2.7.9-3.3 2.4",
            "M1.1 1.7h6.7L3.2 13",
            "M4.5 1.5c-1.9 0-3 1.1-3 2.7 0 1.5 1.2 2.5 3 3 2.1.7 3.3 1.6 3.3 3.2 0 1.7-1.3 2.8-3.3 2.8s-3.3-1.1-3.3-2.8c0-1.6 1.3-2.6 3.3-3.2 1.8-.6 3-1.5 3-3 0-1.6-1.1-2.7-3-2.7Z",
            "M1.8 13c4.1.8 5.9-2.8 5.9-6.8 0-2.9-1.2-4.7-3.4-4.7-2 0-3.1 1.6-3.1 3.6s1.2 3.5 3 3.5c1.6 0 2.8-.9 3.4-2.4",
        ]
        let paths = outlines.enumerated().map { "<path id=\"sd\($0.offset)\" d=\"\($0.element)\"/>" }.joined()
        return "<svg class=\"source-digits\" aria-hidden=\"true\" width=\"0\" height=\"0\"><defs>\(paths)</defs></svg>"
    }()

    private static func lineNumber(_ number: Int) -> String {
        let digits = String(number)
        var svg = "<svg class=\"source-no\" aria-hidden=\"true\" viewBox=\"0 0 \(digits.count * 9) 15\">"
        for (position, digit) in digits.enumerated() {
            let offset = position == 0 ? "" : " x=\"\(position * 9)\""
            svg += "<use href=\"#sd\(digit)\"\(offset)/>"
        }
        return svg + "</svg>"
    }

    static func apply(
        _ options: CodeBlockOptions, html: String, language: SourceLanguage, checkBytes: (Int) throws -> Void
    ) rethrows -> String {
        var bytes = html.utf8.dropFirst(PlainTextConverter.sourceOpen.utf8.count).dropLast("</pre>".utf8.count)
        // A token or change span may close after the last newline. Its close is emitted on the preceding row.
        while bytes.suffix(7).elementsEqual("</span>".utf8) { bytes = bytes.dropLast(7) }
        let count = bytes.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (bytes.last == 10 ? 0 : 1)
        let numbered = options.lineNumbers != .none
        let digits = numbered ? String(count).count : 0
        var result = "<pre class=\"surimono-source code-block source-\(options.longLines.rawValue)\""
        result += " style=\"--source-digits:\(digits);--source-gap:\(numbered ? "2ch" : "0px")\""
        if options.languageLabel != .none {
            result += " data-code-label=\"\(HTML.escape(language.displayName))\""
        }
        result += "><code>"
        if numbered { result += digitDefinitions }
        var spans: [String] = []
        var start = bytes.startIndex
        var number = 1
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            let line = bytes[start..<end]
            var content = spans.joined()
            var indent = 0
            var leading = true
            var cursor = start
            while cursor < end {
                if line[cursor] == 60, let close = line[cursor...].firstIndex(of: 62) {
                    let next = line.index(after: close)
                    let tag = String(decoding: line[cursor..<next], as: UTF8.self)
                    if tag == "</span>" { _ = spans.popLast() } else { spans.append(tag) }
                    content += tag
                    cursor = next
                } else {
                    let next = line[line.index(after: cursor)...].firstIndex(of: 60) ?? end
                    let run = line[cursor..<next]
                    if leading {
                        for byte in run {
                            if byte == 32 {
                                indent += 1
                            } else if byte == 9 {
                                indent += 4 - indent % 4
                            } else {
                                leading = false
                                break
                            }
                        }
                    }
                    content += String(decoding: run, as: UTF8.self)
                    cursor = next
                }
            }
            content += String(repeating: "</span>", count: spans.count)
            let hang = indent == 0 ? "" : " style=\"--source-indent:\(indent + 2)ch\""
            result += "<span class=\"source-line\"\(hang)>"
            if options.lineNumbers.shows(line: number) {
                result += lineNumber(number)
            }
            result += "<span class=\"source-ink\">\(content)</span></span>"
            if end < bytes.endIndex { result += "\n" }
            if number.isMultiple(of: 1024) { try checkBytes(result.utf8.count) }
            start = end == bytes.endIndex ? end : bytes.index(after: end)
            number += 1
        }
        result += "</code></pre>"
        try checkBytes(result.utf8.count)
        return result
    }
}
