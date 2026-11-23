/// The words the writing check treats specially, one table per language. Everything that is a list of words lives
/// here, so that a rule's exceptions can be read and changed in one place.
enum ProseWordTables {
    enum Japanese {
        /// Words that repeat in any text and say nothing about it: formal nouns, demonstratives, light verbs and
        /// conjunctions, in the spellings that pass as candidates (a candidate has kanji, katakana or Latin letters,
        /// so the kana spellings こと, これ, する and また never get this far and are not listed). The system gives
        /// no word classes for Japanese, so a word with a second, full meaning (通り, a street) is not listed.
        static let repetitionStopWords: Set<String> = [
            // formal nouns
            "場合", "以上", "以下", "以外", "以前", "以降", "一方", "今回", "上記", "下記", "前述", "後述", "同様", "自体", "全て",
            "全体", "一部", "一つ", "二つ", "時点", "他方",
            // demonstratives
            "此れ", "其れ", "彼れ", "此の", "其の", "此処", "其処", "何処",
            // light verbs, as the tokenizer cuts them
            "行う", "行い", "行っ", "行わ", "出来る", "出来", "言う", "言い", "言っ", "思う", "思い", "思っ", "有る", "無い", "成る",
            // conjunctions
            "及び", "並び", "又は", "或いは", "但し", "従って", "即ち", "例えば", "更に", "且つ", "故に",
        ]
    }

    enum English {
        /// Content words by their class that still carry little, by lemma and by the class they are stopped in:
        /// "will" and "can" are stopped as verbs and compared as nouns (a will, a can).
        static let repetitionStopVerbs: Set<String> = [
            "be", "have", "do", "make", "get", "go", "take", "give", "put", "let", "say", "use", "need", "want",
            "can", "will", "may", "must", "shall", "should", "would", "could", "might",
        ]
        static let repetitionStopAdverbs: Set<String> = [
            "also", "very", "just", "not", "only", "even", "still", "then", "thus", "however", "therefore", "more",
            "most", "much", "so", "too", "here", "there", "when", "where", "now", "well", "often", "always", "never",
            "again", "first", "second",
        ]
        static let repetitionStopAdjectives: Set<String> = [
            "many", "such", "other", "same", "more", "most", "much", "new", "good", "first", "second",
        ]

        /// Function words of three letters or more. In an English sentence the tagger's classes leave them out; an
        /// English phrase inside a Japanese sentence is not tagged, and these are left out of it by this list.
        static let functionWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "these", "those", "from", "into", "onto", "over", "under",
            "are", "was", "were", "been", "being", "has", "have", "had", "does", "did", "not", "but", "nor", "yet",
            "you", "your", "its", "his", "her", "she", "him", "they", "them", "their", "our", "who", "whom", "whose",
            "which", "what", "when", "where", "why", "how", "all", "any", "each", "some", "such", "than", "then",
            "also", "can", "will", "may", "must", "shall", "should", "would", "could", "might", "about", "after",
            "before", "between", "through", "while", "because", "there", "here",
        ]

        /// Words that stand twice in a row in correct English ("she had had enough", "I know that that is true").
        /// Twice only: three in a row are reported.
        static let legitimateDoubles: Set<String> = ["had", "that"]

        /// Titles: their full stop never ends a sentence.
        static let titles: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr"]

        /// Other abbreviations, without the final stop. Their stop ends a sentence only when a word that often
        /// starts one follows ("in the U.S. She left").
        static let abbreviations: Set<String> = [
            "vs", "cf", "fig", "no", "vol", "inc", "ltd", "co", "approx", "ca", "al", "eq",
            "sec", "ch", "pp",
        ]

        /// Capitalized words that begin a sentence far more often than they follow an abbreviation as a name.
        static let sentenceStarters: Set<String> = [
            "The", "A", "An", "This", "That", "These", "Those", "It", "He", "She", "We", "They", "I", "You", "In",
            "On", "At", "For", "But", "And", "So", "Then", "There", "Here", "When", "If", "However", "After",
            "Before", "Its", "His", "Her", "Our", "Their", "My", "Your",
        ]
    }
}
