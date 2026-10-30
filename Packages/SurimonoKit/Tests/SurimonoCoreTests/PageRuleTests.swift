import SurimonoCore
import Testing

struct PageRuleTests {
    @Test(
        "@page の size から向きを読む",
        arguments: [
            ("landscape", PaperOrientation.landscape),
            ("A4 landscape", .landscape),
            ("A3 landscape", .landscape),
            ("landscape A4", .landscape),
            ("297mm 210mm", .landscape),
            ("11in 8.5in", .landscape),
            ("29.7cm 21cm", .landscape),
            ("1123px 794px", .landscape),
            ("A4 LANDSCAPE !important", .landscape),
            ("portrait", .portrait),
            ("A4 portrait", .portrait),
            ("A4", .portrait),
            ("letter", .portrait),
            ("210mm 297mm", .portrait),
            ("8.5in 11in", .portrait),
        ])
    func orientation(size: String, expected: PaperOrientation) {
        #expect(PageRule.orientation(ofSize: size) == expected)
    }

    @Test("auto・正方形・1 つだけの長さ・知らない値は向きを決めない", arguments: ["auto", "", "200mm", "200mm 200mm", "huge", "0 0"])
    func noOrientation(size: String) {
        #expect(PageRule.orientation(ofSize: size) == nil)
    }

    @Test("全ページの @page のうち後の指定が勝ち、:first や名前つきのページだけの指定では向きを変えない")
    func lastRuleForAllPagesWins() {
        #expect(
            PageRule.orientation(of: [PageRule(size: "portrait"), PageRule(size: "A4 landscape")]) == .landscape)
        #expect(
            PageRule.orientation(of: [PageRule(size: "landscape"), PageRule(selector: ":first", size: "portrait")])
                == .landscape)
        #expect(PageRule.orientation(of: [PageRule(selector: "wide", size: "landscape")]) == nil)
        #expect(PageRule.orientation(of: [PageRule(size: "landscape"), PageRule(size: "auto")]) == nil)
        #expect(PageRule.orientation(of: []) == nil)
    }

    @Test("スクリプトの結果の JSON から @page を読み、読めなければ何もないとする")
    func rulesFromJSON() {
        #expect(
            PageRule.rules(fromJSON: #"[{"selector":"","size":"A4 landscape"},{"selector":":first","size":"A4"}]"#)
                == [PageRule(size: "A4 landscape"), PageRule(selector: ":first", size: "A4")])
        #expect(PageRule.rules(fromJSON: "broken").isEmpty)
    }

    @Test("!important の size は後の通常の指定より強く、同じ強さなら後の指定が勝つ")
    func importantWins() {
        #expect(
            PageRule.orientation(of: [
                PageRule(size: "landscape", important: true), PageRule(size: "portrait"),
            ]) == .landscape)
        #expect(
            PageRule.orientation(of: [
                PageRule(size: "portrait"), PageRule(size: "landscape", important: true),
            ]) == .landscape)
        #expect(
            PageRule.orientation(of: [
                PageRule(size: "landscape", important: true), PageRule(size: "portrait", important: true),
            ]) == .portrait)
        #expect(
            PageRule.orientation(of: [
                PageRule(size: "portrait"), PageRule(selector: ":first", size: "landscape", important: true),
            ]) == .portrait)
    }

    @Test("スクリプトの結果に important がなければ通常の指定として読む")
    func importantDefaultsToFalse() {
        #expect(PageRule.rules(fromJSON: #"[{"selector":"","size":"A4"}]"#) == [PageRule(size: "A4")])
        #expect(
            PageRule.rules(fromJSON: #"[{"selector":"","size":"A4","important":true}]"#)
                == [PageRule(size: "A4", important: true)])
    }

    @Test("@page を読むスクリプトは印刷に当たる指定だけを読み、結果を JSON で返す")
    func script() {
        let script = PageRule.javaScript
        #expect(script.contains("PAGE_RULE"))
        #expect(script.contains("printMatches"))
        #expect(script.contains("CSS.supports"))
        #expect(script.contains("sheet.disabled"))
        #expect(script.contains("getPropertyPriority('size')"))
        #expect(script.hasSuffix("return JSON.stringify(rules);"))
    }
}
