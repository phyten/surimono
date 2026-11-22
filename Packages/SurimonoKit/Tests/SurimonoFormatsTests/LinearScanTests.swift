import Foundation
import Testing

@testable import SurimonoFormats

/// The scanner replaced a regular expression whose openings without closers rescanned the rest of the line. It must
/// find the same matches, with the same groups, as that expression did.
struct ComputationalInlineScannerTests {
    private static func expected(_ text: String) -> [String] {
        let pattern =
            #/
        (`+)(.*?)\1(?!`)
        | \$\$.*?\$\$ | \$[^$]+\$
        | <[^>]+> | \]\([^)]+\)
        | \{\{<\s*(.*?)\s*>\}\}
        | \^\[([^\]]+)\]
        | \[([^\]]*)\]\{([.\#][^}]+)\}
        | \\@ref\(([\w:.-]+)\)
        | \[(\-?)@([\w:.-]+)\]
        | @([\w:-]+(?:\.[\w:-]+)*)
        /#
        func offsets(_ part: Substring?) -> String {
            guard let part else { return "-" }
            return "\(text.distance(from: text.startIndex, to: part.startIndex))"
                + "..\(text.distance(from: text.startIndex, to: part.endIndex))"
        }
        return text.matches(of: pattern).map { match in
            [match.output.0, match.2, match.3, match.4, match.5, match.6, match.7, match.8, match.9, match.10]
                .map(offsets).joined(separator: " ")
        }
    }

    private static func scanned(_ text: String) -> [String] {
        ComputationalInlineScanner(text).matches().map { match in
            [
                match.range, match.code, match.shortcode, match.footnote, match.spanText, match.spanAttributes,
                match.bookdown, match.crossReferenceMinus, match.crossReference, match.bareReference,
            ].map { $0.map { "\($0.lowerBound)..\($0.upperBound)" } ?? "-" }.joined(separator: " ")
        }
    }

    @Test("行内の記法は、元の正規表現と同じ所を同じように読む")
    func matchesTheExpression() {
        let pieces = [
            "`", "`", "`", "$", "$", "<", ">", "]", "(", ")", "[", "{", "}", "^", "\\", "@", "-", ".", ":", "#", " ",
            "\t", "\n", "\r\n", "a", "9", "_", "é", "e\u{301}", "漢", "・", "😀", "٣", "\u{2028}", "\u{A0}", "ref",
            "@ref(", ">}}", "{{<", "$$", "_\u{200D}", "‿",
        ]
        var state: UInt64 = 20_261_122
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        var mismatches: [String] = []
        for _ in 0..<5_000 {
            let text = (0..<(next() % 40)).map { _ in pieces[next() % pieces.count] }.joined()
            if Self.expected(text) != Self.scanned(text) { mismatches.append(text) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).map(\.debugDescription))")
    }

    @Test("閉じない記号が並ぶ長い行も、時間内に読む", arguments: ["[", "<", "`", "{{<", "$$", "^[", "[x]{."])
    func linearInTheLine(_ opener: String) {
        let text = String(repeating: opener, count: 200_000 / opener.count)
        let start = ContinuousClock.now
        _ = ComputationalInlineScanner(text).matches()
        #expect(ContinuousClock.now - start < .seconds(StackSpace.sanitizerFactor > 1 ? 150 : 15))
    }
}

/// `HTMLScanner` finds where a tag ends from marks left by walks that found none; it must find what a plain forward
/// scan from the same offset finds.
struct HTMLTagEndTests {
    private static func scanned(_ bytes: [UInt8], from start: Int) -> Int? {
        var quote: UInt8?
        for index in start..<bytes.count {
            let byte = bytes[index]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return index + 1
            }
        }
        return nil
    }

    @Test("タグの終わりは、どこから探しても前から順に探したのと同じになる")
    func matchesAForwardScan() {
        let pieces: [UInt8] = Array("<<a\"\"'' >>x".utf8)
        var state: UInt64 = 20_261_122
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        var mismatches = 0
        for _ in 0..<3_000 {
            let bytes = (0..<(next() % 48)).map { _ in pieces[next() % pieces.count] }
            var ends = HTMLScanner.TagEnds(bytes)
            var start = next() % 4
            while start < bytes.count {
                if ends.end(from: start) != Self.scanned(bytes, from: start) { mismatches += 1 }
                start += 1 + next() % 3
            }
        }
        #expect(mismatches == 0)
    }

    @Test("終わらないタグと引用符が並ぶ HTML も、時間に比例して読む", arguments: ["<a ", "<a \"", "<a '", "<a \"'", "<a '\"<b \""])
    func linearInThePage(_ piece: String) {
        let html = String(repeating: piece, count: 200_000 / piece.utf8.count)
        let start = ContinuousClock.now
        _ = HTMLScanner.tokens(html)
        #expect(ContinuousClock.now - start < .seconds(StackSpace.sanitizerFactor > 1 ? 150 : 15))
    }
}

/// Markdown's autolinks start an address only where its local part starts, which keeps a long run without an `@`
/// linear; the matches must be those of the expression without that rule.
struct AutolinkMatchTests {
    @Test("隣り合うメールアドレスも、元の正規表現と同じく両方をリンクにする")
    func matchesTheExpression() throws {
        let domain = #"(?:[\p{L}\p{N}_-]+\.)*[\p{L}\p{N}-]+\.[\p{L}\p{N}-]+"#
        let web = #"(?<![^\s*_~(])(?:https?://|www\.)"# + domain + #"[^\s<]*"#
        let email = #"(?:mailto:|xmpp:)?[A-Za-z0-9._+\-]+@[A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+)+"#
        let expression = try NSRegularExpression(pattern: "(?<web>\(web))|\(email)", options: [.caseInsensitive])
        func described(_ matches: [NSTextCheckingResult]) -> [String] {
            matches.map { "\($0.range) \($0.range(withName: "web"))" }
        }
        let pieces = [
            "a", "b.c", "@", "x.com", ".", "+", "-", "_", " ", "mailto:", "xmpp:", "www.", "http://", "https://", "(",
            ")", "*", "~", "é", "<", "1", "a@a.com", "Z", "\n", "日本",
            // Letters that ICU's case-insensitive [A-Za-z] admits, and other Unicode letters and digits.
            "ſ", "\u{212A}", "ß", "Ａ", "٣", "ǅ", "ﬁ", "İ", "ı",
        ]
        var state: UInt64 = 20_261_123
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        var mismatches: [String] = []
        for text in ["a@a.com+b@b.com", "x@y.z_w@v.u", "a@b.c-d@e.f", "a@a.coſ+b@b.com", "a@a.co\u{212A}+b@b.com"]
            + (0..<20_000).map({ _ in (0..<(next() % 24)).map { _ in pieces[next() % pieces.count] }.joined() })
        {
            let old = expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            if described(old) != described(MarkdownConverter.autolinkMatches(text)) { mismatches.append(text) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).map(\.debugDescription))")
        #expect(MarkdownConverter.convert("a@a.com+b@b.com\n").body.contains(#"<a href="mailto:+b@b.com">"#))
        #expect(MarkdownConverter.convert("a@a.coſ+b@b.com\n").body.contains(#"<a href="mailto:+b@b.com">"#))
    }
}

/// `DocumentOutline.title` finds what the expression it replaced found, with byte searches.
struct TitleSearchTests {
    @Test("題名は、元の正規表現と同じ title から読む")
    func matchesTheExpression() throws {
        let expression = try NSRegularExpression(
            pattern: "<title(?:\\s[^>]*)?>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        func expected(_ html: String) -> String? {
            guard let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                let title = Range(match.range(at: 1), in: html)
            else { return nil }
            return DocumentOutline.plainText(ofHTML: String(html[title])).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        let pieces = [
            "<title", "<TITLE", "<Title", ">", "</title>", "</TITLE>", "</title", " ", "\t", "\u{0B}", "\u{3000}",
            "\u{85}", "\n", "x", "<", "é", "a=\"b>\"", "<b>", "&amp;", "s",
            // Characters that join the `>` before them or the `<` after them into one Character, and line breaks.
            "\u{301}", "\u{200D}", "\u{FE0F}", "\u{0903}", "\u{1F3FB}", "\u{0600}", "\r\n", "\r", "👍🏽",
        ]
        var state: UInt64 = 20_261_123
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        var mismatches: [String] = []
        // A title whose first or last character joins the tag next to it: origin/master returns it as well.
        for html in [
            "<title>\u{301}Report</title>", "<title>\u{200D}Report</title>", "<title>Report\u{0600}</title>",
            "<title>\u{1F3FB}Report</title>", "<title\r\n>Report</title>",
        ] where expected(html) != DocumentOutline.title(ofHTML: html) {
            mismatches.append(html)
        }
        #expect(DocumentOutline.title(ofHTML: "<title>\u{301}Report</title>") == "\u{301}Report")
        for _ in 0..<20_000 {
            let html = (0..<(next() % 16)).map { _ in pieces[next() % pieces.count] }.joined()
            if expected(html) != DocumentOutline.title(ofHTML: html) { mismatches.append(html) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).map(\.debugDescription))")
    }
}

/// Word builds a part's XML tree only after a streaming parse succeeded; below the depth limit, the parts it builds
/// must be those Foundation alone built.
struct WordPartParseTests {
    @Test("深さの上限までの XML の部品は、Foundation だけで組み立てたときと同じものを組み立てる")
    func matchesFoundation() {
        let pieces = [
            "<a>", "</a>", "<b/>", "<c x=\"1\">", "</c>", "<!-- c -->", "<![CDATA[<x>]]>", "&amp;", "&bogus;", "&#65;",
            "&#0;", "<?xml version=\"1.0\"?>", "<!DOCTYPE a>", "<!DOCTYPE a [<!ENTITY e \"v\">]>", "&e;", "x", "<", ">",
            "\"", "<?pi data?>", "\u{0B}", "é", "<w:t xmlns:w=\"urn:w\">", "</w:t>", "<p:q>",
        ]
        var state: UInt64 = 20_261_124
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        var mismatches: [String] = []
        for _ in 0..<4_000 {
            let text = (0..<(next() % 12)).map { _ in pieces[next() % pieces.count] }.joined()
            let data = Data(text.utf8)
            let foundation = (try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])) != nil
            if foundation != (DocxConverter.xmlDocument(data) != nil) { mismatches.append(text) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).map(\.debugDescription))")
    }
}

/// Markdown's inline syntax is matched by its openings and indexed closers; the matches must be those of the full
/// expression with lazy contents that origin/master used.
struct MarkdownInlineMatchTests {
    private static let names = [
        "displayMath", "displayMath2", "inlineMath2", "inlineMath", "verbatim", "criticAdd", "criticDelete",
        "criticOld", "criticNew", "criticMark", "criticComment", "criticUnclosed", "footnote", "rubyBase", "rubyText",
        "mark", "sup", "sub",
    ]

    @Test("Markdown の行内の記法は、元の正規表現と同じ所を同じように読む")
    func matchesTheExpression() throws {
        let math = [
            #"\$\$(?<displayMath>[^$\n]+?)\$\$"#, #"\\\[(?<displayMath2>.+?)\\\]"#, #"\\\((?<inlineMath2>.+?)\\\)"#,
            #"(?<!\$)\$(?<inlineMath>(?=[^\s$])(?:\\.|[^$\\\n])*?(?<=[^\s]))\$(?![0-9$])"#,
        ].joined(separator: "|")
        let verbatim = [
            #"\\[\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E]"#, #"(?<!`)(?<ticks>`+)(?:.*?[^`])?\k<ticks>(?!`)"#,
            #"<[A-Za-z/!?][^<>\n]*>"#, #"\]\((?:[^()\s]|\([^()\s]*\))*(?:\s+(?:"[^"]*"|'[^']*'))?\)"#,
            #"(?:https?://|www\.)[^\s<]+"#,
        ].joined(separator: "|")
        let syntax = [
            #"\{\+\+(?<criticAdd>(?s:.*?))\+\+\}"#, #"\{--(?<criticDelete>(?s:.*?))--\}"#,
            #"\{~~(?<criticOld>(?s:.*?))~>(?<criticNew>(?s:.*?))~~\}"#, #"\{==(?<criticMark>(?s:.*?))==\}"#,
            #"\{>>(?<criticComment>(?s:.*?))<<\}"#, #"(?<criticUnclosed>\{(?:\+\+|--|~~|==|>>))"#,
            #"\[\^(?<footnote>[^\]\s]+)\]"#, #"\{(?<rubyBase>[^{}|\n]+)\|(?<rubyText>[^{}\n]+)\}"#,
            #"(?<![=\\])==(?=[^\s=])(?<mark>.+?)(?<=[^\s\\])==(?!=)"#,
            #"(?<![\\^])\^(?=[^\s^])(?<sup>[^\s^]+?)\^(?!\^)"#, #"(?<![~\\])~(?=[^\s~])(?<sub>[^\s~]+?)~(?!~)"#,
        ].joined(separator: "|")
        let expression = try NSRegularExpression(pattern: "\(math)|(?<verbatim>\(verbatim))|\(syntax)")
        func old(_ text: NSString) -> [String] {
            expression.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { match in
                "\(match.range) "
                    + Self.names.compactMap { name in
                        let range = match.range(withName: name)
                        return range.location == NSNotFound ? nil : "\(name)=\(range)"
                    }.joined(separator: " ")
            }
        }
        func new(_ text: NSString) -> [String] {
            MarkdownExtensions.inlineMatches(text).map { match in
                "\(match.range) "
                    + Self.names.compactMap { name in match.groups[name].map { "\(name)=\($0)" } }.joined(
                        separator: " ")
            }
        }
        let pieces = [
            "{++", "++}", "{--", "--}", "{~~", "~>", "~~}", "{==", "==}", "{>>", "<<}", "==", "=", "^", "~", "$", "$$",
            "\\(", "\\)", "\\[", "\\]", "\\", "`", "``", "[^1]", "{a|b}", "{", "}", "|", "<b>", "<", ">", "](", "(",
            ")", " \"t\"", "http://x", "www.", "\n", " ", "a", "1", "日", "é", "\\$",
            // Backtick runs of every kind, and the other line terminators of ICU's `.`.
            "```", "````", "`a`", "``a``", "`", "`", "\r\n", "\r", "\u{2028}", "\u{0B}",
        ]
        var state: UInt64 = 20_261_124
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        var mismatches: [String] = []
        for _ in 0..<20_000 {
            let text = (0..<(next() % 20)).map { _ in pieces[next() % pieces.count] }.joined() as NSString
            if old(text) != new(text) { mismatches.append(text as String) }
        }
        // Code spans alone: runs of every length, text and line terminators between them.
        let ticks = ["`", "`", "`", "a", " ", "\n", "\r", "\\"]
        for _ in 0..<20_000 {
            let text = (0..<(next() % 24)).map { _ in ticks[next() % ticks.count] }.joined() as NSString
            if old(text) != new(text) { mismatches.append(text as String) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).map(\.debugDescription))")
    }
}

/// Markdown remembers, for each paragraph, the searches across its lines that did not join; a document must read as
/// it does when every line with a brace searches the rest of its paragraph again, as origin/master did.
struct ParagraphMemoTests {
    @Test("段落の探索を覚えても、毎行から探し直したときと同じ Markdown を組む")
    func matchesSearchingEveryLine() {
        let pieces = [
            "a {x} b\n", "{y}\n", "> ", ">> ", "- ", "  ", "    ", "1. ", "{++", "++}", "{--", "--}", "{==", "==}",
            "{~~a~>b~~}", "{>>c<<}", "[l](p.html\n\"t\")", "[l](p.html\n'u')", "`c`", "`c\nd`", "$$x$$\n", "\\[y\\]\n",
            "\n", "\n\n", "text ", "*e* ", "<b>", "</b>", "\\(z\\)", "a {x} [n](p.html\n\"T {x}\") e\n",
            "[m](q.html\n\"U\n{y}\") ", "{x} ==a\nb== ",
        ]
        var state: UInt64 = 20_261_124
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        let texts = (0..<1_500).map { _ in (0..<(next() % 24)).map { _ in pieces[next() % pieces.count] }.joined() }
        // A formula's placeholder that ends up inside raw HTML is a random token in either reading.
        @Sendable func body(_ text: String) -> String {
            MarkdownConverter.convert(text).body.replacingOccurrences(
                of: "[a-z]{12}[0-9]+", with: "TOKEN", options: .regularExpression)
        }
        let differences = StackSpace.onLargeStack { () -> [String] in
            texts.filter { text in body(text) != MarkdownExtensions.searchingEveryLine { body(text) } }
        }
        #expect(differences.isEmpty, "\(differences.prefix(3).map(\.debugDescription))")
    }

    @Test("題名が次の行から始まるリンクが段落に並んでも、段落の探索は行数に比例する分しか読まない")
    func repeatedLinkTitlesAreSearchedOnce() {
        let pairs = 300
        let text = String(repeating: "a {x} [note](page.html\n\"Title {x}\") end\n", count: pairs)
        let lines = pairs * 2
        let (remembered, everyLine) = StackSpace.onLargeStack { () -> ((String, Int), (String, Int)) in
            var body = ""
            let remembered = MarkdownExtensions.countingScannedLines { body = MarkdownConverter.convert(text).body }
            var again = ""
            let everyLine = MarkdownExtensions.countingScannedLines {
                again = MarkdownExtensions.searchingEveryLine { MarkdownConverter.convert(text).body }
            }
            return ((body, remembered), (again, everyLine))
        }
        #expect(remembered.0 == everyLine.0)
        #expect(remembered.1 <= lines * 6, "\(remembered.1) lines read for \(lines)")
        // The count is the one that grew with the square of the paragraph before the memo reused earlier searches.
        #expect(everyLine.1 >= lines * lines / 2, "\(everyLine.1) lines read without the memo")
    }
}

/// Markdown skips measuring a text with too few delimiters to nest past the limit; the shortcut must never skip a
/// text that is too deep.
struct NestingShortcutTests {
    @Test("区切りの少ない文書を測らずに済ませても、測ったときと同じ深さの判定になる")
    func matchesMeasuring() {
        let markers = [
            "> ", ">", "- ", "* ", "+ ", "1. ", "1) ", "  ", "    ", "\n", "\n> ", "\n- ", "*", "_", "[", "](u)",
        ]
        let ends = ["x", "x.", "", "*x*", "`x`", "[x](u)", "| a | b |\n|---|---|\n| c | d |"]
        var state: UInt64 = 20_261_124
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        var mismatches: [String] = []
        for _ in 0..<3_000 {
            let text =
                (0..<(30 + next() % 40)).map { _ in markers[next() % markers.count] }.joined()
                + ends[next() % ends.count]
            if MarkdownNesting.isShallow(text) != MarkdownNesting.isShallowMeasured(text) { mismatches.append(text) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(3).map(\.debugDescription))")
    }
}

/// A notebook's JSON is pruned past 100 levels before Foundation reads it; below that, Foundation must read exactly
/// what it read without the pruning.
struct NotebookJSONTests {
    @Test("百段までの JSON は、刈り込みの前処理があっても Foundation だけで読んだのと同じになる")
    func matchesFoundation() {
        let pieces = [
            "{", "}", "[", "]", ",", ":", "\"a\"", "\"[\"", "\"{\\\"}\"", "\"\\\\\"", "\"\\u005b\"", "1", "-2.5e3",
            "true",
            "null", " ", "\n", "\"日本\"", "\"", "\\", "x",
        ]
        var state: UInt64 = 20_261_124
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        var mismatches: [String] = []
        for _ in 0..<5_000 {
            let text = (0..<(next() % 14)).map { _ in pieces[next() % pieces.count] }.joined()
            let foundation = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            let read = try? NotebookConverter.jsonObject(text)
            let same: Bool =
                switch (foundation, read) {
                case (nil, nil): true
                case (let value?, let read?): !read.pruned && (value as AnyObject).isEqual(read.value)
                default: false
                }
            if !same { mismatches.append(text) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).map(\.debugDescription))")
    }
}
