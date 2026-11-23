import Foundation
import NaturalLanguage

/// One word of a paragraph, as a tokenizer cut it.
public struct ProseToken: Equatable, Sendable {
    /// The word in the paragraph's text, in UTF-16 code units.
    public var range: Range<Int>
    /// The dictionary form of an English word, when the tokenizer was asked for it and knows it.
    public var lemma: String?
    /// Whether an English word is a noun, verb, adjective or adverb; nil when the tokenizer did not say.
    public var isContentWord: Bool?

    public init(range: Range<Int>, lemma: String? = nil, isContentWord: Bool? = nil) {
        self.range = range
        self.lemma = lemma
        self.isContentWord = isContentWord
    }
}

/// Cuts a paragraph into words. The rules of the writing check are written against this, so that tests can fix the
/// words where the system's own cutting is not what is being tested.
public protocol ProseTokenizer: Sendable {
    /// The words of `text` in order, without white space and punctuation. With `tagsEnglish`, the paragraph is
    /// English and each word should carry its lemma and whether it is a content word.
    func tokens(in text: String, tagsEnglish: Bool) -> [ProseToken]
}

/// The system's tokenizer (`NLTokenizer`) and, for English, its tagger (`NLTagger`). Both work on the device, and no
/// assets are requested: a language the system cannot tag is left untagged.
public struct SystemProseTokenizer: ProseTokenizer {
    public init() {}

    public func tokens(in text: String, tagsEnglish: Bool) -> [ProseToken] {
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
        guard tagsEnglish, !tokens.isEmpty else { return tokens }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        tagger.setLanguage(.english, range: whole)
        var tags: [Int: (isContent: Bool, lemma: String?)] = [:]
        var seen = 0
        tagger.enumerateTags(
            in: whole, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let isContent = tag == .noun || tag == .verb || tag == .adjective || tag == .adverb
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            tags[range.lowerBound.utf16Offset(in: text)] = (isContent, lemma)
            seen += 1
            return seen % 512 != 0 || !Task.isCancelled
        }
        for index in tokens.indices {
            guard let tag = tags[tokens[index].range.lowerBound] else { continue }
            tokens[index].isContentWord = tag.isContent
            tokens[index].lemma = tag.lemma
        }
        return tokens
    }
}
