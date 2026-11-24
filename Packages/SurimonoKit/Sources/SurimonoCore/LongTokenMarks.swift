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
    private static let skippedElements: Set<String> = ["pre", "svg", "math"]

    private static let verticalClasses: Set<Substring> = ["tcy", "kenten", "bousen", "v-url", "math", "math-block"]

    static func marked(_ html: String, verticalLaTeX: Bool = false) -> String {
        var output = ""
        output.reserveCapacity(html.utf8.count)
        var skipped: (name: String, depth: Int)?
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .opaque(let source): output += source
            case .text(let text): output += skipped == nil ? markedText(text[...]) : text
            case .tag(let tag):
                output += tag.source
                if let current = skipped {
                    guard tag.name == current.name, !tag.isSelfClosing else { continue }
                    let depth = current.depth + (tag.isClosing ? -1 : 1)
                    skipped = depth == 0 ? nil : (current.name, depth)
                } else if !tag.isClosing, !tag.isSelfClosing, skips(tag, verticalLaTeX: verticalLaTeX) {
                    skipped = (tag.name, 1)
                }
            }
        }
        return output
    }

    private static func skips(_ tag: HTMLScanner.Tag, verticalLaTeX: Bool) -> Bool {
        if skippedElements.contains(tag.name) || tag.source == #"<span class="tcy">"# { return true }
        guard verticalLaTeX else { return false }
        if tag.name == "rt" || tag.name == "code" { return true }
        let classes = tag.attribute("class")?.split(whereSeparator: \.isWhitespace) ?? []
        return !verticalClasses.isDisjoint(with: classes)
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
