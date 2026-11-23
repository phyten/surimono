import Foundation

/// Decides what language a document's prose is in, from the prose itself.
///
/// Every sentence is decided on its own, never all Latin text or all kanji in one lump:
/// 1. By its script. A sentence with kana is Japanese (kana is written in no other language), unless it is mostly
///    Latin letters. A sentence mostly in another script (Hangul, Cyrillic, …) is in a language without rules here.
/// 2. By the recognizer (`NLLanguageRecognizer`), asked about that one sentence: a Latin sentence (English, or which
///    other language?), a mostly Latin sentence with some kana (English quoting Japanese, or Japanese full of
///    English terms?), and a sentence of kanji without kana (Chinese?). An answer below the confidence limit, and
///    a sentence of fewer than four letters, which is not asked about, leave the sentence undetermined.
///    One shortcut keeps a long English text from costing a question a sentence: the Latin sentences of one
///    paragraph that have no accented letter are first asked about together, and when the answer is surely English
///    they are English. Any other answer, and each of them is asked about on its own. So a sentence in another
///    language is told apart from the English around it when it has an accented letter or stands in a paragraph of
///    its own, and is taken for English when it is written in plain letters inside an English paragraph.
/// 3. An undetermined sentence takes the language of the nearest decided sentence of its paragraph, the one before
///    it first; in a paragraph without one, the language most of the document's decided sentences are in. Kanji
///    without kana never becomes English this way; it is left out instead.
///
/// The document is then judged by its decided sentences. If most are in languages without rules, it is not
/// analysed, and the reason names the commonest of them, which by construction is neither Japanese nor English.
/// If nothing was decided at all (a word or two), the language is undetermined. Otherwise sentences in other
/// languages (a French quotation) are left out, and the document is Japanese, English or mixed.
enum ProseLanguageChoice {
    enum Choice {
        case language(ProseLanguage)
        case notAnalysed(ProseAnalysis.Reason)
    }

    static func choose(
        for paragraphs: inout [ProseParagraphReading], recognizer: any ProseLanguageRecognizer, limits: ProseLimits
    ) throws -> Choice {
        func isSure(_ answer: ProseRecognizedLanguage?) -> Bool {
            answer.map { $0.confidence.isFinite && $0.confidence >= limits.recognizerConfidence } ?? false
        }
        var together: [(paragraph: Int, sentences: [Int])] = []
        var texts: [String] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let plain = paragraph.sentences.indices.filter { number in
                let sentence = paragraph.sentences[number]
                return sentence.question == .latin && !paragraph.units[sentence.range].contains { $0 >= 0x80 }
            }
            guard plain.count >= 2 else { continue }
            var text = ""
            for number in plain where text.utf16.count < 240 {
                text += paragraph.string(paragraph.sentences[number].range.prefix(120)) + " "
            }
            together.append((index, plain))
            texts.append(text.replacingOccurrences(of: String(ProseParagraph.placeholder), with: " "))
        }
        if !texts.isEmpty {
            let answers = recognizer.languages(of: texts)
            try Task.checkCancellation()
            for (index, group) in together.enumerated() {
                let answer = index < answers.count ? answers[index] : nil
                guard isSure(answer), DocumentLanguage.primary(answer?.code ?? "") == "en" else { continue }
                for number in group.sentences {
                    paragraphs[group.paragraph].sentences[number].language = .english
                    paragraphs[group.paragraph].sentences[number].question = nil
                }
            }
        }
        var asked: [(paragraph: Int, sentence: Int)] = []
        texts = []
        for (index, paragraph) in paragraphs.enumerated() {
            for (number, sentence) in paragraph.sentences.enumerated() where sentence.question != nil {
                asked.append((index, number))
                // The start of a sentence is enough to tell its language, and keeps a huge one cheap.
                texts.append(
                    paragraph.string(sentence.range.prefix(200))
                        .replacingOccurrences(of: String(ProseParagraph.placeholder), with: " "))
            }
        }
        if !texts.isEmpty {
            let answers = recognizer.languages(of: texts)
            try Task.checkCancellation()
            for (index, place) in asked.enumerated() {
                let answer = index < answers.count ? answers[index] : nil
                let isSure = isSure(answer)
                let primary = DocumentLanguage.primary(answer?.code ?? "")
                var sentence = paragraphs[place.paragraph].sentences[place.sentence]
                switch sentence.question {
                case .latin?:
                    if isSure, primary == "en" {
                        sentence.language = .english
                    } else if isSure, primary != "ja", let code = answer?.code {
                        sentence.language = .other(code)
                    }
                case .latinWithKana?:
                    if isSure, let code = answer?.code, primary != "ja" {
                        sentence.language = primary == "en" ? .english : .other(code)
                    } else {
                        sentence.language = .japanese
                    }
                case .ideographic?:
                    if isSure, primary == "ja" {
                        sentence.language = .japanese
                    } else if isSure, primary == "zh", let code = answer?.code {
                        sentence.language = .other(code)
                    }
                case nil: break
                }
                paragraphs[place.paragraph].sentences[place.sentence] = sentence
            }
        }
        var japanese = 0
        var english = 0
        var others: [String: Int] = [:]
        var undetermined = 0
        for paragraph in paragraphs {
            for sentence in paragraph.sentences {
                switch sentence.language {
                case .japanese: japanese += 1
                case .english: english += 1
                case .other(let code): others[code, default: 0] += 1
                case .undetermined: undetermined += 1
                case .excluded: break
                }
            }
        }
        let other = others.values.reduce(0, +)
        guard japanese + english + other + undetermined > 0 else { return .notAnalysed(.noProse) }
        guard japanese + english + other > 0 else { return .notAnalysed(.undeterminedLanguage) }
        if other > japanese + english {
            let commonest = others.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? "und"
            return .notAnalysed(.unsupportedLanguage(named(commonest, in: paragraphs)))
        }
        let majority: ProseSentenceLanguage = japanese >= english ? .japanese : .english
        for index in paragraphs.indices {
            var sentences = paragraphs[index].sentences
            guard sentences.contains(where: { if case .undetermined = $0.language { true } else { false } }) else {
                continue
            }
            func isDecided(_ sentence: ProseSentence) -> Bool {
                if case .undetermined = sentence.language { return false }
                return sentence.language != .excluded
            }
            // The nearest decided sentence after each one, found once from the end.
            var following = [Int?](repeating: nil, count: sentences.count)
            var next: Int?
            for number in sentences.indices.reversed() {
                following[number] = next
                if isDecided(sentences[number]) { next = number }
            }
            var previous: Int?
            for number in sentences.indices {
                guard case .undetermined(let isIdeographic) = sentences[number].language else {
                    if isDecided(sentences[number]) { previous = number }
                    continue
                }
                let nearest: Int?
                if let previous, let next = following[number] {
                    nearest = number - previous <= next - number ? previous : next
                } else {
                    nearest = previous ?? following[number]
                }
                let settled = nearest.map { sentences[$0].language } ?? majority
                switch settled {
                case .japanese: sentences[number].language = .japanese
                case .english: sentences[number].language = isIdeographic ? .excluded : .english
                default: sentences[number].language = .excluded
                }
            }
            paragraphs[index].sentences = sentences
        }
        japanese = 0
        english = 0
        for paragraph in paragraphs {
            japanese += paragraph.sentences.count { $0.language == .japanese }
            english += paragraph.sentences.count { $0.language == .english }
        }
        guard japanese + english > 0 else { return .notAnalysed(.undeterminedLanguage) }
        let smaller = Double(min(japanese, english))
        if smaller > 0, smaller >= Double(japanese + english) * limits.mixedSentenceShare { return .language(.mixed) }
        return .language(japanese >= english ? .japanese : .english)
    }

    /// The code to report for the commonest unsupported language. A sentence in another script was not given a
    /// code when it was sorted; `DocumentLanguage` names its language now. Never Japanese or English.
    private static func named(_ code: String, in paragraphs: [ProseParagraphReading]) -> String {
        var code = code
        if code == "und" {
            var sample = ""
            for paragraph in paragraphs where sample.utf16.count < 4000 {
                for sentence in paragraph.sentences where sentence.language == .other("und") {
                    sample += paragraph.string(sentence.range.prefix(200)) + "\n"
                }
            }
            let plain = String(
                String.UnicodeScalarView(
                    sample.unicodeScalars.map { ["<", ">", "&", "\u{FFFC}"].contains($0) ? " " : $0 }))
            code = DocumentLanguage.detect(html: plain, fallback: "und").code
        }
        return ["ja", "en"].contains(DocumentLanguage.primary(code)) ? "und" : code
    }
}

/// What a token is made of, as far as the rules ask.
struct ProseTokenShape {
    var scalars = 0
    var kanji = 0
    var hiragana = 0
    var katakana = 0
    var latin = 0
    /// Following combining marks, digits, apostrophes and hyphens: what a Latin word may hold besides its letters.
    var latinFillers = 0
    var first: UInt32 = 0

    init(_ units: [UInt16], _ range: Range<Int>) {
        ProseScript.scalars(units, range) { value, offset in
            if offset == range.lowerBound { first = value }
            scalars += 1
            if latin > 0, ProseScript.isCombiningMark(value) {
                latinFillers += 1
                return
            }
            switch ProseScript.of(value) {
            case .kanji: kanji += 1
            case .hiragana: hiragana += 1
            case .katakana: katakana += 1
            case .latin: latin += 1
            default:
                if (0x30...0x39).contains(value) || [0x27, 0x2019, 0x2D].contains(value) { latinFillers += 1 }
            }
        }
    }

    var isLatinWord: Bool { latin > 0 && latin + latinFillers == scalars }

    var startsWithNumeral: Bool {
        (0x30...0x39).contains(first) || (0xFF10...0xFF19).contains(first)
            || "一二三四五六七八九十百千万億兆〇".unicodeScalars.contains { $0.value == first }
    }
}

/// The same word twice or more in a row, within one accepted sentence.
///
/// No stop list applies: the slips worth finding are of the commonest words (`the the`, `をを`). What keeps correct
/// text from being reported is the shape of the word instead:
/// - A Latin word counts when only white space parts the two (case ignored). The two English words that do stand
///   twice in correct sentences (`had had`, `that that`) are passed when they stand exactly twice; three in a row
///   are reported. `is is` ("what it is is…") is reported: the tagger gives both the same class, so nothing tells
///   the correct pair from the slip.
/// - A Japanese word counts when nothing parts the two but a line break, and it is either a single hiragana (a
///   particle typed twice) or a word of two or more characters with kanji or katakana that does not start with a
///   numeral (`設定設定`; not `一つ一つ`). Hiragana words of two or more characters are never reported, so words
///   that are doubled by nature (`ますます`, `いろいろ`, `はいはい`) are safe however the tokenizer cuts them, and
///   `人々` is one word with an iteration mark, not two.
///
/// Whatever stands for inline code, a formula, a URL or an image is not white space, so two words on either side
/// of it are never a pair, and neither are words in different sentences.
enum ProseDuplicates {
    static func findings(in paragraph: ProseParagraphReading, words: [ProseWord]) throws -> [ProseFinding] {
        var findings: [ProseFinding] = []
        var index = 0
        var comparisons = 0
        while index + 1 < words.count {
            var last = index
            while last + 1 < words.count {
                comparisons += 1
                if comparisons.isMultiple(of: 2048) { try Task.checkCancellation() }
                guard words[last].sentence == words[last + 1].sentence,
                    isDouble(words[last].token.range, words[last + 1].token.range, in: paragraph)
                else { break }
                last += 1
            }
            defer { index = last + 1 }
            guard last > index else { continue }
            let word = paragraph.string(words[index].token.range)
            if last == index + 1, ProseWordTables.English.legitimateDoubles.contains(word.lowercased()) { continue }
            findings.append(
                ProseFinding(
                    kind: .adjacentDuplicate(word: word),
                    occurrences: [
                        paragraph.occurrence(words[index].token.range.lowerBound..<words[last].token.range.upperBound)
                    ]))
        }
        return findings
    }

    private static func isDouble(_ first: Range<Int>, _ second: Range<Int>, in paragraph: ProseParagraphReading)
        -> Bool
    {
        let units = paragraph.units
        guard first.upperBound <= second.lowerBound else { return false }
        let gap = units[first.upperBound..<second.lowerBound]
        guard gap.allSatisfy(ProseScript.isWhitespace) else { return false }
        let shape = ProseTokenShape(units, first)
        if shape.isLatinWord {
            return !gap.isEmpty && paragraph.string(first).lowercased() == paragraph.string(second).lowercased()
        }
        guard units[first] == units[second], gap.isEmpty || gap.contains(0x0A) else { return false }
        if shape.scalars == 1 { return shape.hiragana == 1 }
        return shape.kanji + shape.katakana > 0 && !shape.startsWithNumeral
    }
}

/// The same word several times close together in one paragraph.
///
/// Which words are compared, by the language of the sentence each stands in:
/// - In an English sentence, Latin words of three letters or more that the tagger calls a noun, verb, adjective or
///   adverb, by their lemma in lower case (`parsers` and `parser` are one word). The stop lists are by class: `will`
///   and `can` are left out as verbs and compared as nouns. A word the tokenizer did not tag is not compared:
///   without its class, "the" and "and" would be reported.
/// - In a Japanese sentence, words as written: with kanji and two characters or more, all katakana and three or
///   more, or Latin and three letters or more (case ignored; English function words left out by a list, since the
///   tagger is not asked about a Japanese sentence), minus the Japanese stop list. Words of hiragana alone are never
///   compared, which leaves out particles, auxiliaries and most formal nouns without listing them.
///
/// A group is `repetitionCount` or more occurrences whose first and last are within the window: characters between
/// Japanese words, words between English ones, both counted as sentence lengths are (`ProseLengthUnit`). A further
/// occurrence outside the window starts a new group if enough follow it. A group does not cross a sentence that
/// was left out of the analysis.
///
/// The caller drops the groups of the document's subject words: a word that stands in a fifth of the paragraphs
/// (and in four at least) is what the document is about, and that includes a word repeated in every paragraph.
enum ProseRepetition {
    struct Group {
        var key: String
        var word: String
        var occurrences: [ProseOccurrence]
    }

    /// The groups of one paragraph, and every word that was compared in it (for the document-wide count that tells
    /// the document's subject words).
    static func groups(in paragraph: ProseParagraphReading, words: [ProseWord], limits: ProseLimits) throws
        -> (groups: [Group], keys: Set<String>)
    {
        // Sentences that follow one another without one left out between them share a number.
        var stretches = [Int](repeating: 0, count: paragraph.sentences.count)
        var stretch = 0
        for (index, sentence) in paragraph.sentences.enumerated() {
            if sentence.language == .japanese || sentence.language == .english {
                stretches[index] = stretch
            } else {
                stretch += 1
            }
        }
        var places: [String: [Int]] = [:]
        var order: [String] = []
        for (index, word) in words.enumerated() {
            if index % 2048 == 2047 { try Task.checkCancellation() }
            guard let key = key(of: word, in: paragraph) else { continue }
            if places[key] == nil { order.append(key) }
            places[key, default: []].append(index)
        }
        let needed = max(2, limits.repetitionCount)
        var groups: [Group] = []
        for key in order {
            guard let found = places[key], found.count >= needed else { continue }
            let inWords = key.hasPrefix(englishPrefix)
            let window = inWords ? limits.englishRepetitionWindow : limits.japaneseRepetitionWindow
            var start = 0
            while start + needed <= found.count {
                let first = words[found[start]]
                var end = start
                while end + 1 < found.count, stretches[words[found[end + 1]].sentence] == stretches[first.sentence],
                    paragraph.distance(from: first.token.range, to: words[found[end + 1]].token.range, inWords: inWords)
                        <= window
                {
                    end += 1
                }
                guard end - start + 1 >= needed else {
                    start += 1
                    continue
                }
                groups.append(
                    Group(
                        key: key, word: paragraph.string(first.token.range),
                        occurrences: found[start...end].map { paragraph.occurrence(words[$0].token.range) }))
                start = end + 1
            }
        }
        return (groups, Set(order))
    }

    private static let englishPrefix = "en\u{1F}"
    private static let japanesePrefix = "ja\u{1F}"

    private static func key(of word: ProseWord, in paragraph: ProseParagraphReading) -> String? {
        let shape = ProseTokenShape(paragraph.units, word.token.range)
        if shape.isLatinWord {
            guard shape.latin >= 3 else { return nil }
            let surface = paragraph.string(word.token.range).lowercased()
            guard word.isEnglish else {
                return ProseWordTables.English.functionWords.contains(surface) ? nil : japanesePrefix + surface
            }
            guard let wordClass = word.token.wordClass, wordClass.isContent else { return nil }
            let lemma = (word.token.lemma ?? surface).lowercased()
            let stopped: Set<String>
            switch wordClass {
            case .verb: stopped = ProseWordTables.English.repetitionStopVerbs
            case .adverb: stopped = ProseWordTables.English.repetitionStopAdverbs
            case .adjective: stopped = ProseWordTables.English.repetitionStopAdjectives
            case .noun, .other: stopped = []
            }
            return stopped.contains(lemma) || stopped.contains(surface) ? nil : englishPrefix + lemma
        }
        let isCandidate =
            (shape.kanji > 0 && shape.scalars >= 2) || (shape.katakana == shape.scalars && shape.scalars >= 3)
        guard isCandidate else { return nil }
        let surface = paragraph.string(word.token.range)
        return ProseWordTables.Japanese.repetitionStopWords.contains(surface) ? nil : japanesePrefix + surface
    }
}
