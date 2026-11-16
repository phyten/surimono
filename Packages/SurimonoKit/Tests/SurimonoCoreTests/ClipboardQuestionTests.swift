import Foundation
import SurimonoCore
import Testing

struct ClipboardQuestionTests {
    private func question(_ text: String, settings: ClipboardFormatSettings = .standard) -> ClipboardQuestion {
        ClipboardQuestion(
            text: text, detection: ClipboardFormatDetector.detect(text, settings: settings), settings: settings)
    }

    @Test("選べる形式は Markdown・Org・HTML・LaTeX・CSV・テキストの順で URL を含まない")
    func choosableKinds() {
        #expect(ClipboardTextKind.choosable == [.markdown, .org, .html, .latex, .csv, .plainText])
    }

    @Test("種類は同じ名前の文書の形式で開き、URL はテキストで開く")
    func documentFormats() {
        #expect(ClipboardTextKind.markdown.documentFormat == .markdown)
        #expect(ClipboardTextKind.org.documentFormat == .org)
        #expect(ClipboardTextKind.html.documentFormat == .html)
        #expect(ClipboardTextKind.latex.documentFormat == .latex)
        #expect(ClipboardTextKind.csv.documentFormat == .csv)
        #expect(ClipboardTextKind.plainText.documentFormat == .plainText)
        #expect(ClipboardTextKind.url.documentFormat == .plainText)
        #expect(ClipboardTextKind(.csv) == .csv)
        #expect(ClipboardTextKind(.plainText) == .plainText)
        #expect(ClipboardTextKind(.pdf) == nil)
    }

    @Test("2 つの形式が近いときは最上位を最初に選び、両方とテキストを並べて残りを畳む")
    func competing() {
        let asked = question("# Groceries\n* milk\n* eggs\n* bread\n# Chores\n* laundry\n* dishes\n")
        #expect(asked.reason == .competingFormats)
        #expect(asked.preferred == .markdown)
        #expect(asked.competing == [.markdown, .org])
        #expect(asked.options.map(\.kind) == [.markdown, .org, .plainText])
        #expect(asked.others.map(\.kind) == [.html, .latex, .csv])
    }

    @Test("テキストの点数が 2 つの形式のあいだでも、テキストは最後の行に並び、最初の選択は判定器の勧めのまま")
    func plainTextComesLast() {
        let asked = question("* **First**\n* **Second**\n* **Third**")
        #expect(asked.options.map(\.kind) == [.markdown, .org, .plainText])
        #expect(asked.preferred == .plainText)
    }

    @Test("どの形式も確かめられないときはテキストを最初に選び、手がかりのあった形式も並べる")
    func unsure() {
        let asked = question("# 見出し")
        #expect(asked.reason == .insufficientStructure)
        #expect(asked.preferred == .plainText)
        #expect(asked.options.map(\.kind) == [.markdown, .plainText])
        #expect(asked.options.first?.evidence == [.headings(1)])
        #expect(asked.others.map(\.kind) == [.org, .html, .latex, .csv])
        #expect(asked.others.allSatisfy { $0.evidence.isEmpty })
        #expect(asked.competing.isEmpty)
    }

    @Test("自動の判定から外した形式は手がかりがあっても畳んだ側に根拠ごと残る")
    func disabledKindIsFolded() {
        var settings = ClipboardFormatSettings.standard
        settings.automaticKinds.remove(.markdown)
        let asked = question("# 見出し", settings: settings)
        #expect(asked.options.map(\.kind) == [.plainText])
        #expect(asked.others.map(\.kind) == [.markdown, .org, .html, .latex, .csv])
        #expect(asked.others.first?.evidence == [.headings(1)])
    }

    @Test("毎回聞く設定では、自動で開けた形式を最初に選ぶ")
    func alwaysAskPrefersWhatWouldOpen() {
        let text = "# Title\n\nText.\n\n## Section\n\n- one\n- two\n- three\n"
        let detection = ClipboardFormatDetection(
            byReplacingActionOf: ClipboardFormatDetector.detect(text), with: .ask(preferred: .markdown))
        let asked = ClipboardQuestion(text: text, detection: detection, settings: .init(mode: .alwaysAsk))
        #expect(asked.preferred == .markdown)
        #expect(asked.options.first?.kind == .markdown)
    }

    @Test("判定器が URL を勧めてもテキストを最初に選び、URL は選択肢に出さない")
    func urlIsNotOffered() {
        let text = "https://example.com/page"
        let asked = ClipboardQuestion(
            text: text, detection: ClipboardFormatDetector.detect(text, hints: .init(hasMatchingURL: true)),
            settings: .standard)
        #expect(asked.preferred == .plainText)
        #expect(!(asked.options + asked.others).contains { $0.kind == .url })
        #expect((asked.options + asked.others).count == 6)
    }

    @Test("見本は先頭の空行を飛ばした最初の 5 行で、長い行と続きは切ったと分かる")
    func preview() {
        let long = String(repeating: "あ", count: 100)
        let asked = question("\n\n  \nfirst\tcell\nsecond  \n\(long)\nfourth\nfifth\nsixth\n")
        #expect(asked.preview.count == 5)
        #expect(asked.preview[0] == "first    cell")
        #expect(asked.preview[1] == "second")
        #expect(asked.preview[2] == String(repeating: "あ", count: 71) + "…")
        #expect(asked.preview[4] == "fifth")
        #expect(asked.isPreviewCut)
    }

    @Test("短い文の見本は全部を見せ、切っていない")
    func shortPreview() {
        let asked = question("# 見出し\n本文\n\n")
        #expect(asked.preview == ["# 見出し", "本文"])
        #expect(!asked.isPreviewCut)
    }
}

extension ClipboardFormatDetection {
    /// The detector's own result with another action, as a newer detector answers for Always Ask.
    fileprivate init(byReplacingActionOf detection: ClipboardFormatDetection, with action: Action) {
        self = detection
        self.action = action
    }
}
