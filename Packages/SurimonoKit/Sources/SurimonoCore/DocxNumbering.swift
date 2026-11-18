import Foundation

/// Mammoth preserves list nesting but drops numId, startOverride and the start of each abstract level.
/// Match numbered paragraphs in reading order, including repeated text, before writing HTML counters.
struct DocxNumbering {
    private struct Level {
        let ordered: Bool
        let start: Int
    }

    private struct Key: Hashable {
        let id: String
        let level: Int
    }

    private var values: [String: [Int]] = [:]

    init(document: XMLDocument?, numbering: Data?, styles: XMLDocument?) {
        guard let numbering, let document,
            let definitions = try? XMLDocument(data: numbering, options: [.nodeLoadExternalEntitiesNever]),
            let root = definitions.rootElement()
        else { return }

        var levels: [Key: Level] = [:]
        var instances: [String: String] = [:]
        var styleLevels: [String: Key] = [:]
        var defaultInstances: [String: String] = [:]
        var overrides: [Key: Int] = [:]
        for abstract in root.elements(forLocalName: "abstractNum", uri: root.uri) {
            guard let id = Self.attribute(abstract, "abstractNumId") else { continue }
            for element in abstract.elements(forLocalName: "lvl", uri: root.uri) {
                let index = Int(Self.attribute(element, "ilvl") ?? "") ?? 0
                let key = Key(id: id, level: index)
                if let style = Self.childValue(element, "pStyle") { styleLevels[style] = key }
                levels[key] = Level(
                    ordered: Self.childValue(element, "numFmt") != "bullet",
                    start: Int(Self.childValue(element, "start") ?? "") ?? 1)
            }
        }
        for num in root.elements(forLocalName: "num", uri: root.uri) {
            guard let id = Self.attribute(num, "numId") else { continue }
            guard let abstract = Self.childValue(num, "abstractNumId") else { continue }
            instances[id] = abstract
            if defaultInstances[abstract] == nil { defaultInstances[abstract] = id }
            for override in num.elements(forLocalName: "lvlOverride", uri: root.uri) {
                let index = Int(Self.attribute(override, "ilvl") ?? "") ?? 0
                overrides[Key(id: id, level: index)] = Self.childValue(override, "startOverride").flatMap(Int.init)
            }
        }

        guard let properties = try? document.nodes(forXPath: "//*[local-name()='p']/*[local-name()='pPr']")
        else { return }
        var styleInstances: [String: String] = [:]
        let stylePath = "/*/*[local-name()='style']/*[local-name()='pPr']/*[local-name()='numPr']"
        if let numberedStyles = try? styles?.nodes(forXPath: stylePath) {
            for case let num as XMLElement in numberedStyles {
                if let style = num.parent?.parent as? XMLElement, let id = Self.attribute(style, "styleId") {
                    styleInstances[id] = Self.childValue(num, "numId")
                }
            }
        }
        var counters: [String: [Int: Int]] = [:]
        for case let property as XMLElement in properties {
            let num = property.elements(forLocalName: "numPr", uri: property.uri).first
            let styleID = Self.childValue(property, "pStyle")
            let style = styleID.flatMap { styleLevels[$0] }
            let id =
                num.flatMap { Self.childValue($0, "numId") } ?? styleID.flatMap { styleInstances[$0] }
                ?? style.flatMap { defaultInstances[$0.id] }
            guard let id, let abstract = instances[id] else { continue }
            let index = num.flatMap { Self.childValue($0, "ilvl") }.flatMap(Int.init) ?? style?.level ?? 0
            guard (0..<9).contains(index), let level = levels[Key(id: abstract, level: index)] else { continue }
            let start = overrides[Key(id: id, level: index)] ?? level.start
            var counts = counters[id, default: [:]].filter { $0.key <= index }
            let next = counts[index].map { $0 == Int.max ? $0 : $0 + 1 } ?? start
            counts[index] = next
            counters[id] = counts
            if level.ordered, let paragraph = property.parent,
                let runs = try? paragraph.nodes(forXPath: ".//*[local-name()='t']")
            {
                let text = runs.compactMap(\.stringValue).joined()
                values[text, default: []].append(next)
            }
        }
        for key in values.keys { values[key]?.reverse() }
    }

    mutating func take(for text: String) -> Int? { values[text]?.popLast() }

    private static func attribute(_ element: XMLElement, _ name: String) -> String? {
        element.attribute(forLocalName: name, uri: element.uri)?.stringValue
    }

    private static func childValue(_ element: XMLElement, _ name: String) -> String? {
        element.elements(forLocalName: name, uri: element.uri).first.flatMap { attribute($0, "val") }
    }
}
