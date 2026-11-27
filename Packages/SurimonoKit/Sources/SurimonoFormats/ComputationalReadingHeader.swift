import Foundation

/// Read shared Quarto options and the first output format's own options.
struct ComputationalReadingHeader {
    var numbers = ReadingFileInstructions()
    var contents = ReadingFileInstructions()

    init() {}

    init(_ lines: ArraySlice<String>, format: DocumentFormat, metadata: [String: String]) {
        guard let root = Self.fields(in: lines, topLevel: true) else { return }
        let quarto = format == .quarto
        let container = root.last { $0.name == (quarto ? "format" : "output") }
        var options = quarto ? root : []
        if let container {
            guard let selected = container.firstFormatOptions(in: lines) else { return }
            options += selected
        }
        func instruction<T>(_ key: String, parse: (Field) -> T?) -> ReadingInstruction<T>? {
            guard let field = options.last(where: { $0.name == key }),
                field.value.isEmpty || field.value.hasPrefix("|") || field.value.hasPrefix(">")
                    || !field.hasChildren(in: lines), let value = parse(field)
            else {
                return nil
            }
            return .init(value, source: ReadingInstructionSource(lines: lines, index: field.index))
        }
        // These two top-level Quarto fields were decoded by ComputationalMetadata before reading settings.
        func scalar(_ field: Field) -> String {
            guard quarto, root.contains(where: { $0.index == field.index && $0.name == field.name }),
                ["number-sections", "toc-depth"].contains(field.name),
                !field.value.isEmpty || field.isScalarList(in: lines)
            else { return field.value }
            return metadata[field.name] ?? ComputationalMetadata.scalar(field.value)
        }
        func boolean(_ field: Field) -> Bool? {
            Bool(field.value.lowercased()) ?? Bool(scalar(field).lowercased())
        }
        func depth(_ field: Field) -> ReadingDepth? {
            guard let n = Int(field.value) ?? Int(scalar(field)), n >= 0 else { return nil }
            return .levels(n)
        }
        numbers.present = instruction(quarto ? "number-sections" : "number_sections", parse: boolean)
        if quarto { numbers.depth = instruction("number-depth", parse: depth) }
        contents.present = instruction("toc") { field in
            let children = lines[field.block]
            guard !field.value.isEmpty || field.isScalarList(in: lines) else { return nil }
            let items = MarkdownMetadata.items(field.value, children: children)
            return MarkdownMetadata.contentsPresence(field.value, items: items)
        }
        contents.depth = instruction(quarto ? "toc-depth" : "toc_depth", parse: depth)
    }

    private struct Field {
        let index: Int
        let name: String
        let value: String
        let block: Range<Int>

        func firstFormatOptions(in lines: ArraySlice<String>) -> [Field]? {
            if ComputationalMetadata.scalar(value).wholeMatch(of: /^[\w.+:-]+$/) != nil {
                return hasChildren(in: lines) ? nil : []
            }
            guard let formats = mapping(in: lines) else { return nil }
            guard let first = formats.first else { return [] }
            if first.value == "~" || first.value.lowercased() == "null"
                || ComputationalMetadata.scalar(first.value) == "default"
            {
                return first.hasChildren(in: lines) ? nil : []
            }
            return first.mapping(in: lines)
        }

        func hasChildren(in lines: ArraySlice<String>) -> Bool {
            lines[block].contains { !Self.isTrivia($0) }
        }

        func isScalarList(in lines: ArraySlice<String>) -> Bool {
            var indent: Int?
            for line in lines[block] where !Self.isTrivia(line) {
                let spaces = line.prefix(while: { $0 == " " }).count
                guard indent == nil || spaces == indent, line.dropFirst(spaces).hasPrefix("- ") else { return false }
                indent = spaces
            }
            return indent != nil
        }

        static func isTrivia(_ line: String) -> Bool {
            let trimmed = line.drop(while: \.isWhitespace)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }

        func mapping(in lines: ArraySlice<String>) -> [Field]? {
            if value.isEmpty { return fields(in: lines[block]) }
            guard !hasChildren(in: lines), value.hasPrefix("{"), value.hasSuffix("}") else { return nil }
            let body = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if body.isEmpty { return [] }
            guard let items = ComputationalMetadata.flowItems(body) else { return nil }
            var result: [Field] = []
            for item in items {
                guard let (name, raw) = pair(item, flow: true) else { return nil }
                result.append(Field(index: index, name: name, value: raw, block: index..<index))
            }
            return result
        }
    }

    /// Quoted flow keys allow an adjacent value. Within a plain key, bookdown::html_document2 is a single name.
    private static func pair(_ line: String, flow: Bool = false) -> (String, String)? {
        let text = MarkdownMetadata.withoutComment(line.trimmingCharacters(in: .whitespaces))
        let key: Substring
        let rest: Substring
        if let quoted = text.prefixMatch(of: /^(?:"(?:\\.|[^"\\])*"|'(?:''|[^'])*')/) {
            key = quoted.output
            rest = text[quoted.range.upperBound...].drop(while: \.isWhitespace)
            guard rest.first == ":" else { return nil }
        } else {
            guard
                let colon = text.indices.first(where: { index in
                    guard text[index] == ":" else { return false }
                    let next = text.index(after: index)
                    return next == text.endIndex || text[next].isWhitespace || (flow && "[{".contains(text[next]))
                })
            else { return nil }
            key = text[..<colon]
            guard let initial = key.first, !"[]{}&*!#|>@`'\"%".contains(initial),
                !("-?:".contains(initial) && key.dropFirst().first?.isWhitespace != false),
                !flow || !key.contains(where: { "[]{},".contains($0) })
            else { return nil }
            rest = text[colon...]
        }
        let value = rest.dropFirst()
        guard flow || value.first?.isWhitespace != false else { return nil }
        return (ComputationalMetadata.scalar(String(key)), value.trimmingCharacters(in: .whitespaces))
    }

    /// A tab after a block scalar's indentation is part of the text.
    private static func nextStructuralLine(after index: Int, in lines: ArraySlice<String>) -> Int {
        let line = lines[index]
        var next = index + 1
        guard line.contains("|") || line.contains(">") else { return next }
        var entry = line.drop(while: { $0 == " " })
        var sequenceIndent: Int?
        while entry.first == "-", entry.dropFirst().first?.isWhitespace == true {
            sequenceIndent = line.distance(from: line.startIndex, to: entry.startIndex)
            entry = entry.dropFirst().drop(while: \.isWhitespace)
        }
        let indicator: String
        let indent: Int
        if let (_, value) = pair(String(entry)) {
            indicator = value
            indent = line.distance(from: line.startIndex, to: entry.startIndex)
        } else if let sequenceIndent {
            indicator = MarkdownMetadata.withoutComment(entry.trimmingCharacters(in: .whitespaces))
            indent = sequenceIndent
        } else {
            return next
        }
        guard indicator.wholeMatch(of: /^[|>](?:[1-9][+-]?|[+-][1-9]?)?$/) != nil else { return next }
        var contentIndent = indicator.compactMap(\.wholeNumberValue).first.map { indent + $0 }
        while next < lines.endIndex {
            let body = lines[next]
            let text = body.drop(while: { $0 == " " })
            if !text.isEmpty {
                let spaces = body.distance(from: body.startIndex, to: text.startIndex)
                guard spaces >= (contentIndent ?? (indent + 1)) else { break }
                if contentIndent == nil { contentIndent = spaces }
            }
            next += 1
        }
        return next
    }

    private static func fields(in lines: ArraySlice<String>, topLevel: Bool = false) -> [Field]? {
        var siblingIndent: Int?
        var result: [Field] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let start = index
            let line = lines[index]
            index += 1
            let trimmed = line.drop(while: \.isWhitespace)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.distance(from: line.startIndex, to: trimmed.startIndex)
            guard line[..<trimmed.startIndex].allSatisfy({ $0 == " " }),
                siblingIndent == nil || siblingIndent == indent,
                let (name, value) = pair(line)
            else { return nil }
            siblingIndent = indent
            index = nextStructuralLine(after: start, in: lines)
            while index < lines.endIndex {
                let next = lines[index]
                let content = next.drop(while: \.isWhitespace)
                if !topLevel, !content.isEmpty, !content.hasPrefix("#"),
                    !next[..<content.startIndex].allSatisfy({ $0 == " " })
                {
                    return nil
                }
                let nextIndent = next.distance(from: next.startIndex, to: content.startIndex)
                if !content.isEmpty, !content.hasPrefix("#"),
                    nextIndent < indent || (nextIndent == indent && !content.hasPrefix("- "))
                {
                    break
                }
                index = nextStructuralLine(after: index, in: lines)
            }
            let field = Field(index: start, name: name, value: value, block: (start + 1)..<index)
            if !topLevel, !value.isEmpty, !value.hasPrefix("|"), !value.hasPrefix(">"), field.hasChildren(in: lines) {
                return nil
            }
            result.append(field)
        }
        return result
    }
}
