import Foundation

/// Marks paths, URLs and the like in a document's text, so that they can break anywhere.
///
/// A line break is allowed only at few places in such a run of characters. With a long one, the rest of the line
/// stays empty, and a justified theme stretches the few characters in front of it over the whole width.
/// `overflow-wrap` does not help, as it applies only when a line has no break point at all.
enum LongTokenMarks {
    static let opening = "<span class=\"long-token\">"
    private static let minimumLength = 20
    private static let separators = Set("/\\._-:=?&@#".unicodeScalars)
    private static let skippedElements: Set<String> = ["pre", "script", "style", "svg", "math", "textarea", "title"]

    static func marked(_ html: String) -> String {
        var output = ""
        output.reserveCapacity(html.count)
        var skipped: String?
        var rest = html[...]
        while !rest.isEmpty {
            guard let tagStart = rest.firstIndex(of: "<") else {
                output += skipped == nil ? markedText(rest) : String(rest)
                break
            }
            let text = rest[..<tagStart]
            output += skipped == nil ? markedText(text) : String(text)
            guard let tagEnd = rest[tagStart...].firstIndex(of: ">") else {
                output += rest[tagStart...]
                break
            }
            let tag = rest[tagStart...tagEnd]
            output += tag
            rest = rest[rest.index(after: tagEnd)...]
            let name = elementName(of: tag)
            if let current = skipped {
                if tag.hasPrefix("</"), name == current { skipped = nil }
            } else if skippedElements.contains(name), !tag.hasPrefix("</"), !tag.hasSuffix("/>") {
                skipped = name
            }
        }
        return output
    }

    private static func elementName(of tag: Substring) -> String {
        tag.dropFirst().drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
    }

    private static func markedText(_ text: Substring) -> String {
        var output = ""
        var run = ""
        func flush() {
            let isLong = run.unicodeScalars.count >= minimumLength
            if isLong, run.unicodeScalars.contains(where: separators.contains) {
                output += opening + run + "</span>"
            } else {
                output += run
            }
            run = ""
        }
        for character in text {
            if character.isASCII, !character.isWhitespace {
                run.append(character)
            } else {
                flush()
                output.append(character)
            }
        }
        flush()
        return output
    }
}
