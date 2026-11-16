import Testing

@testable import SurimonoCore

/// Settings describe each level by what it does to text a reader can recognize. These are the examples and the
/// invariant behind those sentences: if a sentence stops being true, the sentence changes, not the detector.
struct ClipboardCarefulnessNoteTests {
    /// Headings, sentences and a plain list: an everyday note.
    private static let note = """
        # 会議のメモ

        来週の配布物を決めました。

        ## やること

        - 表紙を直す
        - 本文を刷る
        - 冊子にまとめる

        """

    /// A heading followed by a numbered list of steps, and nothing else.
    private static let steps = """
        # 冊子の作り方

        1. 用紙を選ぶ
        2. 原稿を刷る
        3. 二つに折る
        4. 真ん中をとじる

        """

    private func action(_ text: String, _ level: ClipboardFormatSettings.Carefulness)
        -> ClipboardFormatDetection.Action
    {
        ClipboardFormatDetector.detect(text, settings: .init(carefulness: level)).action
    }

    @Test("控えめは、見出しと文と箇条書きのメモを整形せずに聞くことがある")
    func carefulMayLeaveNotes() {
        #expect(action(Self.note, .careful) == .ask(preferred: .plainText))
    }

    /// Why the careful sentence says "may": `+` items count as lists of their own, and with two headings they are
    /// enough structure for every level.
    @Test("控えめでも、+ の箇条書きのメモは整形することがある")
    func carefulMayStillFormatPlusNotes() {
        let plus = Self.note.replacingOccurrences(of: "- ", with: "+ ")
        #expect(action(plus, .careful) == .open(.markdown))
    }

    @Test("標準は、見出しと文と箇条書きのメモも整形する")
    func standardFormatsNotes() {
        #expect(action(Self.note, .standard) == .open(.markdown))
    }

    @Test("標準は、見出しと番号付きの手順だけなら整形せずに聞く")
    func standardAsksAboutSteps() {
        #expect(action(Self.steps, .standard) == .ask(preferred: .plainText))
    }

    @Test("積極的は、見出しと番号付きの手順だけでも整形する")
    func eagerFormatsSteps() {
        #expect(action(Self.steps, .eager) == .open(.markdown))
    }

    /// Every labelled text, with the hints its collection gives it.
    private static func labelledInputs() throws -> [(id: String, text: String, hints: ClipboardFormatHints)] {
        var inputs: [(id: String, text: String, hints: ClipboardFormatHints)] = []
        for item in try ClipboardFormatCorpusTests.cases() {
            inputs.append((item.id, item.text, .init()))
        }
        for item in try ClipboardFormatReviewTests.cases() {
            inputs.append(
                (item.id, item.text, .init(hasMatchingURL: item.url ?? false, hasTabularData: item.tabular ?? false)))
        }
        return inputs
    }

    /// The labelled texts a level opens as a formatted kind and the next level does not open as the same kind.
    private static func dropped(
        from lower: ClipboardFormatSettings.Carefulness, to higher: ClipboardFormatSettings.Carefulness
    ) throws -> (formatted: Int, dropped: [String]) {
        var formatted = 0
        var dropped: [String] = []
        for input in try labelledInputs() {
            let before = ClipboardFormatDetector.detect(
                input.text, hints: input.hints, settings: .init(carefulness: lower)
            ).action
            guard case .open(let kind) = before, kind != .plainText, kind != .url else { continue }
            formatted += 1
            let after = ClipboardFormatDetector.detect(
                input.text, hints: input.hints, settings: .init(carefulness: higher)
            ).action
            if after != .open(kind) { dropped.append(input.id) }
        }
        return (formatted, dropped)
    }

    /// "Formats less than Standard" in the careful note.
    @Test("ラベル付きの見本 1035 件のすべてで、控えめが整形する文は標準でも同じ形式で整形する")
    func standardKeepsWhatCarefulFormats() throws {
        #expect(try Self.labelledInputs().count == 751 + 284)
        let result = try Self.dropped(from: .careful, to: .standard)
        #expect(result.formatted > 0)
        #expect(result.dropped.isEmpty)
    }

    /// Why the eager note says "may" and claims nothing about Standard: a document that opens with front matter and
    /// has a single heading is formatted by Standard, and Eager asks about it.
    @Test("標準が整形する文を積極的が同じ形式で開かないのは、ラベル付きの見本では front matter の 1 件だけ")
    func eagerDropsOnlyFrontMatter() throws {
        let result = try Self.dropped(from: .standard, to: .eager)
        #expect(result.formatted > 0)
        #expect(result.dropped == ["md-front-matter"])
    }
}
