import Foundation
import SurimonoFormats
import Testing

struct CSVDelimiterTests {
    @Test("タブで区切った表はタブ、カンマで区切った表はカンマと読む")
    func delimiters() {
        #expect(CSVConverter.guessedDelimiter(of: "name\tqty\napple\t3\npear\t2\n") == "\t")
        #expect(CSVConverter.guessedDelimiter(of: "name,qty\napple,3\npear,2\n") == ",")
    }

    @Test("タブ区切りの欄の中のカンマではカンマ区切りにならない")
    func commasInsideTabbedFields() {
        #expect(CSVConverter.guessedDelimiter(of: "name\tnote\nTokyo\t1,234,567 people\r\nOsaka\t2,000\r\n") == "\t")
    }

    @Test("どの行もタブの数が同じなら、欄の中のカンマの方が多くてもタブで読む")
    func thousandsSeparatorsInTabbedCells() {
        let text = "Name\tAmount\nA\t1,200,000\nB\t3,400,000\n"
        #expect(CSVConverter.guessedDelimiter(of: text) == "\t")
        let html = CSVConverter.convert(text, delimiter: CSVConverter.guessedDelimiter(of: text)).body
        #expect(html.contains("<td>A</td><td>1,200,000</td>"))
    }

    @Test("カンマの数がそろった表は、欄の中にタブが混じってもカンマで読む")
    func tabsInsideCommaFields() {
        #expect(CSVConverter.guessedDelimiter(of: "name,note\napple,a\tb\tc\npear,d\n") == ",")
    }

    @Test("どちらの数もそろわない表は、多く区切る方で読む")
    func irregularTable() {
        #expect(CSVConverter.guessedDelimiter(of: "a\tb\nc\td\te,f\n") == "\t")
        #expect(CSVConverter.guessedDelimiter(of: "a,b\nc,d,e\tf\n") == ",")
    }

    @Test("引用符の中のタブは数えない")
    func quotedTabs() {
        #expect(CSVConverter.guessedDelimiter(of: "a,b,c\n\"x\ty\",2,3\n") == ",")
    }

    @Test("区切りのない文字はカンマで読む")
    func noDelimiter() {
        #expect(CSVConverter.guessedDelimiter(of: "one line") == ",")
        #expect(CSVConverter.guessedDelimiter(of: "") == ",")
    }

    @Test("推した区切りで読むとタブ区切りの表が欄に分かれる")
    func tabbedTableConverts() {
        let text = "name\tqty\napple\t3\n"
        let html = CSVConverter.convert(text, delimiter: CSVConverter.guessedDelimiter(of: text)).body
        #expect(html.contains("<th>name</th><th>qty</th>"))
        #expect(html.contains("<td>apple</td><td>3</td>"))
    }
}
