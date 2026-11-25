import Foundation
import Testing

@testable import SurimonoFormats

struct ReadingPrefixTests {
    @Test("テキストは100万バイトを超えたときだけ先頭を組む")
    func textThreshold() {
        let text = String(repeating: "a\n", count: 500_000)
        #expect(ReadingPrefix.text(text, sourceBytes: 999_999) == nil)
        #expect(ReadingPrefix.text(text, sourceBytes: 1_000_000) == nil)
        #expect(ReadingPrefix.text(text + "z", sourceBytes: 1_000_001) == String(repeating: "a\n", count: 1_000))
    }

    @Test("バイト境界が多バイト文字やCRLFの途中なら直前の行末で切る")
    func intactLines() {
        let start = "初め\r\n"
        let padding = String(repeating: "x", count: 200_000 - start.utf8.count - 1)
        for ending in ["猫", "\r\n"] {
            let text = start + padding + ending + String(repeating: "末", count: 300_000)
            #expect(ReadingPrefix.text(text, sourceBytes: text.utf8.count) == start)
        }
    }

    @Test("終端の改行がない長い行を途中で表示しない")
    func unterminatedLine() {
        let long = String(repeating: "z", count: 1_000_001)
        #expect(ReadingPrefix.text(long, sourceBytes: long.utf8.count) == nil)
        let text = "first\rlast complete\n" + long
        #expect(ReadingPrefix.text(text, sourceBytes: text.utf8.count) == "first\rlast complete\n")
    }

    @Test("Shift_JISの全文から決めた文字コードで先頭の日本語を表示する")
    func wholeEncoding() throws {
        let text = String(repeating: "かなのログ\r\n", count: 110_000)
        let bytes = try #require(text.data(using: .shiftJIS))
        let decoded = TextDecoding.decode(bytes, preservingLineEndings: true)
        #expect(decoded.encoding == .shiftJIS)
        #expect(
            ReadingPrefix.text(decoded.text, sourceBytes: bytes.count) == String(repeating: "かなのログ\r\n", count: 1_000))
    }

    @Test("CSVは見出し込み5000レコードまで全文だけを組む", arguments: [0, 1, 2, 999, 1_000, 5_000])
    func csvThreshold(_ count: Int) {
        #expect(ReadingPrefix.csv(Array(repeating: ["x"], count: count)[...]) == nil)
    }

    @Test("CSVの先頭は見出しを一度だけ含み引用符内改行とカンマと二重引用符を保つ")
    func csvRecords() throws {
        let text =
            "label,note\r\n" + String(repeating: "a,b\r\n", count: 998)
            + "\"last,in prefix\",\"two\r\nlines with \"\"quotes\"\"\"\r\n"
            + String(repeating: "outside,tail\r\n", count: 4_000) + "end,done"
        let rows = CSVConverter.records(text, delimiter: ",", checkRow: { _ in })
        let prefix = try #require(ReadingPrefix.csv(rows[...]))
        #expect(prefix.count == 1_000)
        #expect(prefix.last == ["last,in prefix", "two\nlines with \"quotes\""])
        let html = CSVConverter.table(prefix).body
        #expect(html.hasPrefix("<table class=\"surimono-csv\"><thead><tr><th>label</th><th>note</th></tr></thead>"))
        #expect(!html.contains("outside"))
        #expect(rows.last == ["end", "done"])
    }

    @Test("最初のCSVデータ行が予算を超えたら不完全な表を出さない")
    func oversizedRecord() {
        let rows = [["header"], [String(repeating: "x", count: 200_001)]] + Array(repeating: ["a"], count: 5_000)
        #expect(ReadingPrefix.csv(rows[...]) == nil)
    }

    private func columnShares(header: [String], row: [String], width: Double = 512) throws -> [Double] {
        try columnShares(rows: [header] + Array(repeating: row, count: 5_000), width: width)
    }

    private func columnShares(rows: [[String]], width: Double = 512) throws -> [Double] {
        let group = try #require(ReadingPrefix.csvColumnGroup(in: rows, widthAtDefaultScale: width))
        let shares = group.matches(of: /<col(?: span="([0-9]+)")? style="width:([0-9.]+)%">/).flatMap { match in
            Array(repeating: Double(match.2)!, count: match.1.flatMap { Int($0) } ?? 1)
        }
        try #require(shares.count == rows.map(\.count).max())
        #expect(abs(shares.reduce(0, +) - 100) < 0.0001)
        return shares
    }

    @Test("長い備考があっても金額の短い英語見出しとセルの余白を収める")
    func amountHeader() throws {
        let shares = try columnShares(
            header: ["id", "name", "amount", "date", "note"],
            row: ["1", "Ada", "104", "2026-11-25", String(repeating: "description ", count: 10)])
        #expect(shares[2] / 100 * 512 >= 57.5 - 0.0001)
        #expect(shares[0] < shares[2] && shares[4] > shares[2])
    }

    @Test("標準のA4で五万九千行の明細を組むと、後半の五桁の番号・品名・備考も一行に収まる")
    func datedItems() throws {
        let header = ["id", "name", "amount", "date", "note"]
        let rows =
            [header]
            + (0..<59_000).map { index in
                ["\(index)", "item \(index)", "\(index)", "2026-11-01", "a longer note about item number \(index)"]
            }
        let width = (210.0 - 2 * 15) * 72 / 25.4
        let shares = try columnShares(rows: rows, width: width)
        // Five-digit values dominate the document, but none occur in the reading preview.
        #expect(ReadingPrefix.csv(rows[...])?.last?[0] == "998")
        for (share, natural) in zip(shares, [9, 14, 10, 14, 41]) {
            #expect(share / 100 * width / 5.75 >= Double(natural))
            #expect(abs(share - Double(natural) / 88 * 100) < 0.0001)
        }
    }

    @Test("二つの自由文が収まらないときは両方を縮め、短い列は自然幅を保つ")
    func shrinkWideColumns() throws {
        let shares = try columnShares(
            header: ["id", "date", "note", "description"],
            row: ["12", "2026-11-01", String(repeating: "alpha ", count: 12), String(repeating: "beta ", count: 20)],
            width: 414)
        let widths = shares.map { $0 / 100 * 72 }
        for (width, expected) in zip(widths, [8, 14, 25, 25]) {
            #expect(abs(width - Double(expected)) < 0.0001)
        }
    }

    @Test("自然幅は九割のセルが収まる長さで決まり、まれな長文には引きずられない")
    func percentileWidth() throws {
        var rows = [["key", "note"]] + Array(repeating: ["123456", "crew"], count: 5_000)
        for index in 2_001...2_499 { rows[index][1] = String(repeating: "note ", count: 14) }
        let shares = try columnShares(rows: rows)
        #expect(abs(shares[1] - 100.0 * 8 / 18) < 0.0001)
        rows[2_500][1] = rows[2_001][1]
        // With 500 long values among 5,001 cells the 4,501st is still short.
        #expect(try columnShares(rows: rows) == shares)
        rows[2_501][1] = rows[2_001][1]
        #expect(try columnShares(rows: rows)[1] > 80)
    }

    @Test("長い自由文の途中の識別子も拾い、ハッシュの最小幅は半角十六文字で頭打ちになる")
    func boundedBodyTokens() throws {
        let header = ["id", "code", "note"]
        let prose = String(repeating: "a ", count: 20)
        let notes = String(repeating: "short ", count: 12)
        var rows = [header] + Array(repeating: ["1", prose, notes], count: 5_000)
        // The preferred line width is already saturated before this later record introduces an identifier.
        rows[4_500][1] = prose + String(repeating: "x", count: 16)
        let bounded = try columnShares(rows: rows, width: 230)
        #expect(bounded[1] >= 50)
        rows[4_500][1] += String(repeating: "x", count: 200)
        #expect(try columnShares(rows: rows, width: 230) == bounded)
    }

    @Test("見出しの和文四文字には欧文八文字分と左右の余白を確保する")
    func wideHeader() throws {
        let shares = try columnShares(
            header: ["id", "税込金額", "note", "description"],
            row: ["1", "104", String(repeating: "x", count: 40), String(repeating: "y", count: 60)])
        #expect(shares[1] / 100 * 512 >= 69 - 0.0001)
    }

    @Test("和文セルの自然幅は全角を二単位で数え、セル内改行では最長の行を使う")
    func wideBodyLines() throws {
        let shares = try columnShares(
            header: ["id", "label", "名称"],
            row: ["1", "abcd efgh ijkl mnop", "東京 大阪 京都 奈良\n注"])
        #expect(abs(shares[1] - shares[2]) < 0.0001)
        #expect(abs(shares[1] - 100.0 * 23 / 54) < 0.0001)
    }

    @Test("空白で折り返せる長い見出しは最長の語だけを確保し、他列の短い見出しを押し出さない")
    func headerWithWords() throws {
        let phrase = "average amount per branch in spring"
        let shares = try columnShares(
            header: [phrase, "amount", phrase, "note"], row: ["1", "104", "2", String(repeating: "x", count: 60)])
        #expect(shares[1] / 100 * 512 >= 57.5 - 0.0001 && shares[0] == shares[2])
    }

    @Test("見出しの最小幅が合計で収まらないときは本文を含む従来の比率を使う")
    func crowdedHeaders() throws {
        let header = Array(repeating: "amount", count: 12)
        var row = Array(repeating: "104", count: header.count)
        row[0] = String(repeating: "x", count: 100)
        let shares = try columnShares(header: header, row: row)
        #expect(shares[0] == 3_200.0 / 98)
        #expect(shares.dropFirst().allSatisfy { $0 == 600.0 / 98 })
        let wider = try columnShares(header: header, row: row, width: 1_024)
        #expect(wider.dropFirst().allSatisfy { $0 / 100 * 1_024 >= 57.5 - 0.0001 })
    }

    @Test("後半で現れる列にも最長の語を確保し、省略されたセルは自然幅に加算しない")
    func weightedColumns() throws {
        var rows = [["id", "名前", "東京都内の窓口名", "detail"]] + Array(repeating: ["1"], count: 5_000)
        rows[999] = ["1", "東京支店", "短文\n短文", String(repeating: "界", count: 10_000)]
        rows[4_999] = ["1", "outside sample", "", "", "late column", ""]
        let shares = try columnShares(rows: rows, width: 460)
        let units = shares.map { $0 / 100 * 80 }
        // The sparse columns have zero-width P90, but the Japanese name and the late word retain their minima.
        #expect(units[1] >= 12 && units[2] >= 20 && units[3] >= 20 && units[4] >= 10)
        #expect(abs(units[5] - 4) < 0.0001)
        #expect(ReadingPrefix.csvColumnGroup(in: Array(rows.prefix(5_000))) == nil)
    }

    @Test("先頭のバイト制限を超えた後の列も全文の幅に含める")
    func columnsBeyondByteBudget() throws {
        let rows =
            [["id"], ["1"], ["2", String(repeating: "長", count: 100_000)]]
            + Array(repeating: ["3"], count: 5_000)
        #expect(ReadingPrefix.csv(rows[...])?.count == 2)
        let shares = try columnShares(rows: rows, width: 460)
        // The lone value sets the capped token minimum (16 plus padding); its entire line is an outlier.
        #expect(abs(shares[1] - 100.0 * 20 / 28) < 0.0001)
    }

    @Test("途中で列が増え最小幅が収まらなくなっても前半と後半の両方の最大幅を使う")
    func lateCrowdedRow() throws {
        var rows = [["id"], [String(repeating: "x", count: 37)]] + Array(repeating: ["1"], count: 5_000)
        rows[4_999] = Array(repeating: "", count: 25) + [String(repeating: "界", count: 20)]
        let shares = try columnShares(rows: rows, width: 460)
        #expect(shares[0] == 20 && shares[25] == 20)
        #expect(shares[1..<25].allSatisfy { $0 == 2.5 })
    }
}
