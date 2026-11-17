import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct SettingSetSummaryTests {
    @Test("部分ごとの概要は順に並び消えたスタイルとプリセットは表示しない")
    func lines() throws {
        let summary = SettingSetSummary(themes: [], presets: [], language: "en", unit: .millimeters)
        let set = PrintSettingSet(
            name: "Summary",
            settings: DocumentSettings(
                layoutID: "a4Duplex", themeID: "missing", textScale: 1.25, presetID: "missing",
                printOptions: PrintOptions(marginsInMillimeters: 15, showsPageNumbers: true)))
        #expect(summary.line(.style, in: set) == nil)
        #expect(summary.line(.htmlPreset, in: set) == nil)
        #expect(summary.lines(set).count == 3)
        #expect(summary.lines(set).first == PrintLayout.a4Duplex.displayName(language: "en"))
        #expect(summary.line(.margins, in: set)?.contains("15") == true)
        #expect(summary.oneLine(set) == summary.lines(set).joined(separator: " · "))
    }

    @Test("インチを使う地域では、セットの余白と文字の大きさを端数のまま概要に出す")
    func fineValuesInInches() {
        let summary = SettingSetSummary(themes: [], presets: [], language: "en", unit: .inches)
        let set = PrintSettingSet(
            name: "Fine",
            settings: DocumentSettings(textScale: 1.13, printOptions: PrintOptions(marginsInMillimeters: 12.5)))
        #expect(summary.line(.margins, in: set) == "Margins: 0.49 in")
        #expect(summary.line(.style, in: set) == "Text: 113%")
        let millimeters = SettingSetSummary(themes: [], presets: [], language: "en", unit: .millimeters)
        #expect(millimeters.line(.margins, in: set) == "Margins: 12.5 mm")
    }

    @Test("文字サイズだけのセットも概要に残り副題は文字を壊さず60文字に収まる")
    func textOnlyAndTruncation() {
        let summary = SettingSetSummary(themes: [], presets: [], language: "en", unit: .millimeters)
        let set = PrintSettingSet(name: "Text", settings: DocumentSettings(textScale: 1.25))
        #expect(summary.lines(set) == ["Text: 125%"])
        #expect(SettingSetSummary.shortened("Short") == "Short")
        let long = String(repeating: "あ👨‍👩‍👧", count: 40)
        let result = SettingSetSummary.shortened(long)
        #expect(result.count == 60)
        #expect(result == String(long.prefix(59)) + "…")
    }
}
