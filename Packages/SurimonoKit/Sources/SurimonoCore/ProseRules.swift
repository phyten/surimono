import Foundation

/// Decides what language a document's prose is in, from the prose itself.
enum ProseLanguageChoice {
    enum Choice {
        case language(ProseLanguage)
        case notAnalysed(ProseAnalysis.Reason)
    }

    /// The document's language, or why it is not analysed. Sentences are sorted by their script first; what the
    /// kana-and-kanji sentences and the Latin sentences are written in is then asked of `DocumentLanguage`, which
    /// tells Japanese from Chinese and English from the other Latin languages (`NLLanguageRecognizer`). The larger
    /// group decides; a smaller group in another language (a French quotation in a Japanese text) is taken out of
    /// `paragraphs` and not analysed.
    static func choose(for paragraphs: inout [ProseCheck.Paragraph], limits: ProseLimits) -> Choice {
        func count(_ language: ProseCheck.SentenceLanguage) -> Int {
            paragraphs.reduce(0) { $0 + $1.sentences.count { $0.language == language } }
        }
        var japanese = count(.japanese)
        var english = count(.english)
        let other = paragraphs.reduce(0) { $0 + $1.otherSentences }
        guard japanese + english + other > 0 else { return .notAnalysed(.noProse) }
        if other > japanese + english {
            let sample = paragraphs.prefix(60).map { String($0.source.text.prefix(200)) }.joined(separator: "\n")
            let code = code(of: sample)
            return .notAnalysed(.unsupportedLanguage(["ja", "en"].contains(primary(code)) ? "und" : code))
        }
        func written(_ language: ProseCheck.SentenceLanguage, total: Int) -> String {
            // A spread of the sentences, so that a long document is judged by more than its opening.
            let step = max(1, total / 60)
            var seen = 0
            var sample = ""
            for paragraph in paragraphs {
                for sentence in paragraph.sentences where sentence.language == language {
                    defer { seen += 1 }
                    guard seen % step == 0, sample.utf16.count < 6000 else { continue }
                    sample += paragraph.string(sentence.range.prefix(160)) + "\n"
                }
            }
            return code(of: sample)
        }
        func remove(_ language: ProseCheck.SentenceLanguage) {
            for index in paragraphs.indices { paragraphs[index].sentences.removeAll { $0.language == language } }
        }
        let japaneseCode = japanese > 0 ? written(.japanese, total: japanese) : "ja"
        let englishCode = english > 0 ? written(.english, total: english) : "en"
        if primary(japaneseCode) != "ja" {
            guard japanese < english else { return .notAnalysed(.unsupportedLanguage(japaneseCode)) }
            remove(.japanese)
            japanese = 0
        }
        if primary(englishCode) != "en" {
            guard english <= japanese, japanese > 0 else { return .notAnalysed(.unsupportedLanguage(englishCode)) }
            remove(.english)
            english = 0
        }
        let smaller = Double(min(japanese, english))
        if smaller > 0, smaller >= Double(japanese + english) * limits.mixedSentenceShare { return .language(.mixed) }
        return .language(japanese >= english ? .japanese : .english)
    }

    private static func primary(_ code: String) -> String {
        String(code.split(separator: "-").first ?? "").lowercased()
    }

    /// `DocumentLanguage` reads HTML, so what would read as a tag or an entity is taken out of the sample.
    private static func code(of sample: String) -> String {
        let plain = String(
            String.UnicodeScalarView(
                sample.unicodeScalars.map { ["<", ">", "&", "\u{FFFC}"].contains($0) ? " " : $0 }))
        return DocumentLanguage.detect(html: plain, fallback: "en").code
    }
}

/// What a token is made of, as far as the rules ask.
struct ProseTokenShape {
    var scalars = 0
    var kanji = 0
    var hiragana = 0
    var katakana = 0
    var latin = 0
    /// Digits, apostrophes and hyphens: what a Latin word may hold besides its letters.
    var latinFillers = 0
    var first: UInt32 = 0

    init(_ units: [UInt16], _ range: Range<Int>) {
        ProseScript.scalars(units, range) { value, offset in
            if offset == range.lowerBound { first = value }
            scalars += 1
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

/// The same word twice in a row.
///
/// No stop list applies: the slips worth finding are of the commonest words (`the the`, `をを`). What keeps correct
/// text from being reported is the shape of the word instead:
/// - A Latin word counts when only white space parts the two (case ignored), except the two English words that do
///   stand twice in correct sentences (`had had`, `that that`).
/// - A Japanese word counts when nothing parts the two but a line break, and it is either a single hiragana (a
///   particle typed twice) or a word of two or more characters with kanji or katakana that does not start with a
///   numeral (`設定設定`; not `一つ一つ`). Hiragana words of two or more characters are never reported, so words
///   that are doubled by nature (`ますます`, `いろいろ`, `はいはい`) are safe however the tokenizer cuts them, and
///   `人々` is one word with an iteration mark, not two.
enum ProseDuplicates {
    static func findings(in paragraph: ProseCheck.Paragraph, tokens: [ProseToken]) -> [ProseFinding] {
        var findings: [ProseFinding] = []
        var index = 0
        while index + 1 < tokens.count {
            var last = index
            while last + 1 < tokens.count, isDouble(tokens[last].range, tokens[last + 1].range, in: paragraph) {
                last += 1
            }
            if last > index {
                findings.append(
                    ProseFinding(
                        kind: .adjacentDuplicate(word: paragraph.string(tokens[index].range)),
                        occurrences: [
                            paragraph.occurrence(tokens[index].range.lowerBound..<tokens[last].range.upperBound)
                        ]))
            }
            index = last + 1
        }
        return findings
    }

    private static func isDouble(_ first: Range<Int>, _ second: Range<Int>, in paragraph: ProseCheck.Paragraph) -> Bool
    {
        let units = paragraph.units
        guard first.upperBound <= second.lowerBound else { return false }
        let gap = units[first.upperBound..<second.lowerBound]
        guard gap.allSatisfy(ProseScript.isWhitespace) else { return false }
        let shape = ProseTokenShape(units, first)
        if shape.isLatinWord {
            let word = paragraph.string(first).lowercased()
            return !gap.isEmpty && word == paragraph.string(second).lowercased()
                && !ProseWordTables.English.legitimateDoubles.contains(word)
        }
        guard units[first] == units[second], gap.isEmpty || gap.contains(0x0A) else { return false }
        if shape.scalars == 1 { return shape.hiragana == 1 }
        return shape.kanji + shape.katakana > 0 && !shape.startsWithNumeral
    }
}

/// The same word several times close together in one paragraph.
///
/// Which words are compared:
/// - In an English paragraph, Latin words of three letters or more that the tagger calls a noun, verb, adjective or
///   adverb, by their lemma in lower case (`parsers` and `parser` are one word), minus the English stop list. A word
///   the tokenizer did not tag is not compared: without its class, "the" and "and" would be reported.
/// - Everywhere else, words as written: with kanji and two characters or more, all katakana and three or more, or
///   Latin and three letters or more (case ignored), minus the Japanese stop list.
///   Words of hiragana alone are never compared, which leaves out particles, auxiliaries and most formal nouns
///   without listing them.
enum ProseRepetition {
    struct Group {
        var key: String
        var word: String
        var occurrences: [ProseOccurrence]
    }

    /// The groups of one paragraph, and every word that was compared in it (for the document-wide count that tells
    /// the document's subject words).
    static func groups(
        in paragraph: ProseCheck.Paragraph, tokens: [ProseToken], isEnglish: Bool, limits: ProseLimits
    ) -> (groups: [Group], keys: Set<String>) {
        var places: [String: [Int]] = [:]
        var order: [String] = []
        for (index, token) in tokens.enumerated() {
            guard let key = key(of: token, in: paragraph, isEnglish: isEnglish) else { continue }
            if places[key] == nil { order.append(key) }
            places[key, default: []].append(index)
        }
        let needed = max(2, limits.repetitionCount)
        var groups: [Group] = []
        // Characters before each UTF-16 unit, made only when some word stands often enough to need it.
        var characters: [Int32] = []
        func span(_ first: Int, _ last: Int) -> Int {
            if isEnglish { return last - first + 1 }
            return Int(characters[tokens[last].range.upperBound] - characters[tokens[first].range.lowerBound])
        }
        let window = isEnglish ? limits.englishRepetitionWindow : limits.japaneseRepetitionWindow
        for key in order {
            guard let found = places[key], found.count >= needed else { continue }
            if !isEnglish, characters.isEmpty {
                characters = [Int32](repeating: 0, count: paragraph.units.count + 1)
                for (offset, unit) in paragraph.units.enumerated() {
                    characters[offset + 1] = characters[offset] + ((0xDC00...0xDFFF).contains(unit) ? 0 : 1)
                }
            }
            var start = 0
            while start + needed <= found.count {
                var end = start + needed - 1
                guard span(found[start], found[end]) <= window else {
                    start += 1
                    continue
                }
                // Each further occurrence joins while it and the `needed - 1` before it still fit the window.
                while end + 1 < found.count, span(found[end + 2 - needed], found[end + 1]) <= window { end += 1 }
                groups.append(
                    Group(
                        key: key, word: paragraph.string(tokens[found[start]].range),
                        occurrences: found[start...end].map { paragraph.occurrence(tokens[$0].range) }))
                start = end + 1
            }
        }
        return (groups, Set(order))
    }

    private static func key(of token: ProseToken, in paragraph: ProseCheck.Paragraph, isEnglish: Bool) -> String? {
        let shape = ProseTokenShape(paragraph.units, token.range)
        if shape.isLatinWord {
            guard shape.latin >= 3 else { return nil }
            let surface = paragraph.string(token.range)
            let lowered = surface.lowercased()
            guard !ProseWordTables.English.repetitionStopWords.contains(lowered) else { return nil }
            guard isEnglish else { return lowered }
            guard token.isContentWord == true else { return nil }
            let lemma = (token.lemma ?? surface).lowercased()
            return ProseWordTables.English.repetitionStopWords.contains(lemma) ? nil : lemma
        }
        let isCandidate =
            (shape.kanji > 0 && shape.scalars >= 2) || (shape.katakana == shape.scalars && shape.scalars >= 3)
        guard isCandidate else { return nil }
        let surface = paragraph.string(token.range)
        return ProseWordTables.Japanese.repetitionStopWords.contains(surface) ? nil : surface
    }
}
