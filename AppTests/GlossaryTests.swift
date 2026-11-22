import Foundation
import Testing

/// Keeps `GLOSSARY.md` and the string catalogue from drifting apart.
///
/// The glossary is the one place that says which word each language uses for a concept. Each row names a
/// catalogue key whose translations must contain that row's words, so changing a translation without
/// changing the glossary (or the reverse) fails here instead of quietly splitting a term in two.
struct GlossaryTests {
    private static let languages = ["en", "ja", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"]

    @Test("用語集は 8 言語の列を持ち、どの行にも空の欄がない")
    func tableShape() throws {
        let rows = try Self.rows()
        #expect(rows.count >= 20)
        for row in rows {
            #expect(!row.concept.isEmpty, "\(row.key)")
            for language in Self.languages {
                #expect(!(row.terms[language] ?? "").isEmpty, "\(row.key) [\(language)]")
            }
        }
        #expect(Set(rows.map(\.key)).count == rows.count, "同じキーを 2 行で使わない")
    }

    @Test("用語集の語は、確かめるキーの訳に各言語で入っている")
    func termsMatchCatalogue() throws {
        let catalog = try Self.catalog()
        for row in try Self.rows() {
            let entry = try #require(catalog.strings[row.key], "カタログにキーがない: \(row.key)")
            for language in Self.languages {
                let term = try #require(row.terms[language])
                // English is the key itself; the other languages are read from the catalogue.
                let text = language == "en" ? row.key : entry.localizations[language]?.stringUnit?.value
                let value = try #require(text, "\(row.key) [\(language)] に訳がない")
                #expect(
                    value.localizedCaseInsensitiveContains(term),
                    "\(row.key) [\(language)] は「\(term)」のはずが「\(value)」")
            }
        }
    }

    private struct Row {
        let concept: String
        let key: String
        let terms: [String: String]
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func rows() throws -> [Row] {
        let text = try String(contentsOf: root.appending(path: "GLOSSARY.md"), encoding: .utf8)
        var header: [String]?
        var rows: [Row] = []
        for line in text.split(separator: "\n") where line.hasPrefix("|") {
            let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let columns = header else {
                header = cells
                continue
            }
            // The separator row under the header holds only dashes.
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" } }) { continue }
            try #require(cells.count == columns.count, "列の数が見出しと違う: \(line)")
            var terms: [String: String] = [:]
            for (column, cell) in zip(columns, cells).dropFirst(2) { terms[column] = cell }
            let key = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            rows.append(Row(concept: cells[0], key: key, terms: terms))
        }
        let columns = try #require(header)
        #expect(Array(columns.dropFirst(2)) == languages, "言語の列の並び")
        return rows
    }

    private static func catalog() throws -> Catalog {
        try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
    }

    private struct Catalog: Decodable { let strings: [String: Entry] }
    private struct Entry: Decodable { let localizations: [String: Translation] }
    private struct Translation: Decodable { let stringUnit: Unit? }
    private struct Unit: Decodable { let value: String }
}
