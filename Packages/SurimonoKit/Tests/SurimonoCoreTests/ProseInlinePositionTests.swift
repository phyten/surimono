import Testing

@testable import SurimonoCore

@Suite("文章の点検・Markdown のインラインと原文位置", .timeLimit(.minutes(1)))
struct ProseInlinePositionTests {
    @Test("リストの通常の継続行・不足した字下げ・タブでも強調とリンクの語を元の位置で読む")
    func listContinuations() throws {
        let cases = [
            ("1. Intro.\n  *the* the paper.", "Intro.\nthe the paper.", 13..<16, 18..<21),
            ("1. Intro.\n  [the](target \"title\") the grain.", "Intro.\nthe the grain.", 13..<16, 34..<37),
            ("1. Intro.\n   *the* the paper.", "Intro.\nthe the paper.", 14..<17, 19..<22),
            ("1. Intro.\n\t[the](target) the grain.", "Intro.\nthe the grain.", 12..<15, 25..<28),
            ("- outer\n  1. Intro.\n    *the* the paper.", "Intro.\nthe the paper.", 25..<28, 30..<33),
        ]
        for (input, expected, first, second) in cases {
            let report = try ProseTesting.report(input)
            let p = try #require(report.paragraphs.last)
            #expect(p.text == expected)
            #expect(p.sourceRange(of: 7..<10) == first)
            #expect(p.sourceRange(of: 11..<14) == second)
            #expect(report.findings.contains { $0.kind == .adjacentDuplicate(word: "the") })
        }
    }

    @Test("強調・二重強調・リンクラベルの中の通常改行も強制改行も語を分ける")
    func nestedBreaks() throws {
        let cases = [
            ("*the\nthe* paper folds.", "the\nthe paper folds.", 3..<4, 4..<5, 1..<8),
            ("**the  \r\nthe** paper folds.", "the\nthe paper folds.", 3..<4, 7..<9, 2..<12),
            ("See [the\nthe](target \"title\") paper.", "See the\nthe paper.", 7..<8, 8..<9, 5..<12),
            ("See [the\\\r\nthe](target) paper.", "See the\nthe paper.", 7..<8, 9..<11, 5..<14),
        ]
        for (input, expected, visible, original, duplicate) in cases {
            let report = try ProseTesting.report(input)
            let p = try #require(report.paragraphs.first)
            #expect(p.text == expected)
            #expect(p.sourceRange(of: visible) == original)
            #expect(report.facts.english?.medianLength == 4)
            #expect(
                report.findings.first { $0.kind == .adjacentDuplicate(word: "the") }?.occurrences.first?.sourceRange
                    == duplicate)
        }
    }

    @Test("数式内のバッククォートで後続の本文とコードが消えない")
    func mathBeforeCode() throws {
        let report = try ProseTesting.report(#"Use $\text{`}$ to mark the the character `x`."#)
        let p = try #require(report.paragraphs.first)
        #expect(p.text == "Use \u{FFFC} to mark the the character \u{FFFC}.")
        #expect(p.sourceRange(of: 4..<5) == 4..<14)
        #expect(p.sourceRange(of: 32..<33) == 41..<44)
        #expect(
            report.findings.first { $0.kind == .adjacentDuplicate(word: "the") }?.occurrences.first?.sourceRange
                == 23..<30)
    }

    @Test("強調区切りの余りは実際に印刷される側の一文字だけを読む")
    func leftoverDelimiters() throws {
        for (input, expected, visible, original) in [
            ("***the**** the paper.", "the* the paper.", 3..<4, 9..<10),
            ("****the*** the paper.", "*the the paper.", 0..<1, 0..<1),
            ("Read ****the***.", "Read *the.", 5..<6, 5..<6),
            (#"***the****\* paper."#, "the** paper.", 3..<5, 9..<12),
            ("**a***b** in print.", "ab* in print.", 2..<3, 8..<9),
        ] {
            let p = try #require(ProseTesting.report(input).paragraphs.first)
            #expect(p.text == expected)
            #expect(p.sourceRange(of: visible) == original)
        }
        let report = try ProseTesting.report("***" + String(repeating: "あ", count: 76) + "****。")
        #expect(report.facts.japanese?.medianLength == 78)
        #expect(report.findings.isEmpty)
    }

    @Test("複数行のコードの中のドル記号を保護して、その後に現れる数式の桁を保つ")
    func formulaAfterMultilineCode() throws {
        let p = try #require(ProseTesting.report("Read `$a$\n$b$` then $é$ after.").paragraphs.first)
        #expect(p.text == "Read \u{FFFC} then \u{FFFC} after.")
        #expect(p.sourceRange(of: 5..<6) == 5..<14)
        #expect(p.sourceRange(of: 12..<13) == 20..<23)
    }

    @Test("コード内のドル記号はコードに残り、強調表示内の数式は元の UTF-16 範囲を指す")
    func nestedFormula() throws {
        let p = try #require(ProseTesting.report("Use `$skip$` and ==$é😀`$== then `x`.").paragraphs.first)
        #expect(p.text == "Use \u{FFFC} and \u{FFFC} then \u{FFFC}.")
        #expect(p.sourceRange(of: 4..<5) == 4..<12)
        #expect(p.sourceRange(of: 10..<11) == 19..<25)
        #expect(p.sourceRange(of: 17..<18) == 33..<36)
    }
}

@Suite("文章の点検・文の境界")
struct ProseSentenceBoundaryTests {
    @Test("例示の略語の直後の A4 は文頭にならない")
    func exampleAbbreviation() {
        let input = "Use a paper size, e.g. A4 or Letter. Then fold it."
        #expect(ProseSentences.ranges(in: Array(input.utf16), lineBreaksEnd: false) == [0..<36, 37..<50])
        for abbreviation in ["i.e.", "fig."] {
            let text = "See " + abbreviation + " A4 next. Then fold."
            #expect(ProseSentences.ranges(in: Array(text.utf16), lineBreaksEnd: false) == [0..<17, 18..<28])
        }
    }

    @Test("etc. のあとの Next から次の文を読む")
    func terminalAbbreviation() {
        let input = "We need paper, scissors, etc. Next, fold the sheet."
        #expect(ProseSentences.ranges(in: Array(input.utf16), lineBreaksEnd: false) == [0..<29, 30..<51])
    }

    @Test("全角ピリオドは半角・全角の数字の間では小数点になり、文末では文を区切る")
    func wideDecimal() {
        for input in ["値は３．１４です。次です。", "値は3．14です。次です。"] {
            #expect(ProseSentences.ranges(in: Array(input.utf16), lineBreaksEnd: false) == [0..<9, 9..<13])
        }
        #expect(ProseSentences.ranges(in: Array("です．次です．".utf16), lineBreaksEnd: false) == [0..<3, 3..<7])
    }

    @Test("アクセントの表現が違ってもプレーンテキストの折り返しで文数と語数が変わらない")
    func accentBeforeBreak() throws {
        for (input, original) in [("The café\nserves coffee.", 0..<23), ("The cafe\u{0301}\nserves coffee.", 0..<24)] {
            let report = try ProseTesting.report(input, format: .plainText)
            #expect(report.facts.english?.count == 1)
            #expect(report.facts.english?.medianLength == 4)
            #expect(ProseSentences.ranges(in: Array(input.utf16), lineBreaksEnd: true) == [original])
        }
    }
}
