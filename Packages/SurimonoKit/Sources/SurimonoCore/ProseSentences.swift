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
}

/// Cuts a paragraph into sentences by its punctuation alone. The system's sentence tokenizer is not used: it ends a
/// sentence after "Dr." and "e.g.", and inside 「…。」, and what it does cannot be fixed by a test.
enum ProseSentences {
    /// The sentences of a paragraph, each without the white space around it, as ranges of UTF-16 units.
    /// - Parameter lineBreaksEnd: In plain text a line of Japanese is as the writer broke it, so a line that does
    ///   not end in a Latin letter, a digit, a comma or a hyphen ends its sentence. Markdown's line breaks are soft.
    static func ranges(in units: [UInt16], lineBreaksEnd: Bool) -> [Range<Int>] {
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
        func unit(_ index: Int) -> UInt16 { index < units.count ? units[index] : 0x0A }
        func isCloser(_ value: UInt16) -> Bool {
            [0x300D, 0x300F, 0xFF09, 0x29, 0x22, 0x27, 0x201D, 0x2019].contains(value)
        }
        var depth = 0
        var opened = 0
        var index = 0
        while index < units.count {
            let value = units[index]
            switch value {
            case 0x300C, 0x300E, 0xFF08, 0x28:  // 「 『 （ (
                if depth == 0 { opened = index }
                depth += 1
            case 0x300D, 0x300F, 0xFF09, 0x29: depth = max(0, depth - 1)
            default: break
            }
            // A bracket that is never closed must not swallow the rest of the paragraph.
            if depth > 0, index - opened > Self.bracketReach { depth = 0 }
            var end: Int?
            switch value {
            case 0x0A where lineBreaksEnd:
                var before = index
                while before > start, ProseScript.isWhitespace(units[before - 1]) { before -= 1 }
                let last = before > start ? units[before - 1] : 0x2E
                let continues =
                    (0x30...0x39).contains(last) || last == 0x2C || last == 0x2D
                    || ProseScript.of(UInt32(last)) == .latin
                if !continues {
                    end = index + 1
                    depth = 0
                }
            case 0x3002, 0xFF0E, 0xFF01, 0xFF1F:  // 。 ． ！ ？
                guard depth == 0 else { break }
                var after = index + 1
                while after < units.count,
                    [0x3002, 0xFF0E, 0xFF01, 0xFF1F, 0x21, 0x3F].contains(units[after]) || isCloser(units[after])
                {
                    after += 1
                }
                end = after
            case 0x21, 0x3F:  // ! ?
                guard depth == 0 else { break }
                var after = index + 1
                while after < units.count, [0x21, 0x3F].contains(units[after]) || isCloser(units[after]) { after += 1 }
                if ProseScript.isWhitespace(unit(after)) || unit(after) > 0x2E7F { end = after }
            case 0x2E where depth == 0:  // .
                var after = index + 1
                while after < units.count, units[after] == 0x2E || isCloser(units[after]) { after += 1 }
                guard ProseScript.isWhitespace(unit(after)) || unit(after) > 0x2E7F else { break }
                var next = after
                while next < units.count, ProseScript.isWhitespace(units[next]) { next += 1 }
                // A lower-case letter after the stop continues the sentence ("e.g. this", "approx. ten").
                if next < units.count, (0x61...0x7A).contains(units[next]) { break }
                var wordStart = index
                while wordStart > start,
                    ProseScript.of(UInt32(units[wordStart - 1])) == .latin || units[wordStart - 1] == 0x2E
                {
                    wordStart -= 1
                }
                let word = String(decoding: units[wordStart..<index], as: UTF16.self)
                // An initial ("J. Smith"), dotted letters ("U.S.") or a listed abbreviation keeps the sentence going.
                let isInitial = word.utf16.count == 1 && (0x41...0x5A).contains(units[wordStart])
                if isInitial || word.contains(".") || ProseWordTables.English.abbreviations.contains(word.lowercased())
                {
                    break
                }
                end = after
            default: break
            }
            if let end {
                close(end)
                index = end
            } else {
                index += 1
            }
        }
        close(units.count)
        return ranges
    }

    /// How far an opening bracket holds a sentence together when nothing closes it.
    private static let bracketReach = 120
}
