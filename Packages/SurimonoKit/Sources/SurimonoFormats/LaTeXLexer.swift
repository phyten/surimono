import Foundation

/// The parts of LaTeX source that scans for structure must step over as one piece: a comment, `\verb|…|`,
/// `\lstinline`, and the body of a verbatim-like environment. Without this, `\end{quote}` or `\item` written inside
/// code would end an environment or split a list.
package enum LaTeXLexer {
    package static let verbatimEnvironments: Set<String> = [
        "verbatim", "verbatim*", "Verbatim", "lstlisting", "minted", "comment", "alltt",
    ]

    /// The index just past the opaque piece that starts at `index`, or nil when none starts there.
    static func opaqueEnd(_ characters: [Character], at index: Int, needsMore: () -> Void = {}) -> Int? {
        guard index < characters.count else { return nil }
        if characters[index] == "%" {
            var end = index
            while end < characters.count, characters[end] != "\n" { end += 1 }
            return end
        }
        guard characters[index] == "\\" else { return nil }
        if index + 1 == characters.count { needsMore() }
        if let name = word(characters, at: index + 1) {
            let after = index + 1 + name.count
            if after == characters.count { needsMore() }
            switch name {
            case "url", "href", "path", "nolinkurl":
                return urlArgumentEnd(characters, at: index, needsMore: needsMore)
            case "verb":
                var start = after
                if start < characters.count, characters[start] == "*" { start += 1 }
                return delimited(characters, from: start)
            case "lstinline", "mintinline":
                var start = skippingSpaces(characters, from: after)
                start = skippingSpaces(characters, from: skipping(characters, optionalFrom: start))
                if name == "mintinline" {
                    start = skippingSpaces(characters, from: skipping(characters, groupFrom: start))
                }
                if start < characters.count, characters[start] == "{" { return skipping(characters, groupFrom: start) }
                return delimited(characters, from: start)
            case "begin":
                guard after < characters.count, characters[after] == "{" else { return nil }
                guard let close = characters[after...].firstIndex(of: "}") else {
                    needsMore()
                    return nil
                }
                let environment = String(characters[(after + 1)..<close])
                guard verbatimEnvironments.contains(environment) else { return nil }
                let end = Array("\\end{\(environment)}")
                var cursor = close + 1
                while cursor + end.count <= characters.count {
                    if characters[cursor] == "\\", Array(characters[cursor..<(cursor + end.count)]) == end {
                        return cursor + end.count
                    }
                    cursor += 1
                }
                return characters.count
            default:
                return nil
            }
        }
        return nil
    }

    /// The position of the first `\name` outside opaque pieces at or after `start`, with `name` not followed by a
    /// letter.
    static func find(_ name: String, in characters: [Character], from start: Int = 0) -> Int? {
        var index = start
        while index < characters.count {
            if let end = opaqueEnd(characters, at: index) {
                index = max(end, index + 1)
                continue
            }
            if characters[index] == "\\" {
                if word(characters, at: index + 1) == name { return index }
                index += 2
                continue
            }
            index += 1
        }
        return nil
    }

    /// The source split at separators outside braces; escaped characters do not separate.
    /// Cell and row separators inside a nested alignment belong to that alignment.
    static func split(
        _ text: String, at separators: [String], keepingSeparators: Bool = false, protectingEnvironments: Bool = false
    ) -> [String] {
        let characters = Array(text)
        let separators = separators.map(Array.init)
        var parts: [String] = []
        var current: [Character] = []
        var depth = 0
        var environmentDepth = 0
        var index = 0
        outer: while index < characters.count {
            let character = characters[index]
            if character == "%" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "\\", let opaque = LaTeXLexer.opaqueEnd(characters, at: index) {
                // `\verb|a&b|` in a cell is code, not a column separator.
                let end = max(opaque, index + 1)
                current.append(contentsOf: characters[index..<end])
                index = end
                continue
            }
            if protectingEnvironments, depth == 0, character == "\\",
                let command = word(characters, at: index + 1), command == "begin" || command == "end"
            {
                let opening = skippingSpaces(characters, from: index + 1 + command.count)
                if opening < characters.count, characters[opening] == "{" {
                    let end = skipping(characters, groupFrom: opening)
                    environmentDepth = command == "begin" ? environmentDepth + 1 : max(0, environmentDepth - 1)
                    current.append(contentsOf: characters[index..<end])
                    index = end
                    continue
                }
            }
            if depth == 0, environmentDepth == 0 {
                for separator in separators
                where index + separator.count <= characters.count
                    && Array(characters[index..<(index + separator.count)]) == separator
                {
                    // `\tabularnewline` must not split inside a longer command name.
                    let end = index + separator.count
                    if separator.count > 2, end < characters.count, characters[end].isASCII, characters[end].isLetter {
                        continue
                    }
                    parts.append(String(current))
                    if keepingSeparators { parts.append(String(separator)) }
                    current = []
                    index = end
                    continue outer
                }
            }
            if character == "\\", index + 1 < characters.count {
                current += [character, characters[index + 1]]
                index += 2
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            current.append(character)
            index += 1
        }
        parts.append(String(current))
        return parts
    }

    static func word(_ characters: [Character], at index: Int) -> String? {
        var end = index
        while end < characters.count, characters[end].isASCII, characters[end].isLetter { end += 1 }
        return end > index ? String(characters[index..<end]) : nil
    }

    // URL arguments must stay opaque to structural scans: a percent sign cannot hide their closing brace.
    static func urlArgumentEnd(_ characters: [Character], at index: Int, needsMore: () -> Void = {}) -> Int? {
        guard index < characters.count, characters[index] == "\\",
            let name = word(characters, at: index + 1),
            ["url", "href", "path", "nolinkurl"].contains(name)
        else { return nil }
        var cursor = index + 1 + name.count
        while cursor < characters.count {
            if characters[cursor].isWhitespace {
                cursor += 1
            } else if characters[cursor] == "%" {
                while cursor < characters.count, characters[cursor] != "\n" { cursor += 1 }
            } else {
                break
            }
        }
        guard cursor < characters.count else {
            needsMore()
            return nil
        }
        guard characters[cursor] == "{" else { return nil }
        var depth = 0
        while cursor < characters.count {
            let character = characters[cursor]
            cursor += 1
            if character == "\\" {
                cursor = min(cursor + 1, characters.count)
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return cursor }
            }
        }
        return characters.count
    }

    private static func delimited(_ characters: [Character], from start: Int) -> Int {
        guard start < characters.count else { return characters.count }
        let delimiter = characters[start]
        var cursor = start + 1
        while cursor < characters.count, characters[cursor] != delimiter, characters[cursor] != "\n" { cursor += 1 }
        return min(cursor + 1, characters.count)
    }

    private static func skippingSpaces(_ characters: [Character], from start: Int) -> Int {
        var cursor = start
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        return cursor
    }

    private static func skipping(_ characters: [Character], optionalFrom start: Int) -> Int {
        guard start < characters.count, characters[start] == "[" else { return start }
        var cursor = start + 1
        var braces = 0
        while cursor < characters.count {
            let character = characters[cursor]
            cursor += 1
            if character == "{" { braces += 1 }
            if character == "}" { braces -= 1 }
            if character == "]", braces == 0 { break }
        }
        return cursor
    }

    private static func skipping(_ characters: [Character], groupFrom start: Int) -> Int {
        guard start < characters.count, characters[start] == "{" else { return start }
        var depth = 0
        var cursor = start
        while cursor < characters.count {
            if characters[cursor] == "\\" {
                cursor = min(cursor + 2, characters.count)
                continue
            }
            if characters[cursor] == "{" { depth += 1 }
            if characters[cursor] == "}" {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return characters.count
    }
}
