import Foundation

/// The thresholds of the writing check. They are provisional: starting points to be tried against real manuscripts,
/// not boundaries any study fixed. Nothing else in the check holds a number of this kind. They are not open to
/// callers: a screen that lets a reader change one validates what it takes first.
struct ProseLimits: Equatable, Sendable {
    /// A Japanese sentence of this many characters or more is long.
    var longJapaneseSentence = 80
    /// An English sentence of this many words or more is long.
    var longEnglishSentence = 40
    /// A word repeated this many times or more, close together in one paragraph, is reported.
    var repetitionCount = 3
    /// "Close together" in Japanese sentences: from the first of the words to the end of the last, in characters.
    var japaneseRepetitionWindow = 200
    /// "Close together" in English sentences: from the first of the words to the last, in words.
    var englishRepetitionWindow = 80
    /// A word found in at least this share of the document's paragraphs, and in at least
    /// `subjectMinimumParagraphs` of them, is what the document is about, and its repetition is not reported.
    var subjectParagraphShare = 0.2
    var subjectMinimumParagraphs = 4
    /// A sentence with kana is Japanese when at least this share of its letters are kana or kanji. Low, because a
    /// kana says as much as a Latin word.
    var japaneseLetterShare = 0.15
    /// How sure the recognizer must be of a sentence's language for it to count as decided.
    var recognizerConfidence = 0.6
    /// A document is mixed when the smaller of its two languages has at least this share of the sentences.
    var mixedSentenceShare = 0.1

    static let provisional = ProseLimits()

    /// The number of paragraphs a word must stand in to be the document's subject. A share that is no number
    /// (NaN, infinite) leaves only the minimum.
    func subjectFloor(paragraphs: Int) -> Int {
        let share = Double(paragraphs) * subjectParagraphShare
        guard share.isFinite, share < Double(Int.max / 2) else { return max(1, subjectMinimumParagraphs) }
        return max(1, subjectMinimumParagraphs, Int(share.rounded(.up)))
    }
}

/// The language the check read a document's prose as. It is decided from the prose, never from the interface.
public enum ProseLanguage: Equatable, Sendable {
    case japanese, english
    /// Japanese and English sentences side by side.
    case mixed
}

/// A place in the document that a finding points at.
public struct ProseOccurrence: Hashable, Sendable {
    /// The index of the paragraph in `ProseReport.paragraphs`.
    public let paragraph: Int
    /// The place in the decoded source, in UTF-16 code units. It is one stretch of the source and takes in any
    /// markup between its first and last character.
    public let sourceRange: Range<Int>
    /// The same place in the paragraph's `text` (the words as printed, without markup), in UTF-16 code units.
    public let textRange: Range<Int>
}

public enum ProseLengthUnit: Equatable, Sendable {
    /// Characters as a reader counts them (grapheme clusters), without white space and without what stands for
    /// inline code, a formula, a URL or an image.
    case characters
    /// Runs of letters and digits with their combining marks. An apostrophe, a hyphen or a full stop between
    /// letters or digits joins them (`don't`, `state-of-the-art`, `e.g`). An em dash separates them.
    case words
}

/// One thing worth a second look. A finding states a fact about the text; it is not an error and carries no weight.
public struct ProseFinding: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case longSentence(length: Int, unit: ProseLengthUnit)
        /// The same word twice or more in a row, as a slip of the hand leaves it.
        case adjacentDuplicate(word: String)
        /// The same word several times close together in one paragraph.
        case repetition(word: String)
    }

    public let kind: Kind
    /// Where it is, in the document's order. A long sentence and a duplicate have one place (the sentence; the run
    /// of repeated words); a repetition lists every place the word stands in the group.
    public let occurrences: [ProseOccurrence]
}

/// How many of the characters of the Japanese sentences are of each script. Numbers only: no share is better.
public struct ProseScriptCounts: Equatable, Sendable {
    public var kanji = 0
    public var hiragana = 0
    public var katakana = 0
    public var latin = 0

    public var total: Int { kanji + hiragana + katakana + latin }

    /// A count as a share of the four together, from 0 to 1 (0 when there are none).
    public func share(_ count: Int) -> Double { total == 0 ? 0 : Double(count) / Double(total) }
}

public struct ProseFacts: Equatable, Sendable {
    public struct Sentences: Equatable, Sendable {
        public let count: Int
        /// In characters for Japanese sentences and in words for English ones (`ProseLengthUnit`); the two are
        /// never averaged.
        public let medianLength: Double
        public let longCount: Int
    }

    /// The Japanese sentences, nil when there are none.
    public let japanese: Sentences?
    /// The English sentences, nil when there are none.
    public let english: Sentences?
    /// The scripts of the Japanese sentences, nil when there are none.
    public let scripts: ProseScriptCounts?

    public var sentenceCount: Int { (japanese?.count ?? 0) + (english?.count ?? 0) }
}

public struct ProseReport: Equatable, Sendable {
    public let language: ProseLanguage
    public let facts: ProseFacts
    /// In the document's order. Empty when the prose was read and nothing was found.
    public let findings: [ProseFinding]
    /// The paragraphs the findings point into.
    public let paragraphs: [ProseParagraph]
}

/// What the check came to. "Not analysed" is a different answer from an analysis that found nothing, and a caller
/// must not show the one as the other.
public enum ProseAnalysis: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The format's prose is not read (anything but Markdown and plain text).
        case unsupportedFormat
        /// There is no running text: an empty document, or one of code, tables and headings only.
        case noProse
        /// There is too little text to tell its language (a word or two), and nothing around it that settles it.
        case undeterminedLanguage
        /// The prose is mostly in a language the check has no rules for. The code is a BCP 47 tag ("fr", "zh-Hans",
        /// or "und" for a script whose language was not named); it is never Japanese or English.
        case unsupportedLanguage(String)
    }

    case analysed(ProseReport)
    case notAnalysed(Reason)
}

/// The writing check: facts about a document's prose and the places worth a second look. It gives no score and no
/// grade, changes nothing, and reads nothing but the text it is given.
public enum ProseCheck {
    /// Analyses a document off the caller's actor.
    ///
    /// Cancelling the calling task ends the analysis with `CancellationError` at its next check: before the text is
    /// read, between the lines and blocks while it is read, between paragraphs, between the steps of one paragraph
    /// and every few thousand words inside them, and once more before the answer is returned. A single call into
    /// the Markdown parser or the system's tokenizer is not interrupted (the tokenizer is asked to stop every few
    /// hundred words).
    public static func analysis(of text: String, format: DocumentFormat) async throws -> ProseAnalysis {
        try await analysis(
            of: text, format: format, tokenizer: SystemProseTokenizer(), recognizer: SystemProseLanguageRecognizer())
    }

    static func analysis(
        of text: String, format: DocumentFormat, tokenizer: any ProseTokenizer,
        recognizer: any ProseLanguageRecognizer, limits: ProseLimits = .provisional
    ) async throws -> ProseAnalysis {
        let task = Task.detached(priority: .userInitiated) {
            try analyse(text, format: format, tokenizer: tokenizer, recognizer: recognizer, limits: limits)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Analyses a document on the calling thread.
    /// - Throws: `CancellationError` when the task it runs in is cancelled.
    static func analyse(
        _ text: String, format: DocumentFormat, tokenizer: any ProseTokenizer = SystemProseTokenizer(),
        recognizer: any ProseLanguageRecognizer = SystemProseLanguageRecognizer(),
        limits: ProseLimits = .provisional
    ) throws -> ProseAnalysis {
        try Task.checkCancellation()
        guard let source = try ProseSource.read(text, format: format) else { return .notAnalysed(.unsupportedFormat) }
        let analysis = try analyse(source, tokenizer: tokenizer, recognizer: recognizer, limits: limits)
        try Task.checkCancellation()
        return analysis
    }

    static func analyse(
        _ source: ProseSource, tokenizer: any ProseTokenizer, recognizer: any ProseLanguageRecognizer,
        limits: ProseLimits
    ) throws -> ProseAnalysis {
        var paragraphs: [ProseParagraphReading] = []
        paragraphs.reserveCapacity(source.paragraphs.count)
        for paragraph in source.paragraphs {
            try Task.checkCancellation()
            paragraphs.append(
                ProseParagraphReading(paragraph, lineBreaksEnd: source.kind == .plainText, limits: limits))
        }
        let language: ProseLanguage
        switch try ProseLanguageChoice.choose(for: &paragraphs, recognizer: recognizer, limits: limits) {
        case .language(let chosen): language = chosen
        case .notAnalysed(let reason): return .notAnalysed(reason)
        }
        var findings: [ProseFinding] = []
        var japaneseLengths: [Int] = []
        var englishLengths: [Int] = []
        var scripts = ProseScriptCounts()
        var repetitions: [ProseRepetition.Group] = []
        var paragraphsHolding: [String: Int] = [:]
        var readParagraphs = 0
        for index in paragraphs.indices where paragraphs[index].hasAcceptedSentences {
            try Task.checkCancellation()
            paragraphs[index].measure()
            let paragraph = paragraphs[index]
            readParagraphs += 1
            for sentence in paragraph.sentences {
                let length = paragraph.length(of: sentence)
                let isLong: Bool
                switch sentence.language {
                case .japanese:
                    japaneseLengths.append(length)
                    scripts.kanji += sentence.scripts.kanji
                    scripts.hiragana += sentence.scripts.hiragana
                    scripts.katakana += sentence.scripts.katakana
                    scripts.latin += sentence.scripts.latin
                    isLong = length >= limits.longJapaneseSentence
                case .english:
                    englishLengths.append(length)
                    isLong = length >= limits.longEnglishSentence
                default: continue
                }
                guard isLong else { continue }
                findings.append(
                    ProseFinding(
                        kind: .longSentence(
                            length: length, unit: sentence.language == .japanese ? .characters : .words),
                        occurrences: [paragraph.occurrence(sentence.range)]))
            }
            let english = paragraph.sentences.filter { $0.language == .english }.map(\.range)
            let tokens = tokenizer.tokens(in: paragraph.source.text, english: english)
            try Task.checkCancellation()
            let words = try paragraph.words(from: tokens)
            findings += try ProseDuplicates.findings(in: paragraph, words: words)
            let found = try ProseRepetition.groups(in: paragraph, words: words, limits: limits)
            repetitions += found.groups
            for key in found.keys { paragraphsHolding[key, default: 0] += 1 }
        }
        try Task.checkCancellation()
        // A word in a fifth of the paragraphs is the document's subject: an article about PDF says PDF. That holds
        // for a word repeated in every paragraph too, which is why it is not reported anywhere.
        let subjectFloor = limits.subjectFloor(paragraphs: readParagraphs)
        for group in repetitions where (paragraphsHolding[group.key] ?? 0) < subjectFloor {
            findings.append(ProseFinding(kind: .repetition(word: group.word), occurrences: group.occurrences))
        }
        findings.sort { first, second in
            guard let a = first.occurrences.first, let b = second.occurrences.first else { return false }
            return (a.paragraph, a.textRange.lowerBound, a.textRange.upperBound)
                < (b.paragraph, b.textRange.lowerBound, b.textRange.upperBound)
        }
        func facts(_ lengths: [Int], long: Int) -> ProseFacts.Sentences? {
            guard !lengths.isEmpty else { return nil }
            let sorted = lengths.sorted()
            let middle = sorted.count / 2
            let median =
                sorted.count % 2 == 1 ? Double(sorted[middle]) : Double(sorted[middle - 1] + sorted[middle]) / 2
            return .init(count: sorted.count, medianLength: median, longCount: sorted.count { $0 >= long })
        }
        return .analysed(
            ProseReport(
                language: language,
                facts: ProseFacts(
                    japanese: facts(japaneseLengths, long: limits.longJapaneseSentence),
                    english: facts(englishLengths, long: limits.longEnglishSentence),
                    scripts: japaneseLengths.isEmpty ? nil : scripts),
                findings: findings, paragraphs: source.paragraphs))
    }
}

/// What a sentence is written in, as far as the check has got with it.
enum ProseSentenceLanguage: Equatable {
    case japanese, english
    /// A language without rules here, by its code.
    case other(String)
    /// Too little to tell. `isIdeographic` is a sentence of kanji without kana, which can become Japanese but
    /// never English.
    case undetermined(isIdeographic: Bool)
    /// Left out of the analysis: its numbers are not counted and no finding points into it.
    case excluded
}

struct ProseSentence {
    var range: Range<Int>
    var language: ProseSentenceLanguage
    var scripts = ProseScriptCounts()
    /// What the recognizer is to be asked about the sentence, if anything.
    var question: Question?

    enum Question {
        /// Latin letters: which language?
        case latin
        /// Mostly Latin letters with some kana: English that quotes Japanese, or Japanese full of English terms?
        case latinWithKana
        /// Kanji without kana: Chinese, or Japanese without a particle?
        case ideographic
    }
}

/// A word of an accepted sentence: the token, the sentence it is in, and that sentence's language.
struct ProseWord {
    var token: ProseToken
    var sentence: Int
    var isEnglish: Bool
}

/// A paragraph as the rules read it: its UTF-16 units and its sentences. A stretch without letters (a number, a
/// placeholder alone) is no sentence.
struct ProseParagraphReading {
    let source: ProseParagraph
    let units: [UInt16]
    var sentences: [ProseSentence] = []
    /// Characters before each UTF-16 unit, as `ProseLengthUnit.characters` counts them. Made by `measure()`.
    private var charactersBefore: [Int32] = []
    /// Words that start before each UTF-16 unit, as `ProseLengthUnit.words` counts them. Made by `measure()`.
    private var wordsBefore: [Int32] = []

    init(_ source: ProseParagraph, lineBreaksEnd: Bool, limits: ProseLimits) {
        self.source = source
        units = Array(source.text.utf16)
        for range in ProseSentences.ranges(in: units, lineBreaksEnd: lineBreaksEnd) {
            var counts = ProseScriptCounts()
            var other = 0
            ProseScript.scalars(units, range) { value, _ in
                switch ProseScript.of(value) {
                case .kanji: counts.kanji += 1
                case .hiragana: counts.hiragana += 1
                case .katakana: counts.katakana += 1
                case .latin: counts.latin += 1
                case .otherLetter: other += 1
                case .none: break
                }
            }
            let kana = counts.hiragana + counts.katakana
            let japanese = kana + counts.kanji
            guard japanese + counts.latin + other > 0 else { continue }
            var sentence = ProseSentence(range: range, language: .undetermined(isIdeographic: false), scripts: counts)
            let isMostlyJapanese = Double(japanese) >= Double(japanese + counts.latin) * limits.japaneseLetterShare
            if other > japanese, other > counts.latin {
                sentence.language = .other("und")
            } else if kana > 0 {
                // Kana is written in no other language.
                if isMostlyJapanese { sentence.language = .japanese } else { sentence.question = .latinWithKana }
            } else if counts.kanji > 0, isMostlyJapanese {
                sentence.language = .undetermined(isIdeographic: true)
                if counts.kanji >= Self.lettersToAsk { sentence.question = .ideographic }
            } else if counts.latin >= Self.lettersToAsk {
                sentence.question = .latin
            }
            sentences.append(sentence)
        }
    }

    /// Fewer letters than this say too little for the recognizer to be asked at all.
    private static let lettersToAsk = 4

    var hasAcceptedSentences: Bool {
        sentences.contains { $0.language == .japanese || $0.language == .english }
    }

    func occurrence(_ range: Range<Int>) -> ProseOccurrence {
        ProseOccurrence(paragraph: source.index, sourceRange: source.sourceRange(of: range), textRange: range)
    }

    func string(_ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }

    /// Counts the paragraph's characters and words once, so that a sentence's length and the distance between two
    /// words are read off the same count.
    mutating func measure() {
        guard charactersBefore.isEmpty else { return }
        charactersBefore = [Int32](repeating: 0, count: units.count + 1)
        var offset = 0
        var count: Int32 = 0
        for character in source.text {
            let width = character.utf16.count
            let counts = !character.isWhitespace && character != ProseParagraph.placeholder
            for unit in 0..<width where offset + unit + 1 <= units.count {
                charactersBefore[offset + unit + 1] = count + (counts ? 1 : 0)
            }
            if counts { count += 1 }
            offset += width
        }
        wordsBefore = [Int32](repeating: 0, count: units.count + 1)
        var words: Int32 = 0
        var isInWord = false
        ProseScript.scalars(units, units.indices) { value, index in
            var isWord = value <= 0xFFFF && ProseScript.isWordUnit(UInt16(value))
            if !isWord, isInWord {
                if ProseScript.isCombiningMark(value) {
                    isWord = true
                } else if [0x27, 0x2019, 0x2D, 0x2E].contains(value), index + 1 < units.count {
                    isWord = ProseScript.isWordUnit(units[index + 1])
                }
            }
            if isWord, !isInWord { words += 1 }
            isInWord = isWord
            wordsBefore[index + 1] = words
            if value > 0xFFFF { wordsBefore[index + 2] = words }
        }
    }

    /// From the start of `first` to the end of `last`: characters between Japanese words, words between English.
    func distance(from first: Range<Int>, to last: Range<Int>, inWords: Bool) -> Int {
        let counts = inWords ? wordsBefore : charactersBefore
        guard first.lowerBound < counts.count, last.upperBound < counts.count else { return .max }
        // A word that began before `first` and runs into it is not counted before it, so it is counted here.
        return Int(counts[last.upperBound] - counts[first.lowerBound])
    }

    func length(of sentence: ProseSentence) -> Int {
        distance(from: sentence.range, to: sentence.range, inWords: sentence.language == .english)
    }

    /// The tokens that lie inside an accepted sentence, each with its sentence. A token outside one (in a sentence
    /// of another language, or across two sentences) is dropped here, so no rule can see it.
    func words(from tokens: [ProseToken]) throws -> [ProseWord] {
        var words: [ProseWord] = []
        var sentence = 0
        for (index, token) in tokens.enumerated() {
            if index % 2048 == 2047 { try Task.checkCancellation() }
            guard token.range.lowerBound >= 0, token.range.upperBound <= units.count, !token.range.isEmpty else {
                continue
            }
            while sentence < sentences.count, sentences[sentence].range.upperBound <= token.range.lowerBound {
                sentence += 1
            }
            guard sentence < sentences.count else { break }
            let found = sentences[sentence]
            guard found.range.lowerBound <= token.range.lowerBound, token.range.upperBound <= found.range.upperBound
            else { continue }
            guard found.language == .japanese || found.language == .english else { continue }
            words.append(ProseWord(token: token, sentence: sentence, isEnglish: found.language == .english))
        }
        return words
    }
}
