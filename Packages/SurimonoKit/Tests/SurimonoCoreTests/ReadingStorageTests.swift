import Foundation
import SurimonoCore
import Testing

struct ReadingStorageTests {
    @Test("旧 Org の文書は同じ平らな JSON に戻り、他形式の欄は増えない")
    func legacy() throws {
        let json = #"{"orgReading":{"allowsFileChanges":true,"tableOfContents":{"levels":{"_0":2}},"emphasis":false}}"#
        let settings = try JSONDecoder().decode(DocumentSettings.self, from: Data(json.utf8))
        #expect(settings.orgReading?.allowsFileChanges == true)
        #expect(settings.orgReading?.optionsLine == "#+OPTIONS: toc:2 *:nil")
        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let old = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["formatReading"] == nil)
        #expect(try #require(object["orgReading"] as? NSDictionary) == old["orgReading"] as? NSDictionary)
    }

    @Test("同じ項目を形式別に往復し、原稿が決めた成分や継承に戻した空の行は書かない")
    func roundTrip() throws {
        let source = ReadingInstructionSource(fileName: nil, lineNumber: 2, rawText: "toc: true")
        let file = ReadingFileInstructions(present: .init(true, source: source))
        var settings = DocumentSettings()
        settings.formatReading.set(
            .outline(present: true, depth: .levels(1)), for: .tableOfContents, format: .quarto, file: file)
        settings.formatReading.set(.outline(present: true, depth: .all), for: .tableOfContents, format: .markdown)
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try #require(object["formatReading"] as? NSDictionary)
        let expected: NSDictionary = [
            "quarto": ["tableOfContents": ["depth": 1]],
            "markdown": ["tableOfContents": ["present": true, "depth": "all"]],
        ]
        #expect(stored == expected && object["orgReading"] == nil)
        var restored = try JSONDecoder().decode(DocumentSettings.self, from: data)
        #expect(restored == settings)
        restored.formatReading.set(
            .outline(present: true, depth: .levels(3)), for: .tableOfContents, format: .quarto, file: file)
        restored.formatReading.set(
            .outline(present: false, depth: .levels(3)), for: .tableOfContents, format: .markdown)
        let empty = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect(empty["formatReading"] == nil)
    }

    @Test("新しい形式・項目や読めない深さがあっても、ほかの設定を読み戻す")
    func independentFields() throws {
        let data = Data(
            """
            {"formatReading":{"markdown":{"tableOfContents":{"present":true,"depth":"future"},"preserveBreaks":{"present":true},
            "future":{"present":false}},"future":5},"orgReading":{"title":false}}
            """.utf8)
        let restored = try JSONDecoder().decode(DocumentSettings.self, from: data)
        guard case .toggle(let breaks) = restored.formatReading.resolve(.preserveBreaks, for: .markdown),
            case .outline(let present, let depth) = restored.formatReading.resolve(.tableOfContents, for: .markdown)
        else {
            Issue.record("Markdown の項目がない")
            return
        }
        #expect(breaks.value && breaks.layer == .document)
        #expect(present.value && present.layer == .document)
        #expect(depth.value == .levels(3) && depth.layer == .app)
        #expect(restored.orgReading?.optionsLine == "#+OPTIONS: title:nil")
    }
}
