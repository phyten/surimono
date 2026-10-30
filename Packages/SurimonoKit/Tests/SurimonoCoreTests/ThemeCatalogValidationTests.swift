import Foundation
import Testing

@testable import SurimonoCore

struct ThemeCatalogValidationTests {
    private func catalog(categories: [String], featured: [String], themes: [(String, String)]) -> Data {
        let json: [String: Any] = [
            "categories": categories.map { ["id": $0, "name": $0, "ja": $0] },
            "featured": featured,
            "themes": themes.map { ["id": $0.0, "name": $0.0, "ja": $0.0, "category": $0.1] },
        ]
        // The dictionary above only holds strings and arrays, which JSONSerialization always accepts.
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    @Test("目録の正しい形はそのまま読める")
    func validCatalog() throws {
        let data = catalog(categories: ["a", "b"], featured: ["x"], themes: [("x", "a"), ("y", "b")])
        #expect(try PrintThemeLibrary.catalog(from: data).themes.count == 2)
    }

    @Test("同じカテゴリーの id が二度あれば読まない")
    func duplicateCategory() {
        let data = catalog(categories: ["a", "a"], featured: [], themes: [("x", "a")])
        #expect(throws: PrintThemeLibrary.CatalogError.duplicateCategory("a")) {
            try PrintThemeLibrary.catalog(from: data)
        }
    }

    @Test("同じテーマの id が二度あれば読まない")
    func duplicateTheme() {
        let data = catalog(categories: ["a"], featured: [], themes: [("x", "a"), ("x", "a")])
        #expect(throws: PrintThemeLibrary.CatalogError.duplicateTheme("x")) {
            try PrintThemeLibrary.catalog(from: data)
        }
    }

    @Test("目録にないカテゴリーのテーマがあれば読まない")
    func unknownCategory() {
        let data = catalog(categories: ["a"], featured: [], themes: [("x", "b")])
        #expect(throws: PrintThemeLibrary.CatalogError.unknownCategory(theme: "x", category: "b")) {
            try PrintThemeLibrary.catalog(from: data)
        }
    }

    @Test("定番に目録にないテーマや同じテーマが二度あれば読まない")
    func featuredReferences() {
        #expect(throws: PrintThemeLibrary.CatalogError.unknownFeaturedTheme("z")) {
            try PrintThemeLibrary.catalog(from: catalog(categories: ["a"], featured: ["z"], themes: [("x", "a")]))
        }
        #expect(throws: PrintThemeLibrary.CatalogError.duplicateFeaturedTheme("x")) {
            try PrintThemeLibrary.catalog(from: catalog(categories: ["a"], featured: ["x", "x"], themes: [("x", "a")]))
        }
    }
}
