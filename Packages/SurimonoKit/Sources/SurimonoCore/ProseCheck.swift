import Foundation

/// The thresholds of the writing check. They are provisional: starting points to be tried against real manuscripts,
/// not boundaries any study fixed. Nothing else in the check holds a number of this kind.
public struct ProseLimits: Equatable, Sendable {
    /// A Japanese sentence of this many characters or more is long.
    public var longJapaneseSentence = 80
    /// An English sentence of this many words or more is long.
    public var longEnglishSentence = 40
    /// A word repeated this many times or more, close together in one paragraph, is reported.
    public var repetitionCount = 3
    /// "Close together" in Japanese text: from the first of the words to the end of the last, in characters.
    public var japaneseRepetitionWindow = 200
    /// "Close together" in English text: from the first of the words to the last, in words.
    public var englishRepetitionWindow = 80
    /// A word found in at least this share of the document's paragraphs, and in at least
    /// `subjectMinimumParagraphs` of them, is what the document is about, and its repetition is not reported.
    public var subjectParagraphShare = 0.2
    public var subjectMinimumParagraphs = 4
    /// A sentence is Japanese when at least this share of its letters are kana or kanji; otherwise its Latin
    /// letters make it English. Low, because a kana says as much as a Latin word.
    public var japaneseLetterShare = 0.15
    /// A document is mixed when the smaller of its two languages has at least this share of the sentences.
    public var mixedSentenceShare = 0.1

    public static let provisional = ProseLimits()

    public init() {}
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
    case characters, words
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
        /// In characters for Japanese sentences and in words for English ones; the two are never averaged.
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
        /// The prose is mostly in a language the check has no rules for. The code is a BCP 47 tag ("fr", "zh-Hans").
        case unsupportedLanguage(String)
    }

    case analysed(ProseReport)
    case notAnalysed(Reason)
}

/// The writing check: facts about a document's prose and the places worth a second look. It gives no score and no
/// grade, changes nothing, and reads nothing but the text it is given.
public enum ProseCheck {
    /// Analyses a document off the caller's actor. Cancelling the calling task stops the analysis at the next
    /// paragraph (and within a long paragraph, at the tokenizer's next batch of words).
    public static func analysis(
        of text: String, format: DocumentFormat, tokenizer: any ProseTokenizer = SystemProseTokenizer(),
        limits: ProseLimits = .provisional
    ) async throws -> ProseAnalysis {
        let task = Task.detached(priority: .userInitiated) {
            try analyse(text, format: format, tokenizer: tokenizer, limits: limits)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Analyses a document on the calling thread.
    /// - Throws: `CancellationError` when the task it runs in is cancelled.
    public static func analyse(
        _ text: String, format: DocumentFormat, tokenizer: any ProseTokenizer = SystemProseTokenizer(),
        limits: ProseLimits = .provisional
    ) throws -> ProseAnalysis {
        guard let source = ProseSource(text: text, format: format) else { return .notAnalysed(.unsupportedFormat) }
        return try analyse(source, tokenizer: tokenizer, limits: limits)
    }

    public static func analyse(
        _ source: ProseSource, tokenizer: any ProseTokenizer = SystemProseTokenizer(),
        limits: ProseLimits = .provisional
    ) throws -> ProseAnalysis {
        var paragraphs: [Paragraph] = []
        paragraphs.reserveCapacity(source.paragraphs.count)
        for paragraph in source.paragraphs {
            try Task.checkCancellation()
            paragraphs.append(Paragraph(paragraph, lineBreaksEnd: source.kind == .plainText, limits: limits))
        }
        let language: ProseLanguage
        switch ProseLanguageChoice.choose(for: &paragraphs, limits: limits) {
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
        for paragraph in paragraphs where !paragraph.sentences.isEmpty {
            try Task.checkCancellation()
            readParagraphs += 1
            for sentence in paragraph.sentences {
                let isLong: Bool
                switch sentence.language {
                case .japanese:
                    japaneseLengths.append(sentence.length)
                    scripts.kanji += sentence.scripts.kanji
                    scripts.hiragana += sentence.scripts.hiragana
                    scripts.katakana += sentence.scripts.katakana
                    scripts.latin += sentence.scripts.latin
                    isLong = sentence.length >= limits.longJapaneseSentence
                case .english:
                    englishLengths.append(sentence.length)
                    isLong = sentence.length >= limits.longEnglishSentence
                }
                guard isLong else { continue }
                findings.append(
                    ProseFinding(
                        kind: .longSentence(
                            length: sentence.length, unit: sentence.language == .japanese ? .characters : .words),
                        occurrences: [paragraph.occurrence(sentence.range)]))
            }
            let isEnglish = paragraph.isEnglish
            let tokens = tokenizer.tokens(in: paragraph.source.text, tagsEnglish: isEnglish).filter {
                $0.range.lowerBound >= 0 && $0.range.upperBound <= paragraph.units.count && !$0.range.isEmpty
            }
            try Task.checkCancellation()
            findings += ProseDuplicates.findings(in: paragraph, tokens: tokens)
            let found = ProseRepetition.groups(in: paragraph, tokens: tokens, isEnglish: isEnglish, limits: limits)
            repetitions += found.groups
            for key in found.keys { paragraphsHolding[key, default: 0] += 1 }
        }
        // A word in a fifth of the paragraphs is the document's subject: an article about PDF says PDF.
        let subjectFloor = max(
            limits.subjectMinimumParagraphs, Int((Double(readParagraphs) * limits.subjectParagraphShare).rounded(.up)))
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

    // MARK: - Working forms

    enum SentenceLanguage {
        case japanese, english
    }

    struct Sentence {
        var range: Range<Int>
        var language: SentenceLanguage
        /// Characters for a Japanese sentence, words for an English one.
        var length: Int
        var scripts = ProseScriptCounts()
    }

    /// A paragraph as the rules read it: its UTF-16 units and its sentences. A sentence without letters (a number, a
    /// placeholder alone) is no sentence, and one in a script the check has no rules for is counted apart.
    struct Paragraph {
        let source: ProseParagraph
        let units: [UInt16]
        var sentences: [Sentence] = []
        var otherSentences = 0
        var otherLetters = 0

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
                let japanese = counts.kanji + counts.hiragana + counts.katakana
                guard japanese + counts.latin + other > 0 else { continue }
                if other > japanese, other > counts.latin {
                    otherSentences += 1
                    otherLetters += other
                } else if Double(japanese) >= Double(japanese + counts.latin) * limits.japaneseLetterShare {
                    sentences.append(
                        Sentence(range: range, language: .japanese, length: characters(range), scripts: counts))
                } else {
                    sentences.append(Sentence(range: range, language: .english, length: words(range)))
                }
            }
        }

        var isEnglish: Bool {
            sentences.count { $0.language == .english } * 2 > sentences.count
        }

        func occurrence(_ range: Range<Int>) -> ProseOccurrence {
            ProseOccurrence(paragraph: source.index, sourceRange: source.sourceRange(of: range), textRange: range)
        }

        func string(_ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }

        /// The characters a reader counts: no white space, and nothing for inline code, a formula or a URL.
        private func characters(_ range: Range<Int>) -> Int {
            string(range).count { !$0.isWhitespace && $0 != ProseParagraph.placeholder }
        }

        /// Words as they are counted by hand: stretches between white space that hold a letter or a digit.
        private func words(_ range: Range<Int>) -> Int {
            var count = 0
            var holdsWord = false
            for unit in units[range] {
                if ProseScript.isWhitespace(unit) {
                    if holdsWord { count += 1 }
                    holdsWord = false
                } else if !holdsWord, let scalar = Unicode.Scalar(unit) {
                    holdsWord = scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                }
            }
            return count + (holdsWord ? 1 : 0)
        }
    }
}
