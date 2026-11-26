import Foundation

/// Only the selected output's direct scalar options are file instructions.
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
        func instruction<T>(_ key: String, parse: (String) -> T?) -> ReadingInstruction<T>? {
            guard let field = options.last(where: { $0.name == key }), let value = parse(field.value) else {
                return nil
            }
            return .init(value, source: ReadingInstructionSource(lines: lines, index: field.index))
        }
        func boolean(_ value: String) -> Bool? { Bool(value.lowercased()) }
        func depth(_ value: String) -> ReadingDepth? {
            guard let n = Int(value), n >= 0 else { return nil }
            return .levels(n)
        }
        numbers.present = instruction(quarto ? "number-sections" : "number_sections", parse: boolean)
        if quarto { numbers.depth = instruction("number-depth", parse: depth) }
        contents.present = instruction("toc", parse: boolean)
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
                if !content.isEmpty, !content.hasPrefix("#"),
                    next.distance(from: next.startIndex, to: content.startIndex) <= indent
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
