import Foundation

/// Terminal controls are interpreted before limiting, so progress updates do not become hundreds of printed lines.
enum NotebookText {
    static func terminal(_ source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        var line: [Unicode.Scalar] = []
        var cursor = 0
        var result = ""
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            i += 1
            switch scalar.value {
            case 27:
                guard i < scalars.count else { continue }
                let control = scalars[i].value
                i += 1
                if control == 91 {
                    let start = i
                    while i < scalars.count && !(64...126).contains(scalars[i].value) { i += 1 }
                    if i < scalars.count {
                        if scalars[i] == "K" {
                            let parameter = String(String.UnicodeScalarView(scalars[start..<i]))
                            if parameter == "2" {
                                line.removeAll()
                                cursor = 0
                            } else if parameter != "1", cursor < line.count {
                                line.removeSubrange(cursor...)
                            }
                        }
                        i += 1
                    }
                } else if [93, 80, 88, 94, 95].contains(control) {
                    while i < scalars.count {
                        if scalars[i].value == 7 {
                            i += 1
                            break
                        }
                        if scalars[i].value == 27, i + 1 < scalars.count, scalars[i + 1] == "\\" {
                            i += 2
                            break
                        }
                        i += 1
                    }
                }
            case 13: cursor = 0
            case 8: cursor = max(0, cursor - 1)
            case 10:
                result += String(String.UnicodeScalarView(line)) + "\n"
                line.removeAll(keepingCapacity: true)
                cursor = 0
            default:
                if scalar.value < 32 && scalar.value != 9 { continue }
                if cursor < line.count { line[cursor] = scalar } else { line.append(scalar) }
                cursor += 1
            }
        }
        return result + String(String.UnicodeScalarView(line))
    }

    static func needsLimit(_ text: String) -> Bool {
        text.utf8.count > 200_000 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 400
    }

    static func limited(_ text: String) -> (first: String, last: String, omitted: Int?) {
        guard needsLimit(text) else { return (text, "", nil) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let firstCount = min(200, max(1, lines.count - 50))
        let lastCount = min(50, lines.count - firstCount)
        let first = lines.prefix(firstCount).joined(separator: "\n")
        let last = lines.suffix(lastCount).joined(separator: "\n")
        // Decode only complete UTF-8 prefixes/suffixes; replacement characters are avoided at cut boundaries.
        func cut(_ value: String, budget: Int, tail: Bool) -> String {
            var bytes = Array(tail ? value.utf8.suffix(budget) : value.utf8.prefix(budget))
            if tail {
                while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
            } else {
                while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let head = cut(first, budget: 150_000, tail: false)
        let tail = cut(lastCount == 0 ? text : last, budget: 40_000, tail: true)
        let byteCut = head.utf8.count < first.utf8.count || tail.utf8.count < last.utf8.count || lastCount == 0
        let keptHead = head.split(separator: "\n", omittingEmptySubsequences: false).count
        let keptTail = tail.split(separator: "\n", omittingEmptySubsequences: false).count
        return (head, tail, max(byteCut ? 1 : 0, lines.count - keptHead - keptTail))
    }

    static func math(_ source: String) -> String? {
        for (open, close, display) in [
            ("$$", "$$", true), ("\\[", "\\]", true), ("\\(", "\\)", false), ("$", "$", false),
        ] {
            guard source.hasPrefix(open), source.hasSuffix(close), source.count > open.count + close.count else {
                continue
            }
            let body = String(source.dropFirst(open.count).dropLast(close.count))
            guard !body.contains(close) else { return nil }
            let html = MathRenderer.html(body, display: display) ?? MathRenderer.fallback(source, display: display)
            return display ? "<div class=\"math-block\">\(html)</div>\n" : html
        }
        for environment in ["equation", "equation*", "align", "align*", "gather", "gather*", "displaymath"] {
            let open = "\\begin{\(environment)}"
            let close = "\\end{\(environment)}"
            if source.hasPrefix(open), source.hasSuffix(close), !source.dropLast(close.count).contains(close) {
                return LaTeXConverter.convert(source).body
            }
        }
        return nil
    }
}
