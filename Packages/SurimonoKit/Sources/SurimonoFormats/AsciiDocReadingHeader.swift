import Foundation
import JavaScriptCore

/// The parser supplies the last header entry it actually consumed for each component.
struct AsciiDocReadingHeader {
    var numbers = ReadingFileInstructions()
    var contents = ReadingFileInstructions()
    var ownsNumbers = false
    var lead: ReadingDepth?

    static func install(
        in context: JSContext, source: String, reading: FormatReadingSettings, contentsDepth: Int?
    ) -> () -> Self {
        var header = Self()
        let resolve: @convention(block) ([String: Int], [String: String], Bool) -> [String: Int] = {
            positions, attributes, nativeLead in
            var lines = positions.isEmpty ? [] : TextDecoding.normalizeNewlines(source).components(separatedBy: "\n")
            if lines.first?.first == "\u{feff}" { lines[0].removeFirst() }
            func reason(_ name: String) -> ReadingInstructionSource? {
                guard let line = positions[name], lines.indices.contains(line - 1) else { return nil }
                return ReadingInstructionSource(lines: lines[...], index: line - 1)
            }
            func instruction(_ presence: String, _ depth: String, enabled: Bool, defaultDepth: Int)
                -> ReadingFileInstructions
            {
                var file = ReadingFileInstructions()
                if let source = reason(presence) { file.present = .init(enabled, source: source) }
                if let source = reason(depth), let value = attributes[depth].flatMap(Int.init) {
                    file.depth = .init(.levels(value), source: source)
                }
                if file.present == nil, enabled {
                    file.manuscriptDepth = .levels(min(5, max(0, attributes[depth].flatMap(Int.init) ?? defaultDepth)))
                }
                return file
            }
            header.numbers = instruction(
                "sectnums", "sectnumlevels", enabled: attributes["sectnums"] != nil, defaultDepth: 3)
            header.contents = instruction("toc", "toclevels", enabled: nativeLead, defaultDepth: 2)
            let options = reading.resolve(
                for: .asciidoc, numbers: header.numbers, contents: header.contents, contentsDepth: contentsDepth)
            header.ownsNumbers = options.ownsNumbers
            header.lead = options.lead
            var changes: [String: Int] = [:]
            func apply(_ id: ReadingSettingID, file: ReadingFileInstructions, presence: String, levels: String) {
                let edits = reading.document.outlineOverrides(
                    id, for: .asciidoc, file: file, defaults: reading.defaults)
                changes[presence] = edits.present.map { $0 ? 1 : 0 }
                changes[levels] = edits.depth?.headingLevels
            }
            apply(.sectionNumbers, file: header.numbers, presence: "sectnums", levels: "sectnumlevels")
            if !reading.manuscriptContents {
                apply(.tableOfContents, file: header.contents, presence: "toc", levels: "toclevels")
            }
            if reading.separateContentsPage { changes["separatePage"] = 1 }
            if header.lead == .levels(0) { changes["partsOnly"] = 1 }
            return changes
        }
        context.setObject(resolve, forKeyedSubscript: "surimonoReadingHeader" as NSString)
        let label: @convention(block) ([String], String, String) -> String = { components, delimiter, suffix in
            SectionNumbers.label(components, delimiter: delimiter, suffix: suffix)
        }
        context.setObject(label, forKeyedSubscript: "surimonoSectionLabel" as NSString)
        return { header }
    }
}
