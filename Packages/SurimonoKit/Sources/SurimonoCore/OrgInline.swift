import Foundation

enum OrgInline {
    enum Cookies { case none, all, edges }

    static let timestampPattern =
        #"(?:<[0-9]{4}-[0-9]{2}-[0-9]{2}(?: [^<>\[\]\n]*)?>|\[[0-9]{4}-[0-9]{2}-[0-9]{2}(?: [^<>\[\]\n]*)?\])"#

    static func timestamp(_ source: String) -> String {
        let inactive = source.hasPrefix("[") ? " org-timestamp-inactive" : ""
        return "<time class=\"org-timestamp\(inactive)\">\(HTML.escape(String(source.dropFirst().dropLast())))</time>"
    }

    static func planning(_ text: String) -> String? {
        let entry = "(SCHEDULED|DEADLINE|CLOSED):[ \t]*(" + timestampPattern + "(?:--" + timestampPattern + ")?)"
        guard orgCaptures("^(?:" + entry + "[ \t]*)+$", text) != nil,
            let regex = orgExpression(entry)
        else { return nil }
        let items = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            match -> String? in
            guard let labelRange = Range(match.range(at: 1), in: text),
                let timeRange = Range(match.range(at: 2), in: text)
            else { return nil }
            let label = String(text[labelRange]).uppercased()
            let times = text[timeRange].components(separatedBy: "--").map(timestamp).joined(separator: "–")
            return
                "<span class=\"org-planning-item org-\(label.lowercased())\"><span class=\"org-planning-label\">\(label)</span> \(times)</span>"
        }
        return "<p class=\"org-planning\">" + items.joined(separator: " ") + "</p>\n"
    }

    static func render(_ text: String, context: OrgContext = OrgContext(), depth: Int = 0, cookies: Cookies = .none)
        -> String
    {
        guard depth < 32 else { return HTML.escape(text) }
        // Index tokens once, so a run of unmatched openers never rescans the remaining suffix.
        let pattern = timestampPattern + #"|\[(?:[0-9]*/[0-9]*|[0-9]*%)\]"#
        let nsText = text as NSString
        let matches =
            orgExpression(pattern)?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []
        var tokens: [Int: (end: Int, source: String)] = [:]
        var utf16 = 0
        var offsets: [Int: Int] = [:]
        for (offset, character) in text.enumerated() {
            offsets[utf16] = offset
            utf16 += String(character).utf16.count
        }
        offsets[utf16] = text.count
        for match in matches {
            if let start = offsets[match.range.location], let end = offsets[NSMaxRange(match.range)] {
                tokens[start] = (end, nsText.substring(with: match.range))
            }
        }
        let characters = Array(text)
        var brackets: [Int: Int] = [:]
        var stack: [Int] = []
        for (position, character) in characters.enumerated() {
            if character == "[" {
                stack.append(position)
            } else if character == "]", let start = stack.popLast() {
                brackets[start] = position
            } else if character == "\n" {
                stack.removeAll(keepingCapacity: true)
            }
        }
        let tags: [Character: String] = ["*": "strong", "/": "em", "_": "u", "=": "code", "~": "code", "+": "del"]
        var output = ""
        var index = 0
        var linkSearchExhausted = false
        var exhaustedEmphasis: Set<Character> = []
        while index < characters.count {
            var token = tokens[index]
            if index + 3 < characters.count, characters[index] == "[", characters[index + 1] == "f",
                characters[index + 2] == "n", characters[index + 3] == ":", let end = brackets[index]
            {
                token = (end + 1, String(characters[index...end]))
            }
            if let token {
                let source = token.source
                var html: String?
                if source.hasPrefix("[fn:") {
                    let inner = String(source.dropFirst(4).dropLast())
                    var label = inner
                    if let colon = inner.firstIndex(of: ":") {
                        label = String(inner[..<colon])
                        if label.isEmpty {
                            context.anonymous += 1
                            label = "\u{0}anonymous-\(context.anonymous)"
                        }
                        let definition = String(inner[inner.index(after: colon)...]).trimmingCharacters(
                            in: .whitespaces)
                        if context.discovering || label.hasPrefix("\u{0}") || context.definitions[label] == nil {
                            context.definitions[label] = definition
                        }
                        if context.discovering {
                            _ = render(definition, context: context, depth: depth + 1)
                        }
                    }
                    html = context.reference(label, depth: depth)
                } else if source.hasPrefix("<")
                    || source.dropFirst().prefix(4).allSatisfy(\.isNumber) && source.dropFirst(5).hasPrefix("-")
                {
                    html = timestamp(source)
                } else if cookies == .all || cookies == .edges && (index == 0 || token.end == characters.count) {
                    html = "<span class=\"org-cookie\">\(HTML.escape(source))</span>"
                }
                output += html ?? HTML.escape(source)
                index = token.end
                if html?.hasPrefix("<time ") == true, index + 2 < characters.count,
                    characters[index] == "-", characters[index + 1] == "-",
                    let next = tokens[index + 2], !next.source.hasPrefix("[fn:"),
                    orgCaptures("^" + timestampPattern + "$", next.source) != nil
                {
                    output += "–"
                    index += 2
                }
                continue
            }
            if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == "\\",
                index + 2 == characters.count || characters[index + 2] == "\n"
            {
                output += "<br>"
                index += 2
                continue
            }
            var linkEnd: Int?
            if !linkSearchExhausted, index + 1 < characters.count,
                characters[index] == "[", characters[index + 1] == "["
            {
                linkEnd = ((index + 2)..<max(index + 2, characters.count - 1)).first(where: {
                    characters[$0] == "]" && characters[$0 + 1] == "]"
                })
                // A failed search covers the entire suffix; later openers cannot have a closing pair.
                linkSearchExhausted = linkEnd == nil
            }
            if let end = linkEnd {
                let inner = String(characters[(index + 2)..<end])
                let parts = inner.components(separatedBy: "][")
                let destination = parts[0].hasPrefix("file:") ? String(parts[0].dropFirst(5)) : parts[0]
                let label = parts.count > 1 ? parts.dropFirst().joined(separator: "][") : destination
                let path = destination.components(separatedBy: "?")[0].components(separatedBy: "#")[0]
                let suffix = (path as NSString).pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tif", "tiff", "heic"].contains(suffix) {
                    output += "<img src=\"\(HTML.escape(destination))\" alt=\"\(HTML.escape(label))\">"
                } else {
                    output +=
                        "<a href=\"\(HTML.escape(destination))\">\(render(label, context: context, depth: depth + 1))</a>"
                }
                index = end + 2
                continue
            }
            let character = characters[index]
            var emphasisEnd: Int?
            if tags[character] != nil, !exhaustedEmphasis.contains(character),
                index + 1 < characters.count, !characters[index + 1].isWhitespace,
                index == 0 || characters[index - 1].isWhitespace || "([{'\"".contains(characters[index - 1])
            {
                emphasisEnd = ((index + 2)..<characters.count).first(where: {
                    characters[$0] == character && !characters[$0 - 1].isWhitespace
                        && ($0 + 1 == characters.count || characters[$0 + 1].isWhitespace
                            || ")]},.!?;:'\"".contains(characters[$0 + 1]))
                })
                // Once no closing delimiter remains, later openers of this kind cannot succeed either.
                if emphasisEnd == nil { exhaustedEmphasis.insert(character) }
            }
            if let tag = tags[character], let end = emphasisEnd {
                let inner = String(characters[(index + 1)..<end])
                output +=
                    "<\(tag)>\(tag == "code" ? HTML.escape(inner) : render(inner, context: context, depth: depth + 1, cookies: cookies))</\(tag)>"
                index = end + 1
            } else {
                output += HTML.escape(String(character))
                index += 1
            }
        }
        return output
    }
}
