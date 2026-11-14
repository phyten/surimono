import Foundation

/// A deliberately small mapping inside the converter's front matter, never a general YAML parser.
public struct DocumentDirectives: Equatable, Sendable {
    public var setName: String?
    public var layoutID: String?
    public var orientation: PaperOrientation?
    public var marginMillimeters: Double?
    public var style: String?
    public var textScale: Double?

    public var isEmpty: Bool {
        setName == nil && layoutID == nil && orientation == nil && marginMillimeters == nil
            && style == nil && textScale == nil
    }

    public init() {}

    public static func read(fromMarkdown text: String) -> DocumentDirectives {
        let lines = TextDecoding.normalizeNewlines(text).components(separatedBy: "\n")
        var result = DocumentDirectives()
        guard let end = MarkdownConverter.frontMatterEnd(in: lines) else { return result }
        var inMapping = false
        var childIndent: Int?
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if indent == 0 {
                inMapping = trimmed == "surimono:"
                childIndent = nil
                continue
            }
            guard inMapping else { continue }
            if childIndent == nil { childIndent = indent }
            guard indent == childIndent, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon])
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                guard value.count >= 2, value.last == quote else { continue }
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            switch key {
            case "set": result.setName = value
            case "layout": result.layoutID = value
            case "style": result.style = value
            case "orientation":
                if value == "portrait" { result.orientation = .portrait }
                if value == "landscape" { result.orientation = .landscape }
            case "margins":
                let units: [(String, Double)] = [("mm", 1), ("cm", 10), ("in", 25.4)]
                let unit = units.first { value.hasSuffix($0.0) }
                let number = unit.map { String(value.dropLast($0.0.count)) } ?? value
                if let parsed = Double(number.trimmingCharacters(in: .whitespaces)) {
                    let millimeters = parsed * (unit?.1 ?? 1)
                    if millimeters.isFinite, (0...50).contains(millimeters) { result.marginMillimeters = millimeters }
                }
            case "text-size":
                let percent = value.hasSuffix("%")
                if let parsed = Double(percent ? String(value.dropLast()) : value), parsed.isFinite {
                    let scale = percent ? parsed / 100 : parsed
                    result.textScale = min(max(scale, TextScale.steps.first ?? 0.8), TextScale.steps.last ?? 2)
                }
            default: break
            }
        }
        return result
    }
}
