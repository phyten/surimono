import Foundation
import NaturalLanguage

/// What kind of word an English token is, as far as the rules ask.
enum ProseWordClass: Equatable, Sendable {
    case noun, verb, adjective, adverb
    /// Everything that carries no content of its own: articles, pronouns, prepositions, conjunctions, numbers.
    case other

    var isContent: Bool { self != .other }
}

/// One word of a paragraph, as a tokenizer cut it.
struct ProseToken: Equatable, Sendable {
    /// The word in the paragraph's text, in UTF-16 code units.
    var range: Range<Int>
    /// The dictionary form of an English word, when the tokenizer was asked for it and knows it.
    var lemma: String?
    /// The class of an English word; nil when the tokenizer did not say.
    var wordClass: ProseWordClass?

    init(range: Range<Int>, lemma: String? = nil, wordClass: ProseWordClass? = nil) {
        self.range = range
        self.lemma = lemma
        self.wordClass = wordClass
    }
}

/// Cuts a paragraph into words. The rules of the writing check are written against this, so that tests can fix the
/// words where the system's own cutting is not what is being tested.
protocol ProseTokenizer: Sendable {
    /// The words of `text` in order, without white space and punctuation. The words inside `english` (the English
    /// sentences of the paragraph, as UTF-16 ranges in order) should carry their lemma and class.
    func tokens(in text: String, english: [Range<Int>]) -> [ProseToken]
}

/// The system's tokenizer (`NLTokenizer`) and, for English sentences, its tagger (`NLTagger`). Both work on the
/// device, and no assets are requested: a word the system cannot tag is left untagged.
struct SystemProseTokenizer: ProseTokenizer {
    func tokens(in text: String, english: [Range<Int>]) -> [ProseToken] {
        let whole = text.startIndex..<text.endIndex
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [ProseToken] = []
        tokenizer.enumerateTokens(in: whole) { range, _ in
            tokens.append(
                ProseToken(range: range.lowerBound.utf16Offset(in: text)..<range.upperBound.utf16Offset(in: text)))
            // A cancelled analysis stops here instead of cutting the rest of a long paragraph.
            return tokens.count % 512 != 0 || !Task.isCancelled
        }
        guard !english.isEmpty, !tokens.isEmpty else { return tokens }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        var tags: [Int: (wordClass: ProseWordClass, lemma: String?)] = [:]
        var seen = 0
        let units = Array(text.utf16)
        // English sentences that follow one another are tagged in one go: the tagger reads a sentence better with
        // its neighbours, and a call a sentence took several times as long.
        var runs: [Range<Int>] = []
        for sentence in english where sentence.lowerBound >= 0 && sentence.upperBound <= units.count {
            if let last = runs.last, last.upperBound <= sentence.lowerBound,
                units[last.upperBound..<sentence.lowerBound].allSatisfy(ProseScript.isWhitespace)
            {
                runs[runs.count - 1] = last.lowerBound..<sentence.upperBound
            } else {
                runs.append(sentence)
            }
        }
        for sentence in runs where !Task.isCancelled {
            let range =
                String.Index(
                    utf16Offset: sentence.lowerBound, in: text)..<String.Index(
                    utf16Offset: sentence.upperBound, in: text)
            tagger.setLanguage(.english, range: range)
            tagger.enumerateTags(
                in: range, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]
            ) { tag, word in
                let wordClass: ProseWordClass
                switch tag {
                case NLTag.noun?: wordClass = .noun
                case NLTag.verb?: wordClass = .verb
                case NLTag.adjective?: wordClass = .adjective
                case NLTag.adverb?: wordClass = .adverb
                default: wordClass = .other
                }
                let lemma = tagger.tag(at: word.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
                tags[word.lowerBound.utf16Offset(in: text)] = (wordClass, lemma)
                seen += 1
                return seen % 512 != 0 || !Task.isCancelled
            }
        }
        for index in tokens.indices {
            guard let tag = tags[tokens[index].range.lowerBound] else { continue }
            tokens[index].wordClass = tag.wordClass
            tokens[index].lemma = tag.lemma
        }
        return tokens
    }
}

/// A language a recognizer read a text as, and how sure it is (0 to 1).
struct ProseRecognizedLanguage: Equatable, Sendable {
    var code: String
    var confidence: Double
}

/// Says what language a sentence is written in. Behind a protocol for the same reason as the tokenizer: the rules
/// for settling a document's language are tested with fixed answers.
protocol ProseLanguageRecognizer: Sendable {
    /// One answer per text, nil where the recognizer has none.
    func languages(of texts: [String]) -> [ProseRecognizedLanguage?]
}

/// `NLLanguageRecognizer`, asked sentence by sentence.
struct SystemProseLanguageRecognizer: ProseLanguageRecognizer {
    func languages(of texts: [String]) -> [ProseRecognizedLanguage?] {
        let recognizer = NLLanguageRecognizer()
        return texts.map { text in
            guard !Task.isCancelled else { return nil }
            recognizer.reset()
            recognizer.processString(text)
            guard let best = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
            return ProseRecognizedLanguage(code: best.key.rawValue, confidence: best.value)
        }
    }
}
