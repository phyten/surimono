import Foundation
import SurimonoCore
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
