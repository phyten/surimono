import Foundation

/// Read shared Quarto options and the first output format's own options.
struct ComputationalReadingHeader {
    var numbers = ReadingFileInstructions()
    var contents = ReadingFileInstructions()

    init() {}

    init(_ lines: ArraySlice<String>, format: DocumentFormat) {
        let root = Self.fields(in: lines)
        let quarto = format == .quarto
        let container = root.last { $0.name == (quarto ? "format" : "output") }
        let selected = container?.children(in: lines).first?.children(in: lines) ?? []
        let options = (quarto ? root : []) + selected
        func instruction<T>(_ key: String, parse: (Field) -> T?) -> ReadingInstruction<T>? {
            guard let field = options.last(where: { $0.name == key }), let value = parse(field) else {
                return nil
            }
            return .init(value, source: ReadingInstructionSource(lines: lines, index: field.index))
        }
        func boolean(_ field: Field) -> Bool? { Bool(field.value.lowercased()) }
        func depth(_ field: Field) -> ReadingDepth? {
            guard let n = Int(field.value), n >= 0 else { return nil }
            return .levels(n)
        }
        numbers.present = instruction(quarto ? "number-sections" : "number_sections", parse: boolean)
        if quarto { numbers.depth = instruction("number-depth", parse: depth) }
        contents.present = instruction("toc") { field in
            let children = lines[field.block]
            if field.value.isEmpty {
                let first = children.lazy.map { $0.drop(while: \.isWhitespace) }.first {
                    !$0.isEmpty && !$0.hasPrefix("#")
                }
                guard first?.hasPrefix("- ") == true else { return nil }
            }
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

        func children(in lines: ArraySlice<String>) -> [Field] {
            if value.isEmpty { return fields(in: lines[block]) }
            guard value.hasPrefix("{"), value.hasSuffix("}") else { return [] }
            var result: [Field] = []
            for item in ComputationalMetadata.items(String(value.dropFirst().dropLast())) {
                if let (name, raw) = pair(item) {
                    result.append(Field(index: index, name: name, value: raw, block: index..<index))
                }
            }
            return result
        }
    }

    /// A namespace such as bookdown::html_document2 contains colons that are part of its name.
    private static func pair(_ line: String) -> (String, String)? {
        let line = MarkdownMetadata.withoutComment(line.trimmingCharacters(in: .whitespaces))
        guard
            let colon = line.indices.first(where: {
                line[$0] == ":" && (line.index(after: $0) == line.endIndex || line[line.index(after: $0)].isWhitespace)
            })
        else { return nil }
        let key = ComputationalMetadata.scalar(String(line[..<colon]))
        return (key, String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func fields(in lines: ArraySlice<String>) -> [Field] {
        var result: [Field] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let start = index
            let line = lines[index]
            index += 1
            let trimmed = line.drop(while: \.isWhitespace)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.distance(from: line.startIndex, to: trimmed.startIndex)
            while index < lines.endIndex {
                let next = lines[index]
                let content = next.drop(while: \.isWhitespace)
                let nextIndent = next.distance(from: next.startIndex, to: content.startIndex)
                if !content.isEmpty, !content.hasPrefix("#"),
                    nextIndent < indent || (nextIndent == indent && !content.hasPrefix("- "))
                {
                    break
                }
                index += 1
            }
            guard let (name, value) = pair(line) else { continue }
            result.append(Field(index: start, name: name, value: value, block: (start + 1)..<index))
        }
        return result
    }
}
