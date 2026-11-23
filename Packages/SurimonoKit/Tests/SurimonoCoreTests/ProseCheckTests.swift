import Foundation
import Testing

@testable import SurimonoCore

/// Cuts a text at the given words, in order, wherever each next stands. The rules are tested with these fixed words
/// so that a test does not depend on how the system's tokenizer happens to cut Japanese.
struct ListedWords: ProseTokenizer {
    var words: [String]
    var tags: [String: (lemma: String, isContent: Bool)] = [:]

    func tokens(in text: String, tagsEnglish: Bool) -> [ProseToken] {
        let whole = text as NSString
        var from = 0
        var tokens: [ProseToken] = []
        for word in words {
            let found = whole.range(of: word, range: NSRange(location: from, length: whole.length - from))
            guard found.location != NSNotFound else { continue }
            from = found.location + found.length
            let tag = tagsEnglish ? tags[word.lowercased()] : nil
            tokens.append(
                ProseToken(
                    range: found.location..<from, lemma: tag?.lemma, isContentWord: tag.map(\.isContent)))
        }
        return tokens
    }
}

/// Cuts at everything that is not a letter or a digit, as English is cut. Only the listed words are content words.
struct SpacedWords: ProseTokenizer {
    var content: Set<String> = []

    func tokens(in text: String, tagsEnglish: Bool) -> [ProseToken] {
        var tokens: [ProseToken] = []
        var start: Int?
        let units = Array(text.utf16)
        for (index, unit) in units.enumerated() {
            let isWord = Unicode.Scalar(unit).map { $0.properties.isAlphabetic || $0.properties.numericType != nil }
            if isWord == true {
                start = start ?? index
            } else if let from = start {
                tokens.append(token(from..<index, units))
                start = nil
            }
        }
        if let from = start { tokens.append(token(from..<units.count, units)) }
        return tokens
    }

    private func token(_ range: Range<Int>, _ units: [UInt16]) -> ProseToken {
        let word = String(decoding: units[range], as: UTF16.self).lowercased()
        return ProseToken(range: range, lemma: word, isContentWord: content.contains(word))
    }
}

enum ProseTesting {
    static func report(
        _ text: String, format: DocumentFormat = .markdown, tokenizer: any ProseTokenizer = SystemProseTokenizer(),
        limits: ProseLimits = .provisional
    ) throws -> ProseReport {
        guard
            case .analysed(let report) = try ProseCheck.analyse(
                text, format: format, tokenizer: tokenizer, limits: limits)
        else {
            throw Missing()
        }
        return report
    }

    struct Missing: Error {}

    /// Each finding as a line a test can read: its kind and the source text it points at.
    static func lines(_ report: ProseReport, in text: String) -> [String] {
        report.findings.map { finding in
            let places = finding.occurrences.map {
                (text as NSString).substring(
                    with: NSRange(location: $0.sourceRange.lowerBound, length: $0.sourceRange.count))
            }
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

@Suite("文章の点検: 言語と数字")
struct ProseCheckFactsTests {
    @Test("日本語の本文は日本語として読む")
    func japanese() throws {
        #expect(try ProseTesting.report("これは日本語の文です。もう一つの文も日本語です。").language == .japanese)
    }

    @Test("英語の本文は英語として読む")
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

    @Test(
        "日本語でも英語でもない本文は「点検していない」になる",
        arguments: [
            (
                "Ceci est un document écrit en français. Il contient plusieurs phrases assez longues pour être reconnu.",
                "fr"
            ),
            (
                "Dies ist ein Dokument in deutscher Sprache. Es enthält mehrere Sätze, damit die Sprache erkannt wird.",
                "de"
            ),
            ("这是一份用中文写的文档。它包含了几个句子，没有任何假名。我们很高兴你能阅读它吗？", "zh-Hans"),
            ("이 문서는 한국어로 작성되었습니다. 여러 문장이 들어 있습니다.", "ko"),
        ])
    func otherLanguages(_ text: String, _ code: String) throws {
        #expect(try ProseCheck.analyse(text, format: .markdown) == .notAnalysed(.unsupportedLanguage(code)))
    }

    @Test("本文がない文書は「点検していない」で、指摘のない文書とは別の答えになる")
    func noProse() throws {
        #expect(try ProseCheck.analyse("", format: .markdown) == .notAnalysed(.noProse))
        #expect(try ProseCheck.analyse("# 見出しだけ\n\n```\ncode\n```\n", format: .markdown) == .notAnalysed(.noProse))
        let clean = try ProseTesting.report("短い文です。")
        #expect(clean.findings.isEmpty)
        #expect(clean.facts.sentenceCount == 1)
    }

    @Test("本文を読まない形式は「点検していない」になる")
    func unsupportedFormat() throws {
        #expect(try ProseCheck.analyse("<p>本文です。</p>", format: .html) == .notAnalysed(.unsupportedFormat))
    }

    @Test("日本語の文書の中のフランス語の引用は数えず、文書は日本語のまま")
    func foreignQuotation() throws {
        let report = try ProseTesting.report(
            "最初の文は日本語です。二つ目の文も日本語です。三つ目の文も日本語です。\n\nCeci est une citation écrite en français pour le test.\n")
        #expect(report.language == .japanese)
        #expect(report.facts.japanese?.count == 3)
        #expect(report.facts.english == nil)
    }

    @Test("文の数と長さの中央値を、日本語は字で、英語は語で数える")
    func sentenceFacts() throws {
        let japanese = try ProseTesting.report("一二三四。一二三四五六七八九。一二三四五六。")
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

    @Test("日本語の文の漢字・ひらがな・カタカナ・英字を数える")
    func scripts() throws {
        let report = try ProseTesting.report("漢字とカタカナと ABC を数える。")
        let scripts = try #require(report.facts.scripts)
        #expect(scripts == ProseScriptCounts(kanji: 3, hiragana: 5, katakana: 4, latin: 3))
        #expect(scripts.share(scripts.kanji) == 0.2)
        #expect(try ProseTesting.report("English only.").facts.scripts == nil)
    }

    @Test("かぎ括弧の中の句点では文を切らない")
    func quotedStop() throws {
        #expect(try ProseTesting.report("彼は「行く。すぐ戻る。」と言った。次の文です。").facts.japanese?.count == 2)
    }

    @Test("閉じない括弧があっても、段落の残りを 1 文にしない")
    func unclosedBracket() throws {
        let text = "これは（閉じない括弧の文です。" + String(repeating: "短い文が続きます。", count: 30)
        #expect((try ProseTesting.report(text).facts.japanese?.count ?? 0) > 15)
    }

    @Test("英語の略語と頭文字のピリオドでは文を切らない")
    func abbreviations() throws {
        let report = try ProseTesting.report(
            "Dr. Smith read the U.S. report, e.g. the summary, on version 1.2 of the plan. Then J. Doe signed it!")
        #expect(report.facts.english?.count == 2)
    }

    @Test("Markdown の行の折り返しは文を切らず、プレーンテキストの日本語の行は文を切る")
    func lineBreaks() throws {
        let text = "一行目の文は\n二行目に続く\n\nThis line is\nwrapped by hand\n"
        #expect(try ProseTesting.report(text).facts.japanese?.count == 1)
        let plain = try ProseTesting.report(text, format: .plainText)
        #expect(plain.facts.japanese?.count == 2)
        #expect(plain.facts.english?.count == 1)
    }
}

@Suite("文章の点検: 指摘")
struct ProseCheckFindingTests {
    @Test("80 字の日本語の文は長い文で、79 字は違う")
    func longJapanese() throws {
        let long = String(repeating: "あ", count: 79) + "。"
        let short = String(repeating: "あ", count: 78) + "。"
        let text = "# 題\n\n短い文です。\(long)\n\n\(short)\n"
        let report = try ProseTesting.report(text, tokenizer: SpacedWords())
        #expect(ProseTesting.lines(report, in: text) == ["long 80字 @0"])
        #expect(report.facts.japanese?.longCount == 1)
        let place = try #require(report.findings.first?.occurrences.first)
        #expect(
            (text as NSString).substring(
                with: NSRange(location: place.sourceRange.lowerBound, length: place.sourceRange.count)) == long)
        #expect(
            (report.paragraphs[0].text as NSString).substring(
                with: NSRange(location: place.textRange.lowerBound, length: place.textRange.count)) == long)
    }

    @Test("40 語の英語の文は長い文で、39 語は違う")
    func longEnglish() throws {
        let words =
            Array(repeating: "the sheet folds and", count: 10).dropLast().joined(separator: " ") + " the sheet folds"
        let text = "\(words) end.\n\n\(words).\n"
        let report = try ProseTesting.report(text, tokenizer: SpacedWords())
        #expect(ProseTesting.lines(report, in: text) == ["long 40語 @0"])
        #expect(report.facts.english == .init(count: 2, medianLength: 39.5, longCount: 1))
    }

    @Test("同じ語が続く所を、止め語の表なしで見つける")
    func adjacentDuplicates() throws {
        let english = "Check the the grain and and and fold."
        let inEnglish = ProseTesting.lines(try ProseTesting.report(english, tokenizer: SpacedWords()), in: english)
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
            ("It is the `the` keyword.", ["It", "is", "the", "the", "keyword"]),
            ("終わった。た、という音。", ["終わっ", "た", "た", "という", "音"]),
            ("That is fine. Fine words follow.", ["That", "is", "fine", "Fine", "words", "follow"]),
            ("値は 10 10 と並ぶ。", ["値", "は", "10", "10", "と", "並ぶ"]),
        ])
    func legitimateDoubles(_ text: String, _ words: [String]) throws {
        let report = try ProseTesting.report(text, tokenizer: ListedWords(words: words))
        #expect(ProseTesting.lines(report, in: text) == [])
    }

    @Test("同じ段落の 200 字のうちに 3 回出る語を、1 つの指摘にまとめる")
    func nearbyRepetition() throws {
        let text = "処理を始める前に処理の順を決め、処理が終わったら結果を見る。\n\n次の段落に処理が一度だけ出る。\n"
        let words = ListedWords(words: [
            "処理", "を", "始める", "前", "に", "処理", "の", "順", "を", "決め", "処理", "が", "終わっ", "たら", "結果", "を", "見る",
        ])
        let report = try ProseTesting.report(text, tokenizer: words)
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

    @Test("離れた所でまた 3 回続けば、別の指摘になる")
    func separateGroups() throws {
        let filler = String(repeating: "あいうえおかきくけこ", count: 25)
        let text = "処理と処理と処理。\(filler)処理と処理と処理と処理。"
        let report = try ProseTesting.report(text, tokenizer: ListedWords(words: Array(repeating: "処理", count: 7)))
        #expect(
            ProseTesting.repetitions(report, in: text) == ["repeat 処理 ×3: 処理|処理|処理", "repeat 処理 ×4: 処理|処理|処理|処理"])
    }

    @Test("日本語の候補は、漢字を含む 2 字以上・カタカナ 3 字以上・英字 3 字以上の語だけ")
    func japaneseCandidates() throws {
        let text = "こと、こと、こと。紙、紙、紙。ログ、ログ、ログ。サーバー、サーバー、サーバー。API、api、Api。OK、OK、OK。読み込み、読み込み、読み込み。"
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

    @Test("形式名詞や接続の語は、漢字で書いてあっても繰り返しにしない")
    func japaneseStopWords() throws {
        let text = "その場合は止める。別の場合は進む。どの場合も記録する。及び、及び、及び。"
        let words = ListedWords(words: ["場合", "止める", "場合", "進む", "場合", "記録", "及び", "及び", "及び"])
        #expect(ProseTesting.lines(try ProseTesting.report(text, tokenizer: words), in: text) == [])
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
                "the": ("the", false), "parser": ("parser", true), "parsers": ("parser", true), "reads": ("read", true),
                "file": ("file", true), "and": ("and", false), "it": ("it", false), "also": ("also", true),
            ])
        let report = try ProseTesting.report(text, tokenizer: words)
        #expect(ProseTesting.lines(report, in: text) == ["repeat parser ×3: parser|parsers|parser"])
    }

    @Test("英語で 80 語より離れた語は繰り返しにしない")
    func englishWindow() throws {
        let filler = Array(repeating: "we fold a sheet along the grain and press it flat", count: 4).joined(
            separator: " ")
        let text = "The crease opens. \(filler) crease \(filler) crease again."
        let far = try ProseTesting.report(text, tokenizer: SpacedWords(content: ["crease"]))
        #expect(ProseTesting.repetitions(far, in: text) == [])
        let near = "The crease opens, a crease moves, each crease shows."
        #expect(
            ProseTesting.lines(try ProseTesting.report(near, tokenizer: SpacedWords(content: ["crease"])), in: near)
                == ["repeat crease ×3: crease|crease|crease"])
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

@Suite("文章の点検: システムの語の区切り")
struct ProseSystemTokenizerTests {
    private func words(_ text: String) -> [String] {
        SystemProseTokenizer().tokens(in: text, tagsEnglish: false).map {
            (text as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count))
        }
    }

    @Test("日本語の助詞は 1 字ずつの語になり、重ねた助詞は 2 つの語になる")
    func japaneseParticles() {
        #expect(words("設定をを変更する。") == ["設定", "を", "を", "変更", "する"])
    }

    @Test("ますます・人々・いろいろは 1 つの語になる")
    func japaneseDoubledWords() {
        #expect(words("ますます人々がいろいろな方法を試す。") == ["ますます", "人々", "が", "いろいろ", "な", "方法", "を", "試す"])
    }

    @Test("英語は見出し語と品詞が付く")
    func englishTags() {
        let text = "The parsers were parsing files quickly."
        let tokens = SystemProseTokenizer().tokens(in: text, tagsEnglish: true)
        #expect(tokens.map(\.lemma) == ["the", "parser", "be", "parse", "file", "quickly"])
        #expect(tokens.map(\.isContentWord) == [false, true, true, true, true, true])
    }

    @Test("絵文字のあとでも語の範囲は UTF-16 でずれない")
    func utf16Ranges() {
        #expect(
            words("😀 設定を変更する。").prefix(2) == ["設定", "を"] || words("😀 設定を変更する。").dropFirst().prefix(2) == ["設定", "を"])
    }

    @Test("システムの区切りでも、正しい重なりは重複にならない")
    func legitimateDoublesWithSystemWords() throws {
        let text = "はいはい、ますます人々がいろいろ試す。山々と日々を見る。\n\nShe had had it, and I know that that is so.\n"
        #expect(ProseTesting.lines(try ProseTesting.report(text), in: text) == [])
    }

    @Test("システムの区切りで、重ねた助詞と the the が見つかる")
    func slipsWithSystemWords() throws {
        let text = "ここでで止まり、設定をを変える。\n\nCheck the the grain before you fold.\n"
        #expect(
            ProseTesting.lines(try ProseTesting.report(text), in: text)
                == ["double で: でで", "double を: をを", "double the: the the"])
    }

    @Test("日本語の見本: 重ねた助詞・近い繰り返し・長い文を見つけ、コード・表・引用は読まない")
    func japaneseFixture() throws {
        let text = try ProseTesting.fixture("japanese")
        let report = try ProseTesting.report(text)
        #expect(report.language == .japanese)
        #expect(report.facts.japanese?.count == 8)
        #expect(report.facts.japanese?.longCount == 1)
        #expect(
            ProseTesting.lines(report, in: text) == [
                "double を: をを", "repeat 折り目 ×4: 折り目|折り目|折り目|折り目", "long 114字 @3",
            ])
    }

    @Test("英語の見本: the the と crease・fold の繰り返しと長い文を見つけ、had had と that that は見つけない")
    func englishFixture() throws {
        let text = try ProseTesting.fixture("english")
        let report = try ProseTesting.report(text)
        #expect(report.language == .english)
        #expect(report.facts.english?.count == 9)
        #expect(
            ProseTesting.lines(report, in: text) == [
                "double the: the the", "repeat crease ×3: crease|crease|crease", "long 57語 @4",
                "repeat folding ×3: folding|fold|fold",
            ])
    }

    @Test("混在の見本: 文を言語ごとに数え、サーバーの繰り返しを見つける")
    func mixedFixture() throws {
        let text = try ProseTesting.fixture("mixed")
        let report = try ProseTesting.report(text)
        #expect(report.language == .mixed)
        #expect(report.facts.japanese?.count == 4)
        #expect(report.facts.english?.count == 4)
        #expect(ProseTesting.lines(report, in: text) == ["repeat サーバー ×3: サーバー|サーバー|サーバー"])
    }
}

@Suite("文章の点検: 速さと取り消し")
struct ProseCheckPerformanceTests {
    @Test("20 万字でも、語が 1 つだけ何万回も出ても、すぐに終わる", .timeLimit(.minutes(1)))
    func largeDocuments() throws {
        let paragraph = "紙を半分に折ったあとで、左右の端を中央の線に合わせて折り、開いたときに区画がそろっていることを確かめます。Then check the grain again.\n\n"
        let many = String(repeating: paragraph, count: 200_000 / paragraph.count + 1)
        let single = String(repeating: "処理と処理を処理する。", count: 20_000)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            _ = try ProseTesting.report(many)
            let report = try ProseTesting.report(single)
            #expect(report.findings.count == 1)
        }
        // Linear work takes about a second here in a debug build; a quadratic pass over 200,000 characters would
        // take minutes.
        #expect(elapsed < .seconds(15))
    }

    @Test("呼び出したタスクを取り消すと、点検は CancellationError で終わる", .timeLimit(.minutes(1)))
    func cancellation() async {
        let text = String(repeating: "紙を折って、折り目を確かめます。\n\n", count: 100_000)
        let task = Task { try await ProseCheck.analysis(of: text, format: .markdown) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("非同期の入口は同期の入口と同じ答えを返す")
    func asynchronous() async throws {
        let text = "設定をを変更する。\n"
        #expect(
            try await ProseCheck.analysis(of: text, format: .markdown)
                == (try ProseCheck.analyse(text, format: .markdown)))
    }
}
