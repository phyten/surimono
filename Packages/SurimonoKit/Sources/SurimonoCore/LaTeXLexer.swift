import Foundation

/// The parts of LaTeX source that scans for structure must step over as one piece: a comment, `\verb|…|`,
/// `\lstinline`, and the body of a verbatim-like environment. Without this, `\end{quote}` or `\item` written inside
/// code would end an environment or split a list.
enum LaTeXLexer {
    static let verbatimEnvironments: Set<String> = [
        "verbatim", "verbatim*", "Verbatim", "lstlisting", "minted", "comment", "alltt",
    ]

    /// The index just past the opaque piece that starts at `index`, or nil when none starts there.
    static func opaqueEnd(_ characters: [Character], at index: Int) -> Int? {
        guard index < characters.count else { return nil }
        if characters[index] == "%" {
            var end = index
            while end < characters.count, characters[end] != "\n" { end += 1 }
            return end
        }
        guard characters[index] == "\\" else { return nil }
        if let name = word(characters, at: index + 1) {
            let after = index + 1 + name.count
            switch name {
            case "verb":
                var start = after
                if start < characters.count, characters[start] == "*" { start += 1 }
                return delimited(characters, from: start)
            case "lstinline", "mintinline":
                var start = skipping(characters, optionalFrom: after)
                if name == "mintinline" { start = skipping(characters, groupFrom: start) }
                if start < characters.count, characters[start] == "{" { return skipping(characters, groupFrom: start) }
                return delimited(characters, from: start)
            case "begin":
                guard after < characters.count, characters[after] == "{",
                    let close = characters[after...].firstIndex(of: "}")
                else { return nil }
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

    static func word(_ characters: [Character], at index: Int) -> String? {
        var end = index
        while end < characters.count, characters[end].isASCII, characters[end].isLetter { end += 1 }
        return end > index ? String(characters[index..<end]) : nil
    }

    private static func delimited(_ characters: [Character], from start: Int) -> Int {
        guard start < characters.count else { return characters.count }
        let delimiter = characters[start]
        var cursor = start + 1
        while cursor < characters.count, characters[cursor] != delimiter, characters[cursor] != "\n" { cursor += 1 }
        return min(cursor + 1, characters.count)
    }

    private static func skipping(_ characters: [Character], optionalFrom start: Int) -> Int {
        guard start < characters.count, characters[start] == "[",
            let close = characters[start...].firstIndex(of: "]")
        else { return start }
        return close + 1
    }

    private static func skipping(_ characters: [Character], groupFrom start: Int) -> Int {
        guard start < characters.count, characters[start] == "{" else { return start }
        var depth = 0
        var cursor = start
        while cursor < characters.count {
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
