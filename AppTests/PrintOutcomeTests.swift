import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct PrintOutcomeTests {
    /// The text without the no-break spaces and hyphens that keep its parts together where it wraps.
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2011}", with: "-")
    }

    @Test("1行目は、実際に使う用紙と枚数と片面か両面かを言う")
    func lead() {
        let outcome = PrintOutcome(layout: .a4Single, paper: .a4, sheets: 38, pages: 38, body: 38)
        #expect(plain(outcome.lead(language: "ja")) == "用紙 A4・38 枚・片面")
        #expect(plain(outcome.lead(language: "en")) == "Paper A4 · 38 sheets · One-Sided")
        #expect(outcome.detail(language: "ja") == nil)
    }

    @Test("A4 冊子は、用紙が A3 と出て、仕上がりを2行目に言う")
    func booklet() {
        let outcome = PrintOutcome(
            layout: .a3BookletA4, paper: .a3, sheets: 10, pages: 40, body: 38, blanks: 2)
        #expect(plain(outcome.lead(language: "ja")) == "用紙 A3・10 枚・両面")
        #expect(plain(outcome.detail(language: "ja")) == "仕上がり A4 冊子・40 ページ（本文 38＋白紙 2）")
        #expect(
            plain(outcome.detail(language: "en"))
                == "Finished: A4 booklet · 40 pages (Body 38 + Blank 2)")
    }

    @Test("白紙・目次・ノートの内訳は、足すと全体のページ数になる")
    func partsAddUp() {
        let outcome = PrintOutcome(
            layout: .a4Duplex, paper: .a4, sheets: 25, pages: 50, body: 40, contents: 2, notes: 6, blanks: 2)
        #expect(plain(outcome.detail(language: "ja")) == "50 ページ（本文 40＋目次 2＋ノート 6＋白紙 2）")
        #expect(40 + 2 + 6 + 2 == outcome.pages)
    }

    @Test("折り返しても、数と単位、区切りの前の語は離れない")
    func keepsPartsTogether() {
        let outcome = PrintOutcome(
            layout: .a3BookletA4, paper: .a3, sheets: 10, pages: 40, body: 38, blanks: 2)
        #expect(outcome.lead(language: "en") == "Paper A3\u{00A0}· 10\u{00A0}sheets\u{00A0}· Two\u{2011}Sided")
        #expect(outcome.detail(language: "en")?.contains("40\u{00A0}pages") == true)
        #expect(outcome.detail(language: "en")?.contains("Blank\u{00A0}2") == true)
    }

    @Test("2部のときは、1行目が合計の枚数で、2行目に1部あたりと合計を言う")
    func copies() {
        let outcome = PrintOutcome(layout: .a3BookletA4, paper: .a3, sheets: 10, pages: 40, body: 40, copies: 2)
        #expect(plain(outcome.lead(language: "ja")) == "用紙 A3・20 枚・両面")
        #expect(plain(outcome.detail(language: "ja")) == "仕上がり A4 冊子・1 部 10 枚・合計 20 枚")
        #expect(
            plain(outcome.detail(language: "en"))
                == "Finished: A4 booklet · 10 sheets per copy · 20 sheets in total")
    }

    @Test("2ページを1枚には、仕上がりのページの大きさを2行目に言う")
    func twoUp() {
        let outcome = PrintOutcome(layout: .a3TwoUp, paper: .a3, sheets: 19, pages: 38, body: 38)
        #expect(plain(outcome.lead(language: "ja")) == "用紙 A3・19 枚・片面")
        #expect(plain(outcome.detail(language: "ja")) == "仕上がり A4 2 ページを 1 枚に")
    }

    @Test("4ページを1枚と3ページ＋メモは、カードの名前の繰り返しを2行目に出さない")
    func noRepeat() {
        #expect(
            PrintOutcome(layout: .a4FourUp, paper: .a4, sheets: 10, pages: 40, body: 40).detail(language: "ja") == nil)
        #expect(
            PrintOutcome(layout: .a4Handout3, paper: .a4, sheets: 13, pages: 39, body: 39).detail(language: "ja")
                == nil)
    }

    @Test("縦と横が混ざる用紙は、その数を2行目に言う")
    func mixed() {
        let outcome = PrintOutcome(
            layout: .a4Single, paper: .a4, sheets: 3, pages: 3, body: 3,
            orientations: [.portrait, .landscape, .landscape])
        #expect(plain(outcome.detail(language: "ja")) == "縦 1 枚・横 2 枚")
    }

    @Test("1行目と2行目は8言語のどれでも翻訳され、書式の記号が残らない")
    func languages() {
        let outcome = PrintOutcome(
            layout: .a3BookletA4, paper: .a3, sheets: 10, pages: 40, body: 38, blanks: 2, copies: 2)
        for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"] {
            let lead = outcome.lead(language: language)
            let detail = outcome.detail(language: language) ?? ""
            #expect(!lead.contains("%") && !detail.contains("%"), "\(language)")
            #expect(lead.contains("A3") && lead.contains("20"), "\(language)")
            #expect(detail.contains("A4") && detail.contains("10") && detail.contains("38"), "\(language)")
        }
    }

    @Test("表示画面の帯の「印刷」は、8言語のどれでも省略記号を付けない")
    func bandPrintHasNoEllipsis() {
        for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"] {
            let title = PrintModeText.string(PrintButton.titleKey, language: language)
            #expect(!title.contains("…") && !title.contains("..."), "\(language): \(title)")
            #expect(title == PrintModeText.string("Print", language: language), "\(language)")
        }
        // The File menu's item keeps its ellipsis: it opens the print screen, and only on the tray prints at once.
        #expect(PrintModeText.string("Print…", language: "ja") == "印刷…")
    }
}
