/// The scripts the writing check tells apart, by code point.
enum ProseScript {
    case kanji, hiragana, katakana, latin, otherLetter, none

    static func of(_ value: UInt32) -> ProseScript {
        switch value {
        case 0x3041...0x3096, 0x309D...0x309F: return .hiragana
        // The long vowel mark belongs to the word it lengthens; the middle dot (U+30FB) is punctuation.
        case 0x30A1...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .katakana
        case 0x3005, 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return .kanji
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        default:
            guard value > 0x7F, let scalar = Unicode.Scalar(value), scalar.properties.isAlphabetic else {
                return .none
            }
            return .otherLetter
        }
    }

    /// Calls `body` with each code point of `units[range]` and its offset; half a surrogate pair is U+FFFD.
    static func scalars(_ units: [UInt16], _ range: Range<Int>, _ body: (_ value: UInt32, _ offset: Int) -> Void) {
        var index = range.lowerBound
        while index < range.upperBound {
            let unit = units[index]
            if (0xD800...0xDBFF).contains(unit), index + 1 < range.upperBound,
                (0xDC00...0xDFFF).contains(units[index + 1])
            {
                body(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00), index)
                index += 2
            } else {
                body((0xD800...0xDFFF).contains(unit) ? 0xFFFD : UInt32(unit), index)
                index += 1
            }
        }
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x3000 || unit == 0xA0
    }

    static func isCombiningMark(_ value: UInt32) -> Bool {
        guard value >= 0x300, let scalar = Unicode.Scalar(value) else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// A letter or digit of the kind English words are made of.
    static func isWordUnit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || of(UInt32(unit)) == .latin
    }
}

/// Cuts a paragraph into sentences by its punctuation alone. The system's sentence tokenizer is not used: it ends a
/// sentence after "Dr." and "e.g.", and inside 「…。」, and what it does cannot be fixed by a test.
///
/// A run of end marks (`.`, `!`, `?`, `。`, `．`, `！`, `？`, `…`, `‥`, in any mixture) is read once, together with
/// the closing brackets and quotation marks after it, and the scan goes on after them, so the work is linear in the
/// paragraph whatever it holds. Whether the run ends a sentence:
/// - Inside a bracket or quotation that is closed later in the paragraph it does not. When the run is followed by
///   that closing mark, it does if the paragraph ends there or another quotation opens (`「行く。」「待って。」`),
///   and it does not when the sentence goes on (`「行く。」と言った。`).
/// - A full-width mark ends a sentence; `!` and `?` do before white space or a Japanese character, unless they
///   close a quotation that a lower-case word follows (`"Stop!" he cried.`).
/// - An ellipsis does before white space when a capital, a Japanese character or an opening bracket follows.
/// - A single full stop does before white space or a Japanese character, unless a lower-case letter follows, or the
///   word before it is a title (`Dr.`), or it is another abbreviation, an initial or dotted letters (`etc.`, `J.`,
///   `U.S.`) that is not followed by a word that usually starts a sentence.
enum ProseSentences {
    /// The sentences of a paragraph, each without the white space around it, as ranges of UTF-16 units.
    /// - Parameter lineBreaksEnd: In plain text a line of Japanese is as the writer broke it, so a line that does
    ///   not end in a Latin letter, a digit, a comma or a hyphen ends its sentence. Markdown's line breaks are soft.
    static func ranges(in units: [UInt16], lineBreaksEnd: Bool) -> [Range<Int>] {
        let count = units.count
        var ranges: [Range<Int>] = []
        var start = 0
        func close(_ end: Int) {
            var lower = start
            var upper = end
            while lower < upper, ProseScript.isWhitespace(units[lower]) { lower += 1 }
            while upper > lower, ProseScript.isWhitespace(units[upper - 1]) { upper -= 1 }
            if lower < upper { ranges.append(lower..<upper) }
            start = end
        }
        // Only a bracket with its partner counts: one that is never closed must not swallow the paragraph, and one
        // that is closed holds its sentence together however long it is.
        var paired = [Bool](repeating: false, count: count)
        var open: [(kind: UInt16, index: Int)] = []
        for index in 0..<count {
            let unit = units[index]
            if let closer = Self.closer(of: unit) {
                open.append((closer, index))
            } else if Self.isClosingBracket(unit), let last = open.last, last.kind == unit {
                open.removeLast()
                paired[last.index] = true
                paired[index] = true
            }
        }
        var depth = 0
        var index = 0
        while index < count {
            let unit = units[index]
            if paired[index] {
                depth += Self.closer(of: unit) != nil ? 1 : -1
                index += 1
                continue
            }
            if lineBreaksEnd, unit == 0x0A || unit == 0x0D {
                var before = index
                while before > start, index - before < 64, ProseScript.isWhitespace(units[before - 1]) { before -= 1 }
                let last: UInt16 = before > start ? units[before - 1] : 0x2E
                let end = unit == 0x0D && index + 1 < count && units[index + 1] == 0x0A ? index + 2 : index + 1
                if !(ProseScript.isWordUnit(last) || last == 0x2C || last == 0x2D) { close(end) }
                index = end
                continue
            }
            guard Self.isEndMark(unit) else {
                index += 1
                continue
            }
            var isWide = false
            var isExclaimed = false
            var dots = 0
            var marksEnd = index
            while marksEnd < count, Self.isEndMark(units[marksEnd]) {
                switch units[marksEnd] {
                case 0x3002, 0xFF0E, 0xFF01, 0xFF1F: isWide = true
                case 0x21, 0x3F: isExclaimed = true
                case 0x2026, 0x2025: dots += 2
                default: dots += 1
                }
                marksEnd += 1
            }
            var after = marksEnd
            var depthAfter = depth
            var closesQuote = false
            while after < count, Self.isClosingBracket(units[after]) || Self.isClosingQuote(units[after]) {
                if paired[after] { depthAfter -= 1 }
                if Self.isClosingQuote(units[after]) { closesQuote = true }
                after += 1
            }
            var next = after
            while next < count, ProseScript.isWhitespace(units[next]) { next += 1 }
            let isLast = next == count
            let hasSpace = next > after
            func isCapital(_ unit: UInt16) -> Bool { (0x41...0x5A).contains(unit) }
            func isEastAsian(_ unit: UInt16) -> Bool { unit >= 0x2E80 }
            func isLower(_ unit: UInt16) -> Bool { (0x61...0x7A).contains(unit) }
            var ends = false
            if depthAfter > 0 {
                ends = false
            } else if depth > 0 {
                ends = isLast || Self.closer(of: units[next]) != nil || (!isWide && hasSpace && isCapital(units[next]))
            } else if isWide {
                ends = true
            } else if isExclaimed {
                // `"Stop!" he cried.` goes on after the quotation.
                ends = isLast || isEastAsian(units[after]) || (hasSpace && !(closesQuote && isLower(units[next])))
            } else if dots >= 2 {
                ends =
                    isLast
                    || (hasSpace
                        && (isCapital(units[next]) || isEastAsian(units[next]) || Self.closer(of: units[next]) != nil
                            || units[next] == 0x22 || units[next] == 0x201C))
            } else if isLast {
                ends = true
            } else if hasSpace || isEastAsian(units[after]) {
                // A lower-case letter after the stop continues the sentence ("e.g. this", "approx. ten").
                ends = !isLower(units[next]) && !Self.abbreviates(units, stop: index, next: next, from: start)
            }
            depth = max(0, depthAfter)
            if ends { close(after) }
            index = after
        }
        close(count)
        return ranges
    }

    /// Whether the full stop at `stop` belongs to an abbreviation that the next word does not end.
    private static func abbreviates(_ units: [UInt16], stop: Int, next: Int, from start: Int) -> Bool {
        var wordStart = stop
        // Far enough for any abbreviation; without the bound, a chain of dotted letters is read again from each dot.
        while wordStart > start, stop - wordStart < 16,
            ProseScript.of(UInt32(units[wordStart - 1])) == .latin || units[wordStart - 1] == 0x2E
        {
            wordStart -= 1
        }
        guard wordStart < stop else { return false }
        let word = String(decoding: units[wordStart..<stop], as: UTF16.self)
        let lowered = word.lowercased()
        if ProseWordTables.English.titles.contains(lowered) { return true }
        let isInitial = word.utf16.count == 1 && (0x41...0x5A).contains(units[wordStart])
        guard isInitial || word.contains(".") || ProseWordTables.English.abbreviations.contains(lowered) else {
            return false
        }
        var wordEnd = next
        while wordEnd < units.count, wordEnd - next < 12, ProseScript.of(UInt32(units[wordEnd])) == .latin {
            wordEnd += 1
        }
        let following = String(decoding: units[next..<wordEnd], as: UTF16.self)
        return !ProseWordTables.English.sentenceStarters.contains(following)
    }

    private static func isEndMark(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x2E, 0x21, 0x3F, 0x3002, 0xFF0E, 0xFF01, 0xFF1F, 0x2026, 0x2025: return true
        default: return false
        }
    }

    /// The closing bracket of an opening one: 「」 『』 （） ().
    private static func closer(of unit: UInt16) -> UInt16? {
        switch unit {
        case 0x300C: return 0x300D
        case 0x300E: return 0x300F
        case 0xFF08: return 0xFF09
        case 0x28: return 0x29
        default: return nil
        }
    }

    private static func isClosingBracket(_ unit: UInt16) -> Bool {
        unit == 0x300D || unit == 0x300F || unit == 0xFF09 || unit == 0x29
    }

    private static func isClosingQuote(_ unit: UInt16) -> Bool {
        unit == 0x22 || unit == 0x27 || unit == 0x201D || unit == 0x2019
    }
}
