import Foundation
import NaturalLanguage
import Testing

@testable import SurimonoCore

/// Cuts a text at the given words, in order, wherever each next stands. The rules are tested with these fixed words
/// so that a test does not depend on how the system's tokenizer happens to cut Japanese.
struct ListedWords: ProseTokenizer {
    var words: [String]
    /// Lemma and class by lower-case word, given to the words inside English sentences.
    var tags: [String: (lemma: String, wordClass: ProseWordClass)] = [:]

    func tokens(in text: String, english: [Range<Int>]) -> [ProseToken] {
        let whole = text as NSString
        var from = 0
        var tokens: [ProseToken] = []
        for word in words {
            let found = whole.range(of: word, range: NSRange(location: from, length: whole.length - from))
            guard found.location != NSNotFound else { continue }
            from = found.location + found.length
            let isEnglish = english.contains { $0.lowerBound <= found.location && from <= $0.upperBound }
            let tag = isEnglish ? tags[word.lowercased()] : nil
            tokens.append(ProseToken(range: found.location..<from, lemma: tag?.lemma, wordClass: tag?.wordClass))
        }
        return tokens
    }
}

/// Cuts at everything that is not a letter or a digit, as English is cut. In English sentences the listed words
/// are nouns and every other word is a function word.
struct SpacedWords: ProseTokenizer {
    var content: Set<String> = []

    func tokens(in text: String, english: [Range<Int>]) -> [ProseToken] {
        var tokens: [ProseToken] = []
        var start: Int?
        let units = Array(text.utf16)
        func token(_ range: Range<Int>) -> ProseToken {
            guard english.contains(where: { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound })
            else { return ProseToken(range: range) }
            let word = String(decoding: units[range], as: UTF16.self).lowercased()
            return ProseToken(range: range, lemma: word, wordClass: content.contains(word) ? .noun : .other)
        }
        for (index, unit) in units.enumerated() {
            let isWord = Unicode.Scalar(unit).map { $0.properties.isAlphabetic || $0.properties.numericType != nil }
            if isWord == true {
                start = start ?? index
            } else if let from = start {
                tokens.append(token(from..<index))
                start = nil
            }
        }
        if let from = start { tokens.append(token(from..<units.count)) }
        return tokens
    }
}

/// Answers the recognizer's questions from a table: the first entry whose text the sentence holds, or English with
/// full confidence. The rules for settling a document's language are tested with these fixed answers.
struct FixedLanguages: ProseLanguageRecognizer {
    var answers: [(containing: String, code: String, confidence: Double)] = []
    var otherwise = ProseRecognizedLanguage(code: "en", confidence: 1)

    func languages(of texts: [String]) -> [ProseRecognizedLanguage?] {
        texts.map { text in
            guard let answer = answers.first(where: { text.contains($0.containing) }) else { return otherwise }
            return ProseRecognizedLanguage(code: answer.code, confidence: answer.confidence)
        }
    }
}

enum ProseTesting {
    static func analyse(
        _ text: String, format: DocumentFormat = .markdown, tokenizer: any ProseTokenizer = SpacedWords(),
        recognizer: any ProseLanguageRecognizer = FixedLanguages()
    ) throws -> ProseAnalysis {
        try ProseCheck.analyse(text, format: format, tokenizer: tokenizer, recognizer: recognizer)
    }

    static func report(
        _ text: String, format: DocumentFormat = .markdown, tokenizer: any ProseTokenizer = SpacedWords(),
        recognizer: any ProseLanguageRecognizer = FixedLanguages()
    ) throws -> ProseReport {
        guard
            case .analysed(let report) = try analyse(text, format: format, tokenizer: tokenizer, recognizer: recognizer)
        else { throw Missing() }
        return report
    }

    struct Missing: Error {}

    static func slice(_ text: String, _ range: Range<Int>) -> String {
        (text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    /// Each finding as a line a test can read: its kind and the source text it points at.
    static func lines(_ report: ProseReport, in text: String) -> [String] {
        report.findings.map { finding in
            let places = finding.occurrences.map { slice(text, $0.sourceRange) }
            switch finding.kind {
            case .longSentence(let length, let unit):
                return "long \(length)\(unit == .characters ? "字" : "語") @\(finding.occurrences[0].paragraph)"
            case .adjacentDuplicate(let word): return "double \(word): \(places.joined(separator: "|"))"
            case .repetition(let word): return "repeat \(word) ×\(places.count): \(places.joined(separator: "|"))"
            }
        }
    }

    static func repetitions(_ report: ProseReport, in text: String) -> [String] {
        lines(report, in: text).filter { $0.hasPrefix("repeat") }
    }

    static func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures/Prose"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite("文章の点検: 言語")
struct ProseCheckLanguageTests {
    @Test("かなのある文は、認識器に聞かずに日本語として読む")
    func japanese() throws {
        // The recognizer would call everything Korean; a sentence with kana is never asked about.
        let korean = FixedLanguages(otherwise: .init(code: "ko", confidence: 1))
        #expect(try ProseTesting.report("これは日本語の文です。もう一つの文も日本語です。", recognizer: korean).language == .japanese)
    }

    @Test("英語と認識された文は英語として読む")
    func english() throws {
        #expect(try ProseTesting.report("This is a sentence in English. Here is another one.").language == .english)
    }

    @Test("英語の用語が多い日本語の文書は日本語のまま")
    func japaneseWithTerms() throws {
        let report = try ProseTesting.report("Kubernetes の Deployment を設定する。Service と Ingress も kubectl で確かめる。")
        #expect(report.language == .japanese)
        #expect(report.facts.japanese?.count == 2)
        #expect(report.facts.english == nil)
    }

    @Test("日本語の文と英語の文が並ぶ文書は混在として読み、文は別々に数える")
    func mixed() throws {
        let report = try ProseTesting.report(
            "この段落は日本語で書きました。二つ目の文です。\n\nThis paragraph is written in English. It has two sentences.\n")
        #expect(report.language == .mixed)
        #expect(report.facts.japanese?.count == 2)
        #expect(report.facts.english?.count == 2)
        #expect(report.facts.sentenceCount == 4)
    }

    @Test("ほとんどが英字でかなが少しある文は、認識器の答えで日本語か英語に決まり、対象外にはならない")
    func mostlyLatinWithKana() throws {
        let text = "InternationalizationConfigurationを使う。"
        let asJapanese = FixedLanguages(answers: [("Internationalization", "ja", 0.9)])
        #expect(try ProseTesting.report(text, recognizer: asJapanese).language == .japanese)
        #expect(try ProseTesting.report(text, recognizer: FixedLanguages()).language == .english)
        let unsure = FixedLanguages(answers: [("Internationalization", "fr", 0.2)])
        #expect(try ProseTesting.report(text, recognizer: unsure).language == .japanese)
    }

    @Test("文ごとに認識するので、英語の文書の中のフランス語の文だけが外れる")
    func sentenceBySentence() throws {
        let text = "This is the first sentence. Ceci est une phrase en français. This is the last sentence."
        let report = try ProseTesting.report(text, recognizer: FixedLanguages(answers: [("Ceci", "fr", 1)]))
        #expect(report.language == .english)
        #expect(report.facts.english?.count == 2)
    }

    @Test("段落の英字の文をまとめて聞いた答えが英語でなければ、文ごとに聞き直す")
    func askedAgainOneByOne() throws {
        let text = "Das ist gut so. This is English text here. And this one is English too."
        let report = try ProseTesting.report(text, recognizer: FixedLanguages(answers: [("Das", "de", 1)]))
        #expect(report.language == .english)
        #expect(report.facts.english?.count == 2)
    }

    @Test(
        "日本語でも英語でもない本文は「点検していない」になり、理由はその言語を名指す",
        arguments: [
            ("Ceci est un document écrit en français. Il contient plusieurs phrases.", "fr"),
            ("这是一份用中文写的文档。它包含了几个句子，没有任何假名。", "zh-Hans"),
            ("이 문서는 한국어로 작성되었습니다. 여러 문장이 들어 있습니다.", "ko"),
        ])
    func otherLanguages(_ text: String, _ code: String) throws {
        let recognizer = FixedLanguages(
            answers: [("Ceci", "fr", 1), ("Il contient", "fr", 1)], otherwise: .init(code: "zh-Hans", confidence: 1))
        #expect(try ProseTesting.analyse(text, recognizer: recognizer) == .notAnalysed(.unsupportedLanguage(code)))
    }

    @Test("認識器が英字の文を日本語と答えても、日本語や英語が対象外の理由になることはない")
    func supportedLanguagesAreNeverTheReason() throws {
        let recognizer = FixedLanguages(otherwise: .init(code: "ja", confidence: 1))
        #expect(
            try ProseTesting.analyse("Plain words in Latin letters only.", recognizer: recognizer)
                == .notAnalysed(.undeterminedLanguage))
    }

    @Test(
        "短すぎて決められない本文は「言語を決められない」になる",
        arguments: ["OK.", "你好。", "Bonjour tout le monde.", "東京都"])
    func undetermined(_ text: String) throws {
        // Fewer than four letters are not asked about; an unsure answer decides nothing.
        let recognizer = FixedLanguages(answers: [("Bonjour", "fr", 0.4)])
        #expect(try ProseTesting.analyse(text, recognizer: recognizer) == .notAnalysed(.undeterminedLanguage))
    }

    @Test("確かな答えのある短いフランス語は、英語にならず対象外になる")
    func shortFrench() throws {
        let recognizer = FixedLanguages(answers: [("Bonjour", "fr", 0.9)])
        #expect(
            try ProseTesting.analyse("Bonjour.", recognizer: recognizer) == .notAnalysed(.unsupportedLanguage("fr")))
    }

    @Test("決められない文は、同じ段落の前の文、なければ後ろの文の言語になる")
    func settledByNeighbours() throws {
        let unsure = FixedLanguages(answers: [("Fine", "en", 0.1)])
        let after = try ProseTesting.report("これは日本語の文です。Fine words.", recognizer: unsure)
        #expect(after.facts.japanese?.count == 2)
        #expect(after.facts.english == nil)
        let before = try ProseTesting.report("OK. This sentence is English. これは日本語の文です。", recognizer: unsure)
        #expect(before.facts.english?.count == 2)
        #expect(before.facts.japanese?.count == 1)
    }

    @Test("決まった文のない段落の決められない文は、文書で多い方の言語になる")
    func settledByDocument() throws {
        let report = try ProseTesting.report("OK.\n\nこれは日本語の文です。二つ目も日本語です。\n")
        #expect(report.language == .japanese)
        #expect(report.facts.japanese?.count == 3)
    }

    @Test("かなのない漢字だけの文は、日本語にはなっても英語にはならない")
    func ideographicNeverEnglish() throws {
        let english = try ProseTesting.report("This sentence is English. So is this one.\n\n東京都\n")
        #expect(english.language == .english)
        #expect(english.facts.sentenceCount == 2)
        let japanese = try ProseTesting.report("これは日本語の文です。\n\n東京都\n")
        #expect(japanese.facts.japanese?.count == 2)
    }

    @Test("本文がない文書は「点検していない」で、指摘のない文書とは別の答えになる")
    func noProse() throws {
        #expect(try ProseTesting.analyse("") == .notAnalysed(.noProse))
        #expect(try ProseTesting.analyse("# 見出しだけ\n\n```\ncode\n```\n") == .notAnalysed(.noProse))
        let clean = try ProseTesting.report("短い文です。")
        #expect(clean.findings.isEmpty)
        #expect(clean.facts.sentenceCount == 1)
    }

    @Test("本文を読まない形式は「点検していない」になる")
    func unsupportedFormat() throws {
        #expect(try ProseTesting.analyse("<p>本文です。</p>", format: .html) == .notAnalysed(.unsupportedFormat))
    }

    @Test("日本語の文書の中のフランス語の引用は数えず、文書は日本語のまま")
    func foreignQuotation() throws {
        let report = try ProseTesting.report(
            "最初の文は日本語です。二つ目の文も日本語です。三つ目の文も日本語です。\n\nCeci est une citation écrite en français.\n",
            recognizer: FixedLanguages(answers: [("Ceci", "fr", 1)]))
        #expect(report.language == .japanese)
        #expect(report.facts.japanese?.count == 3)
        #expect(report.facts.english == nil)
    }
}

@Suite("文章の点検: 文と数字")
struct ProseCheckFactsTests {
    private func sentences(_ text: String, plain: Bool = false) -> [String] {
        let units = Array(text.utf16)
        return ProseSentences.ranges(in: units, lineBreaksEnd: plain).map {
            String(decoding: units[$0], as: UTF16.self)
        }
    }

    @Test(
        "文の区切り",
        arguments: [
            ("彼は「行く。すぐ戻る。」と言った。次の文です。", ["彼は「行く。すぐ戻る。」と言った。", "次の文です。"]),
            ("「行く。」「待って。」", ["「行く。」", "「待って。」"]),
            ("We live in the U.S. She left.", ["We live in the U.S.", "She left."]),
            ("He joined the U.S. Navy in May.", ["He joined the U.S. Navy in May."]),
            (
                "Dr. Smith read it, e.g. the summary, on version 1.2. Then J. Doe signed it!",
                ["Dr. Smith read it, e.g. the summary, on version 1.2.", "Then J. Doe signed it!"]
            ),
            ("Wait… Next.", ["Wait…", "Next."]),
            ("Wait.....really", ["Wait.....really"]),
            ("Wait... Really. Yes", ["Wait...", "Really.", "Yes"]),
            ("そうか…次へ進む。", ["そうか…次へ進む。"]),
            ("本当？！次です。", ["本当？！", "次です。"]),
            ("本当?！次です。", ["本当?！", "次です。"]),
            ("What?now. Really?! Yes.", ["What?now.", "Really?!", "Yes."]),
            ("\"Go.\" she said. \"Stop!\" he cried.", ["\"Go.\" she said.", "\"Stop!\" he cried."]),
            ("(See Fig. 2.) Next one.", ["(See Fig. 2.)", "Next one."]),
            ("終止符のない文", ["終止符のない文"]),
            ("値は 1.2 です。次。", ["値は 1.2 です。", "次。"]),
        ])
    func sentenceBoundaries(_ text: String, _ expected: [String]) {
        #expect(sentences(text) == expected)
    }

    @Test("閉じた長い引用は、長くても中の句点で切らない")
    func longClosedQuotation() {
        let text = "彼は「" + String(repeating: "あ", count: 300) + "。まだ続く。」と言った。終わり。"
        #expect(sentences(text).count == 2)
    }

    @Test("閉じない括弧は文をまとめない")
    func unclosedBracket() {
        #expect(sentences("これは（閉じない括弧の文です。短い文です。次の文です。") == ["これは（閉じない括弧の文です。", "短い文です。", "次の文です。"])
    }

    @Test(
        "プレーンテキストの日本語の行は、CR・CRLF・LF のどれでも文を切る", arguments: ["折る\r開く", "折る\r\n開く", "折る\n開く"])
    func plainLineEndings(_ text: String) {
        #expect(sentences(text, plain: true) == ["折る", "開く"])
    }

    @Test("プレーンテキストの英字の行の折り返しと、Markdown の行の折り返しは文を切らない")
    func softLineBreaks() throws {
        #expect(sentences("This line is\nwrapped by hand", plain: true) == ["This line is\nwrapped by hand"])
        let text = "一行目の文は\n二行目に続く\n\nThis line is\nwrapped by hand\n"
        #expect(try ProseTesting.report(text).facts.japanese?.count == 1)
        let plain = try ProseTesting.report(text, format: .plainText)
        #expect(plain.facts.japanese?.count == 2)
        #expect(plain.facts.english?.count == 1)
    }

    @Test("文の数と長さの中央値を、日本語は字で、英語は語で数える")
    func sentenceFacts() throws {
        let japanese = try ProseTesting.report("あいうえ。あいうえおかきくけ。あいうえおか。")
        #expect(japanese.facts.japanese == .init(count: 3, medianLength: 7, longCount: 0))
        let english = try ProseTesting.report(
            "One two three. One two three four five. One two. One two three four five six.")
        #expect(english.facts.english == .init(count: 4, medianLength: 4, longCount: 0))
    }

    @Test("インラインのコードと空白は文の長さに数えない")
    func lengthLeavesOutCode() throws {
        let report = try ProseTesting.report("設定は `a_very_long_identifier_name` に 書く。")
        #expect(report.facts.japanese?.medianLength == 7)
    }

    @Test("日本語の長さは見た目の字で数え、結合文字は 1 字に含める")
    func graphemes() throws {
        let text = String(repeating: "か\u{3099}", count: 79) + "。"
        let report = try ProseTesting.report(text)
        #expect(report.facts.japanese == .init(count: 1, medianLength: 80, longCount: 1))
    }

    @Test("英語の語は英数字の続きで、ダッシュは語を分け、アポストロフィとハイフンは分けない")
    func words() throws {
        let report = try ProseTesting.report("We don't ship state-of-the-art parsers—ever, e.g. today.")
        #expect(report.facts.english?.medianLength == 8)
    }

    @Test("日本語の文の漢字・ひらがな・カタカナ・英字を数える")
    func scripts() throws {
        let report = try ProseTesting.report("漢字とカタカナと ABC を数える。")
        let scripts = try #require(report.facts.scripts)
        #expect(scripts == ProseScriptCounts(kanji: 3, hiragana: 5, katakana: 4, latin: 3))
        #expect(scripts.share(scripts.kanji) == 0.2)
        #expect(try ProseTesting.report("English only, with enough letters.").facts.scripts == nil)
    }

    @Test("主題の語の段落数は、割合が数でなくても止まらずに最小の数になる")
    func subjectFloor() {
        var limits = ProseLimits()
        #expect(limits.subjectFloor(paragraphs: 40) == 8)
        #expect(limits.subjectFloor(paragraphs: 3) == 4)
        for share in [Double.nan, .infinity, -.infinity, 1e300] {
            limits.subjectParagraphShare = share
            #expect(limits.subjectFloor(paragraphs: 40) == 4)
        }
    }
}

@Suite("文章の点検: 指摘")
struct ProseCheckFindingTests {
    @Test("80 字の日本語の文は長い文で、79 字は違う")
    func longJapanese() throws {
        let long = String(repeating: "あ", count: 79) + "。"
        let short = String(repeating: "あ", count: 78) + "。"
        let text = "# 題\n\n短い文です。\(long)\n\n\(short)\n"
        let report = try ProseTesting.report(text)
        #expect(ProseTesting.lines(report, in: text) == ["long 80字 @0"])
        #expect(report.facts.japanese?.longCount == 1)
        let place = try #require(report.findings.first?.occurrences.first)
        #expect(ProseTesting.slice(text, place.sourceRange) == long)
        #expect(ProseTesting.slice(report.paragraphs[0].text, place.textRange) == long)
    }

    @Test("40 語の英語の文は長い文で、39 語は違う。ダッシュで分かれた語も 1 語ずつ数える")
    func longEnglish() throws {
        let words = Array(repeating: "the sheet folds and", count: 9).joined(separator: " ")
        let text = "\(words) it folds—flat end.\n\n\(words) it folds flat.\n"
        let report = try ProseTesting.report(text)
        #expect(ProseTesting.lines(report, in: text) == ["long 40語 @0"])
        #expect(report.facts.english == .init(count: 2, medianLength: 39.5, longCount: 1))
    }

    @Test("同じ語が続く所を、止め語の表なしで見つける")
    func adjacentDuplicates() throws {
        let english = "Check the the grain and and and fold."
        let inEnglish = ProseTesting.lines(try ProseTesting.report(english), in: english)
        #expect(inEnglish == ["double the: the the", "double and: and and and"])
        let japanese = "設定をを変更して、用紙用紙を保存する。"
        let words = ListedWords(words: ["設定", "を", "を", "変更", "し", "て", "用紙", "用紙", "を", "保存", "する"])
        let inJapanese = ProseTesting.lines(try ProseTesting.report(japanese, tokenizer: words), in: japanese)
        #expect(inJapanese == ["double を: をを", "double 用紙: 用紙用紙"])
    }

    @Test("強調の印をはさんだ重複も見つけ、原文の範囲は印を含む")
    func duplicateAcrossMarkup() throws {
        let text = "設定を**を**変更する。"
        let words = ListedWords(words: ["設定", "を", "を", "変更", "する"])
        #expect(ProseTesting.lines(try ProseTesting.report(text, tokenizer: words), in: text) == ["double を: を**を"])
    }

    @Test(
        "正しい重なりは重複にしない",
        arguments: [
            ("She had had enough of it.", ["She", "had", "had", "enough", "of", "it"]),
            ("I think that that is fine.", ["I", "think", "that", "that", "is", "fine"]),
            // However a tokenizer cuts these, a doubled hiragana word is not a slip.
            ("ますます速くなる。", ["ます", "ます", "速く", "なる"]),
            ("いろいろな方法がある。", ["いろ", "いろ", "な", "方法", "が", "ある"]),
            ("はいはい、わかりました。", ["はい", "はい", "わかり", "まし", "た"]),
            ("人々が集まる。", ["人", "々", "が", "集まる"]),
            ("人々が集まる。", ["人々", "が", "集まる"]),
            ("一つ一つ確かめる。", ["一つ", "一つ", "確かめる"]),
            // The same word on either side of something else is not a pair.
            ("Use the `x` the same way.", ["Use", "the", "the", "same", "way"]),
            ("図は ![the](a.png) the とする。", ["図", "は", "the", "と", "する"]),
            ("終わった。た、という音。", ["終わっ", "た", "た", "という", "音"]),
            ("That is fine. Fine words follow.", ["That", "is", "fine", "Fine", "words", "follow"]),
            ("値は 10 10 と並ぶ。", ["値", "は", "10", "10", "と", "並ぶ"]),
        ])
    func legitimateDoubles(_ text: String, _ words: [String]) throws {
        let report = try ProseTesting.report(text, tokenizer: ListedWords(words: words))
        #expect(ProseTesting.lines(report, in: text) == [])
    }

    @Test("had had had のような 3 つ続きは見つける。is is は見分けられないので、そのまま見つける")
    func runsOfThree() throws {
        let text = "She had had had enough. What it is is unclear."
        #expect(
            ProseTesting.lines(try ProseTesting.report(text), in: text) == [
                "double had: had had had", "double is: is is",
            ])
    }

    @Test("対象外の文の中の重複は見つけない")
    func excludedSentence() throws {
        let text = "日本語です。次です。終わりです。 Это длинное предложение the the."
        let report = try ProseTesting.report(text)
        #expect(report.facts.japanese?.count == 3)
        #expect(ProseTesting.lines(report, in: text) == [])
    }

    @Test("同じ段落の 200 字のうちに 3 回出る語を、1 つの指摘にまとめる")
    func nearbyRepetition() throws {
        let text = "処理を始める前に処理の順を決め、処理が終わったら結果を見る。\n\n次の段落に処理が一度だけ出る。\n"
        let report = try ProseTesting.report(text, tokenizer: ListedWords(words: ["処理", "処理", "処理", "結果"]))
        #expect(ProseTesting.lines(report, in: text) == ["repeat 処理 ×3: 処理|処理|処理"])
        #expect(report.findings[0].occurrences.map(\.sourceRange.lowerBound) == [0, 8, 16])
    }

    @Test("2 回だけの語、200 字より離れた語、段落をまたぐ語は繰り返しにしない")
    func notRepetition() throws {
        let filler = String(repeating: "あいうえおかきくけこ", count: 20)
        let texts = [
            "処理を始めて、処理を終える。",
            "処理を始める。\(filler)処理を続ける。\(filler)処理を終える。",
            "処理を始める。\n\n処理を続ける。\n\n処理を終える。\n",
        ]
        for text in texts {
            let report = try ProseTesting.report(text, tokenizer: ListedWords(words: ["処理", "処理", "処理"]))
            #expect(ProseTesting.repetitions(report, in: text) == [])
        }
    }

    @Test("指摘の最初と最後は窓に収まる。収まらない続きは別の指摘になるか、指摘にならない")
    func groupsFitTheWindow() throws {
        // 99 characters a step: three in a row end 200 characters after the first begins, and a fourth does not.
        let step = "処理" + String(repeating: "あ", count: 96) + "。"
        let text = String(repeating: step, count: 6)
        let report = try ProseTesting.report(text, tokenizer: ListedWords(words: Array(repeating: "処理", count: 6)))
        #expect(
            ProseTesting.repetitions(report, in: text) == ["repeat 処理 ×3: 処理|処理|処理", "repeat 処理 ×3: 処理|処理|処理"])
        let four = String(repeating: step, count: 4)
        let once = try ProseTesting.report(four, tokenizer: ListedWords(words: Array(repeating: "処理", count: 4)))
        #expect(ProseTesting.repetitions(once, in: four) == ["repeat 処理 ×3: 処理|処理|処理"])
    }

    @Test("日本語の距離は見た目の字で測るので、結合文字で書いても同じ判定になる")
    func distanceInGraphemes() throws {
        let filler = String(repeating: "か\u{3099}", count: 50)
        let text = "処理\(filler)処理\(filler)処理。"
        let report = try ProseTesting.report(text, tokenizer: ListedWords(words: ["処理", "処理", "処理"]))
        #expect(ProseTesting.repetitions(report, in: text) == ["repeat 処理 ×3: 処理|処理|処理"])
    }

    @Test("日本語の候補は、漢字を含む 2 字以上・カタカナ 3 字以上・英字 3 字以上の語だけ")
    func japaneseCandidates() throws {
        let text = "こと、こと、こと、紙、紙、紙、ログ、ログ、ログ、サーバー、サーバー、サーバー、API、api、Api、OK、OK、OK、読み込み、読み込み、読み込みを見る。"
        let words = ListedWords(
            words: [
                "こと", "こと", "こと", "紙", "紙", "紙", "ログ", "ログ", "ログ", "サーバー", "サーバー", "サーバー", "API", "api", "Api",
                "OK", "OK", "OK", "読み込み", "読み込み", "読み込み",
            ])
        let report = try ProseTesting.report(text, tokenizer: words)
        #expect(
            ProseTesting.lines(report, in: text) == [
                "repeat サーバー ×3: サーバー|サーバー|サーバー", "repeat API ×3: API|api|Api",
                "repeat 読み込み ×3: 読み込み|読み込み|読み込み",
            ])
    }

    @Test("形式名詞や接続の語は、漢字で書いてあっても繰り返しにしない。道の「通り」は語として比べる")
    func japaneseStopWords() throws {
        let text = "その場合は止める。別の場合は進む。どの場合も記録する。及び、及び、及び。通りを歩き、通りを渡り、通りを見る。"
        let words = ListedWords(words: ["場合", "止める", "場合", "進む", "場合", "記録", "及び", "及び", "及び", "通り", "通り", "通り"])
        #expect(
            ProseTesting.lines(try ProseTesting.report(text, tokenizer: words), in: text) == ["repeat 通り ×3: 通り|通り|通り"])
    }

    @Test("日本語の文の中の英語の機能語は繰り返しにしない")
    func functionWordsInJapanese() throws {
        let text = "the と the と the を並べ、and と and と and も並べ、token と token と token を使う。"
        #expect(
            ProseTesting.lines(try ProseTesting.report(text), in: text) == ["repeat token ×3: token|token|token"])
    }

    @Test("英語は 80 語のうちに 3 回出る内容語を、見出し語でまとめる")
    func englishRepetition() throws {
        let text =
            "The parser reads a file. Two parsers disagree. A parser that fails also stops, and it also logs, and it also waits."
        let words = ListedWords(
            words: [
                "The", "parser", "reads", "a", "file", "Two", "parsers", "disagree", "A", "parser", "that", "fails",
                "also",
                "stops", "and", "it", "also", "logs", "and", "it", "also", "waits",
            ],
            tags: [
                "the": ("the", .other), "parser": ("parser", .noun), "parsers": ("parser", .noun),
                "reads": ("read", .verb), "file": ("file", .noun), "and": ("and", .other), "it": ("it", .other),
                "also": ("also", .adverb),
            ])
        let report = try ProseTesting.report(text, tokenizer: words)
        #expect(ProseTesting.lines(report, in: text) == ["repeat parser ×3: parser|parsers|parser"])
    }

    @Test("止め語は品詞ごとで、will は動詞なら比べず、名詞（遺言）なら比べる")
    func stopWordsByClass() throws {
        let text = "The will names her. A will binds them. Each will differs."
        let words = ["The", "will", "names", "her", "A", "will", "binds", "them", "Each", "will", "differs"]
        let asNoun = ListedWords(words: words, tags: ["will": ("will", .noun)])
        #expect(
            ProseTesting.lines(try ProseTesting.report(text, tokenizer: asNoun), in: text) == [
                "repeat will ×3: will|will|will"
            ])
        let asVerb = ListedWords(words: words, tags: ["will": ("will", .verb)])
        #expect(ProseTesting.lines(try ProseTesting.report(text, tokenizer: asVerb), in: text) == [])
    }

    @Test("日本語の段落の中の英語の文は、英語の規則（品詞と語数の窓）で比べる")
    func englishSentenceInJapaneseParagraph() throws {
        let filler = Array(repeating: "we fold a sheet along the grain and press it flat", count: 4).joined(
            separator: " ")
        let near = "これは日本語の文です。The crease opens, a crease moves, each crease shows."
        let tokenizer = SpacedWords(content: ["crease"])
        #expect(
            ProseTesting.repetitions(try ProseTesting.report(near, tokenizer: tokenizer), in: near)
                == ["repeat crease ×3: crease|crease|crease"])
        // More than 200 characters from the first to the last, which a Japanese sentence would not report, and
        // fewer than 80 words.
        let half = Array(repeating: "we fold a sheet along the grain and press it flat", count: 2).joined(
            separator: " ")
        let wide = "これは日本語の文です。The crease opens and \(half) crease \(half) crease again."
        #expect(
            ProseTesting.repetitions(try ProseTesting.report(wide, tokenizer: tokenizer), in: wide)
                == ["repeat crease ×3: crease|crease|crease"])
        let far = "これは日本語の文です。The crease opens and \(filler) crease \(filler) crease again."
        let report = try ProseTesting.report(far, tokenizer: tokenizer)
        #expect(report.facts.english?.count == 1)
        #expect(ProseTesting.repetitions(report, in: far) == [])
    }

    @Test("繰り返しは、対象外の文をまたがない")
    func excludedSentenceIsABoundary() throws {
        let words = ListedWords(words: ["処理", "処理", "処理"])
        let apart = "処理を見る。処理を直す。Это предложение написано по-русски. 処理を終える。"
        #expect(ProseTesting.repetitions(try ProseTesting.report(apart, tokenizer: words), in: apart) == [])
        let together = "処理を見る。処理を直す。処理を終える。Это предложение написано по-русски."
        #expect(
            ProseTesting.repetitions(try ProseTesting.report(together, tokenizer: words), in: together)
                == ["repeat 処理 ×3: 処理|処理|処理"])
    }

    @Test("文書の 2 割以上、4 つ以上の段落に出る語は文書の主題で、繰り返しにしない")
    func subjectWords() throws {
        let subject = (1...5).map { _ in "用紙を選び、用紙を置き、用紙を確かめる。" }
        let local = "余白を測り、余白を決め、余白を書く。"
        let text = (subject + [local]).joined(separator: "\n\n")
        let words = ListedWords(words: Array(repeating: "用紙", count: 15) + Array(repeating: "余白", count: 3))
        let report = try ProseTesting.report(text, tokenizer: words)
        #expect(ProseTesting.lines(report, in: text) == ["repeat 余白 ×3: 余白|余白|余白"])
    }

    @Test("3 つの段落にしか出ない語は主題にせず、段落ごとに指摘する")
    func notYetSubject() throws {
        let text = (1...3).map { _ in "用紙を選び、用紙を置き、用紙を確かめる。" }.joined(separator: "\n\n")
        let report = try ProseTesting.report(text, tokenizer: ListedWords(words: Array(repeating: "用紙", count: 9)))
        #expect(report.findings.map(\.occurrences.count) == [3, 3, 3])
        #expect(report.findings.map { $0.occurrences[0].paragraph } == [0, 1, 2])
    }

    @Test("指摘は文書の順に並ぶ")
    func order() throws {
        let text = "処理と処理と処理をを見る。\n\nCheck the the grain.\n"
        let words = ListedWords(words: ["処理", "処理", "処理", "を", "を", "見る", "Check", "the", "the", "grain"])
        #expect(
            ProseTesting.lines(try ProseTesting.report(text, tokenizer: words), in: text)
                == ["repeat 処理 ×3: 処理|処理|処理", "double を: をを", "double the: the the"])
    }
}

/// What must hold whatever the system's tokenizer and recognizer do on this machine. The rules themselves are
/// tested above with fixed words and fixed answers.
@Suite("文章の点検: システムの語の区切りと言語の認識")
struct ProseSystemTests {
    @Test(
        "語は順に並び、重ならず、本文の中にあり、文字を含む",
        arguments: [
            "設定をを変更する。ますます人々がいろいろな方法を試す。", "😀 か\u{3099}ぎの設定を見る。API サーバーを再起動する。",
            "The parsers were parsing files quickly, e.g. state-of-the-art ones.", "",
        ])
    func tokenInvariants(_ text: String) {
        let length = text.utf16.count
        let tokens = SystemProseTokenizer().tokens(in: text, english: length > 0 ? [0..<length] : [])
        var end = 0
        for token in tokens {
            #expect(token.range.lowerBound >= end)
            #expect(token.range.lowerBound < token.range.upperBound)
            #expect(token.range.upperBound <= length)
            #expect(!ProseTesting.slice(text, token.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            end = token.range.upperBound
        }
        #expect(tokens.isEmpty == text.isEmpty)
    }

    @Test("英語の品詞と見出し語は、この Mac が付けられるときに付く")
    func englishTags() throws {
        let schemes = NLTagger.availableTagSchemes(for: .word, language: .english)
        let text = "The parsers were parsing files."
        let tokens = SystemProseTokenizer().tokens(in: text, english: [0..<text.utf16.count])
        let word = try #require(tokens.first { ProseTesting.slice(text, $0.range) == "parsers" })
        if schemes.contains(.lexicalClass) { #expect(word.wordClass == .noun) } else { #expect(word.wordClass == nil) }
        if schemes.contains(.lemma) { #expect(word.lemma == "parser") }
        // Outside the English sentences nothing is tagged.
        #expect(
            SystemProseTokenizer().tokens(in: text, english: []).allSatisfy { $0.wordClass == nil && $0.lemma == nil })
    }

    @Test("認識器は文ごとに答えを 1 つずつ返す")
    func recognizerAnswers() {
        let answers = SystemProseLanguageRecognizer().languages(of: [
            "This is a plain sentence written in English.", "", "これは日本語で書いた文です。",
        ])
        #expect(answers.count == 3)
        for answer in answers.compactMap({ $0 }) {
            #expect(answer.confidence >= 0 && answer.confidence <= 1)
            #expect(!answer.code.isEmpty)
        }
    }

    @Test("見本の文書: 指摘は文書の順で、範囲は本文と原文の中にあり、本文の範囲から原文の範囲へ戻れる", arguments: ["japanese", "english", "mixed"])
    func fixtures(_ name: String) throws {
        let text = try ProseTesting.fixture(name)
        guard case .analysed(let report) = try ProseCheck.analyse(text, format: .markdown) else {
            Issue.record("\(name) was not analysed")
            return
        }
        #expect(report.facts.sentenceCount > 0)
        var last = (paragraph: 0, start: 0)
        for finding in report.findings {
            let first = try #require(finding.occurrences.first)
            #expect((first.paragraph, first.textRange.lowerBound) >= last)
            last = (first.paragraph, first.textRange.lowerBound)
            for occurrence in finding.occurrences {
                let paragraph = report.paragraphs[occurrence.paragraph]
                #expect(occurrence.textRange.upperBound <= paragraph.text.utf16.count)
                #expect(occurrence.sourceRange.upperBound <= text.utf16.count)
                #expect(paragraph.sourceRange(of: occurrence.textRange) == occurrence.sourceRange)
                #expect(paragraph.sourceRange.lowerBound <= occurrence.sourceRange.lowerBound)
                #expect(occurrence.sourceRange.upperBound <= paragraph.sourceRange.upperBound)
            }
        }
        // What is not prose is not read, whatever the tokenizer does: the table and the code hold these words.
        if name == "japanese" {
            #expect(!report.paragraphs.contains { $0.text.contains("コードの中") || $0.text.contains("引用の中") })
        }
    }
}

/// A tokenizer that reports when the analysis has reached it and then waits to be cancelled.
private struct WaitingTokenizer: ProseTokenizer {
    let reached: AsyncStream<Void>.Continuation

    func tokens(in text: String, english: [Range<Int>]) -> [ProseToken] {
        reached.yield()
        let deadline = Date().addingTimeInterval(20)
        while !Task.isCancelled, Date() < deadline { usleep(1000) }
        return []
    }
}

@Suite("文章の点検: 大きな文書と取り消し")
struct ProseCheckLargeTests {
    // No time is asserted here (the benchmark records times). The limits only stop a pass that has become
    // quadratic, which at these sizes takes many minutes instead of a second.
    @Test("20 万字の文書も、語が 1 つだけ何万回も出る段落も、終わりまで読める", .timeLimit(.minutes(2)))
    func largeDocuments() throws {
        let paragraph = "紙を半分に折ったあとで、左右の端を中央の線に合わせて折り、開いたときに区画がそろっていることを確かめます。Then check the grain again.\n\n"
        let many = String(repeating: paragraph, count: 200_000 / paragraph.count + 1)
        #expect(try ProseTesting.report(many).facts.sentenceCount == 2 * (200_000 / paragraph.count + 1))
        let single = String(repeating: "処理と処理を処理する。", count: 20_000)
        let words = ListedWords(words: Array(repeating: "処理", count: 60_000))
        let groups = try ProseTesting.report(single, tokenizer: words).findings
        #expect(groups.count > 500)
        #expect(groups.allSatisfy { $0.occurrences.count >= 3 })
    }

    @Test("終わりの印が 20 万個続いても、文の区切りは一度の走査で終わる", .timeLimit(.minutes(1)))
    func runsOfEndMarks() {
        let text =
            "Wait" + String(repeating: ".", count: 200_000) + "really and " + String(repeating: "!", count: 200_000)
            + "x " + String(repeating: "a.", count: 100_000)
        #expect(ProseSentences.ranges(in: Array(text.utf16), lineBreaksEnd: false).count == 1)
    }

    @Test("始まる前に取り消されていれば、空の文書でも CancellationError で終わる")
    func cancelledBeforeStart() async {
        let task = Task {
            await Task.yield()
            return try ProseTesting.analyse("")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("点検が始まってから取り消すと、CancellationError で終わる", .timeLimit(.minutes(1)))
    func cancelledWhileRunning() async {
        let (reached, continuation) = AsyncStream<Void>.makeStream()
        let text = String(repeating: "紙を折って、折り目を確かめます。\n\n", count: 50)
        let task = Task {
            try await ProseCheck.analysis(
                of: text, format: .markdown, tokenizer: WaitingTokenizer(reached: continuation),
                recognizer: FixedLanguages())
        }
        // The analysis is inside the first paragraph's tokenizer now, not before or after its work.
        for await _ in reached { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("非同期の入口は、呼び出したタスクとは別のタスクで同じ答えを返す")
    func asynchronous() async throws {
        let text = "Check the the grain.\n"
        let answer = try await CallerTask.$isCaller.withValue(true) {
            try await ProseCheck.analysis(
                of: text, format: .markdown, tokenizer: CallerTask.Tokenizer(), recognizer: FixedLanguages())
        }
        // A detached task does not inherit the caller's task-local value. Run in the caller's own task, the
        // tokenizer would have seen it and returned no words, and the duplicate would not be found.
        #expect(ProseTesting.lines(try ProseTesting.report(text), in: text) == ["double the: the the"])
        #expect(answer == (try ProseTesting.analyse(text)))
    }
}

private enum CallerTask {
    @TaskLocal static var isCaller = false

    struct Tokenizer: ProseTokenizer {
        func tokens(in text: String, english: [Range<Int>]) -> [ProseToken] {
            CallerTask.isCaller ? [] : SpacedWords().tokens(in: text, english: english)
        }
    }
}
