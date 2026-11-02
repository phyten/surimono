import Foundation
import Testing

@testable import SurimonoCore

struct PrintSettingSetTests {
    @Test("形式の集合からテーマと文字サイズとHTMLプリセットを同時に適用する")
    func mixedFormats() {
        let set = PrintSettingSet(
            name: "Mixed",
            settings: DocumentSettings(
                themeID: "mincho", textScale: 1.5, presetID: "article"))
        let mixed = set.applicable(to: [.markdown, .html, .pdf], themeIDs: ["mincho"], presetIDs: ["article"])
        #expect(mixed == set)
        let images = set.applicable(to: [.pdf, .image], themeIDs: ["mincho"], presetIDs: ["article"])
        #expect(images.themeID == nil && images.textScale == nil && images.presetID == nil)
        let missing = set.applicable(to: [.org, .html], themeIDs: [], presetIDs: [])
        #expect(missing.themeID == nil && missing.textScale == 1.5 && missing.presetID == nil)
    }

    @Test("設定セットは印刷に使う項目だけを取り出し往復できる")
    func roundTrip() throws {
        let settings = DocumentSettings(
            view: ViewOptions(layout: .spread, scrollAxis: .vertical, transition: .fade, showsCoverAlone: true),
            zoom: 2, layoutID: "a4Duplex", themeID: "mincho", textScale: 1.25,
            printOptions: PrintOptions(marginsInMillimeters: 12, showsPageNumbers: true, rotatesBackSides: true),
            paperOrientation: .landscape)
        let set = PrintSettingSet(name: "Book", settings: settings)
        let data = try JSONEncoder().encode(set)
        #expect(try JSONDecoder().decode(PrintSettingSet.self, from: data) == set)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(object.keys) == [
                "id", "name", "layoutID", "paperOrientation", "marginsInMillimeters", "showsPageNumbers", "themeID",
                "textScale",
            ])
    }

    @Test("未知の項目や読めない項目があっても他の項目を残す")
    func tolerantDecoding() throws {
        let data = Data(
            """
            {"id":"00000000-0000-0000-0000-000000000001","name":"Partial",
             "layoutID":"future","paperOrientation":"future","textScale":"large",
             "showsPageNumbers":true,"future":{"a":1}}
            """.utf8)
        let set = try JSONDecoder().decode(PrintSettingSet.self, from: data)
        #expect(set.layoutID == "future")
        #expect(set.paperOrientation == nil)
        #expect(set.textScale == nil)
        #expect(set.showsPageNumbers == true)
        #expect(set.marginsInMillimeters == nil)
    }

    @Test(
        "識別子や名前を読めない設定セットは復元しない",
        arguments: [
            #"{"name":"Set"}"#, #"{"id":"bad","name":"Set"}"#,
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"  "}"#,
        ])
    func invalidIdentity(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PrintSettingSet.self, from: Data(json.utf8))
        }
    }

    @Test("文書に使えない形式の設定と消えた識別子だけを除く")
    func applicableFields() {
        let set = PrintSettingSet(
            name: "Mixed",
            settings: DocumentSettings(
                layoutID: "missing", themeID: "missing", textScale: 1.5, presetID: "article",
                printOptions: PrintOptions(marginsInMillimeters: 10)))
        let markdown = set.applicable(to: .markdown, themeIDs: ["standard"], presetIDs: ["article"])
        #expect(markdown.layoutID == nil)
        #expect(markdown.themeID == nil)
        #expect(markdown.textScale == 1.5)
        #expect(markdown.presetID == nil)
        let html = set.applicable(to: .html, themeIDs: [], presetIDs: ["article"])
        #expect(html.themeID == nil && html.textScale == nil)
        #expect(html.presetID == "article")
        #expect(set.applicable(to: .html, themeIDs: [], presetIDs: []).presetID == nil)
        let pdf = set.applicable(to: .pdf, themeIDs: ["missing"], presetIDs: ["article"])
        #expect(pdf.themeID == nil && pdf.textScale == nil && pdf.presetID == nil)
        #expect(pdf.marginsInMillimeters == 10)
    }

    @Test("一致判定はセットが持つ項目だけを比較し裏面回転や表示を無視する")
    func matchesOnlyIncludedFields() {
        var current = DocumentSettings(
            zoom: 3, layoutID: "a4Duplex", themeID: "mincho",
            printOptions: PrintOptions(marginsInMillimeters: 10, showsPageNumbers: true, rotatesBackSides: true))
        let set = PrintSettingSet(
            name: "Paper",
            settings: DocumentSettings(
                layoutID: "a4Duplex", printOptions: PrintOptions(marginsInMillimeters: 10, showsPageNumbers: true)))
        #expect(set.matches(current))
        current.printOptions?.showsPageNumbers = false
        #expect(!set.matches(current))
        #expect(!PrintSettingSet(name: "Empty", settings: DocumentSettings()).matches(current))
    }

    @Test(
        "保存した各項目が変わると一致しなくなる",
        arguments: [
            "layout", "orientation", "margin", "numbers", "theme", "scale", "preset",
        ])
    func detectsEachDifference(field: String) {
        var current = DocumentSettings(
            layoutID: "a4Duplex", themeID: "mincho", textScale: 1.25, presetID: "none",
            printOptions: PrintOptions(), paperOrientation: .auto)
        let set = PrintSettingSet(name: "All", settings: current)
        #expect(set.matches(current))
        switch field {
        case "layout": current.layoutID = "a4Single"
        case "orientation": current.paperOrientation = .landscape
        case "margin": current.printOptions?.marginsInMillimeters = 20
        case "numbers": current.printOptions?.showsPageNumbers = true
        case "theme": current.themeID = "standard"
        case "scale": current.textScale = 1.5
        case "preset": current.presetID = "article"
        default: Issue.record("Unknown field")
        }
        #expect(!set.matches(current))
    }

    @Test("不正な余白や対応しない文字倍率だけを当てずに飛ばす")
    func invalidNumbers() {
        let set = PrintSettingSet(
            name: "Invalid",
            settings: DocumentSettings(
                layoutID: "a4Duplex", textScale: 1.23, printOptions: PrintOptions(marginsInMillimeters: -10)))
        let applicable = set.applicable(to: .markdown, themeIDs: [], presetIDs: [])
        #expect(applicable.layoutID == "a4Duplex")
        #expect(applicable.marginsInMillimeters == nil)
        #expect(applicable.textScale == nil)
    }
}
