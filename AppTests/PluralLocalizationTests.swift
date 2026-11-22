import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct PluralLocalizationTests {
    @Test("英語の印刷概要はページ数と用紙枚数をそれぞれ単複変化させる")
    func englishSummary() {
        #expect(summary(pages: 1, layout: .a4Single, language: "en") == "1 page → A4 1 sheet (Single-sided)")
        #expect(summary(pages: 2, layout: .a4Duplex, language: "en") == "2 pages → A4 1 sheet (Duplex, long edge)")
        #expect(summary(pages: 2, layout: .a4Single, language: "en") == "2 pages → A4 2 sheets (Single-sided)")
    }

    @Test("フランス語の印刷概要はページ数と用紙枚数をそれぞれ単複変化させる")
    func frenchSummary() {
        #expect(summary(pages: 1, layout: .a4Single, language: "fr") == "1 page → A4, 1 feuille (Recto)")
        #expect(
            summary(pages: 2, layout: .a4Duplex, language: "fr") == "2 pages → A4, 1 feuille (Recto verso, bord long)")
        #expect(summary(pages: 2, layout: .a4Single, language: "fr") == "2 pages → A4, 2 feuilles (Recto)")
    }

    @Test("画像数が第2引数でも単複を選びファイル名を保持する")
    func imageCounts() throws {
        for language in ["en", "fr"] {
            let bundle = try languageBundle(language)
            let template = bundle.localizedString(forKey: "%@ — %lld images", value: nil, table: nil)
            #expect(String(format: template, locale: Locale(identifier: language), "sample", 1) == "sample — 1 image")
            #expect(String(format: template, locale: Locale(identifier: language), "sample", 2) == "sample — 2 images")
        }
    }

    @Test("フランス語の除外件数は名詞と分詞をともに単複変化させる")
    func excludedFiles() throws {
        let bundle = try languageBundle("fr")
        let template = bundle.localizedString(forKey: "%lld non-image files excluded (%@)", value: nil, table: nil)
        #expect(
            String(format: template, locale: Locale(identifier: "fr"), 1, "txt") == "1 fichier non image exclu (txt)")
        #expect(
            String(format: template, locale: Locale(identifier: "fr"), 2, "txt") == "2 fichiers non image exclus (txt)")
    }

    @Test("手動両面の枚数は物理用紙の単複を選びプリンター名を保つ")
    func manualDuplexCounts() {
        let key = "Fronts sent: %lld sheets. (Printer: %@)"
        #expect(PrintModeText.format(key, language: "en", 1, "A") == "Fronts sent: 1 sheet. (Printer: A)")
        #expect(PrintModeText.format(key, language: "en", 3, "A") == "Fronts sent: 3 sheets. (Printer: A)")
        #expect(PrintModeText.format(key, language: "ja", 3, "A") == "表を 3 枚送りました。（プリンター：A）")
        #expect(
            PrintModeText.format(key, language: "fr", 1, "A")
                == "Rectos envoyés\u{00A0}: 1 feuille. (Imprimante\u{00A0}: A)")
        #expect(
            PrintModeText.format(key, language: "fr", 3, "A")
                == "Rectos envoyés\u{00A0}: 3 feuilles. (Imprimante\u{00A0}: A)")
    }

    private func summary(pages: Int, layout: PrintLayout, language: String) -> String {
        DocumentViewModel.summaryText(
            PrintSummary(plan: Imposition.plan(pageCount: pages, layout: layout)),
            layout: layout, locale: Locale(identifier: language))
    }

    private func languageBundle(_ language: String) throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }
}
