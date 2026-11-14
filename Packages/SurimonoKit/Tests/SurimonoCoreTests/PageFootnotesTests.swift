import Foundation
import Testing

@testable import SurimonoCore

struct PageFootnotesTests {
    private func reference(_ number: Int) -> String {
        "<sup class=\"footnote-ref\"><a href=\"#fn-\(number)\" id=\"fnref-\(number)\">\(number)</a></sup>"
    }

    private func notes(_ contents: [String]) -> String {
        "<section class=\"footnotes\"><ol>"
            + contents.enumerated().map { "<li id=\"fn-\($0.offset + 1)\">\($0.element)</li>" }.joined()
            + "</ol></section>"
    }

    @Test("脚注も適格な参照もなければ計画を作らない")
    func absent() {
        #expect(PageFootnotes.plan(for: "<p>本文</p>") == nil)
        #expect(PageFootnotes.plan(for: reference(9) + notes(["注"])) == nil)
        #expect(PageFootnotes.plan(for: notes([reference(1)])) == nil)
    }

    @Test("表とコードと図と数式の中の参照は文末に残す")
    func exclusions() throws {
        for tag in ["table", "pre", "code", "svg", "math", "figure"] {
            let html = "<\(tag)>\(reference(1))</\(tag)>" + reference(2) + notes(["残す", "移す"])
            let planned = try #require(PageFootnotes.plan(for: html))
            #expect(planned.eligibleNotes == [2])
            #expect(planned.references.map(\.eligible) == [false, true])
            let measured = planned.measuringHTML(placing: [2])
            #expect(measured.contains("<li id=\"fn-1\" value=\"1\">残す</li>"))
            #expect(measured.contains("class=\"paper-footnote\" id=\"fn-2\""))
        }
    }

    @Test("最初の参照が表の中にある脚注は後で本文から参照しても文末に残す")
    func firstReferenceDecides() throws {
        let html = "<table>\(reference(1))</table><p>\(reference(1))</p><p>\(reference(2))</p>" + notes(["残す", "移す"])
        let planned = try #require(PageFootnotes.plan(for: html))
        #expect(planned.eligibleNotes == [2])
        #expect(planned.references.map(\.eligible) == [false, false, true])
    }

    @Test("変更の印の目印は残した脚注にも移した脚注にも付け直す")
    func keepsChangeMarkIDs() throws {
        let html =
            "<p>\(reference(1))</p><table>\(reference(2))</table>"
            + "<section class=\"footnotes\"><ol><li id=\"fn-1\" data-surimono-block=\"b1\">移す</li>"
            + "<li id=\"fn-2\" data-surimono-block=\"b2\">残す</li></ol></section>"
        let planned = try #require(PageFootnotes.plan(for: html))
        let measuring = planned.measuringHTML(placing: planned.eligibleNotes)
        #expect(measuring.contains("<div class=\"paper-footnote\" id=\"fn-1\" data-surimono-block=\"b1\">"))
        #expect(measuring.contains("<li id=\"fn-2\" value=\"2\" data-surimono-block=\"b2\">残す</li>"))
    }

    @Test("繰り返し参照は別の出現位置を持ち脚注は一度だけ測る")
    func repeated() throws {
        let planned = try #require(PageFootnotes.plan(for: reference(1) + reference(1) + notes(["注"])))
        #expect(planned.references.map(\.index) == [0, 1])
        #expect(planned.eligibleNotes == [1])
        let measured = planned.measuringHTML(placing: [1])
        #expect(measured.components(separatedBy: "class=\"paper-footnote\"").count == 2)
        #expect(!measured.contains("section class=\"footnotes\""))
    }

    @Test("残した脚注の番号と移した脚注の内部HTMLを保つ")
    func stock() throws {
        let inner = "<p>注<svg><text>x</text></svg><a href='https://example.test'>資料</a></p>"
        let html = reference(1) + notes([inner, "残す"]) + "<section class=\"paper-links\">リンク</section>"
        let planned = try #require(PageFootnotes.plan(for: html))
        let measured = planned.measuringHTML(placing: [1])
        #expect(measured.contains("<li id=\"fn-2\" value=\"2\">残す</li>"))
        #expect(measured.contains(inner))
        #expect(measured.contains("paper-footnote-number\">1</span>"))
        #expect(measured.components(separatedBy: "paper-footnote-stock-mark").count == 3)
        #expect(
            try #require(measured.range(of: "paper-links")).lowerBound
                < #require(measured.range(of: "paper-footnote-stock\"")).lowerBound)
    }

    @Test("予約領域は指定した参照のsupの直後に一つだけ挿入する")
    func reserve() throws {
        let planned = try #require(PageFootnotes.plan(for: reference(1) + "あと" + reference(1) + notes(["注"])))
        let reserved = planned.reservingHTML(groups: [.init(firstReference: 0, notes: [1], heightPixels: 60)])
        #expect(reserved.contains("</sup><span class=\"paper-footnote-room\" style=\"height:60px\">"))
        #expect(reserved.contains("</a></span>あと<sup"))
        #expect(reserved.components(separatedBy: "class=\"paper-footnote-room\"").count == 2)
    }

    @Test("脚注内からだけ参照される別の脚注は末尾に残す")
    func nestedReference() throws {
        let planned = try #require(PageFootnotes.plan(for: reference(1) + notes(["本文" + reference(2), "補足"])))
        #expect(planned.eligibleNotes == [1])
        #expect(planned.references.count == 1)
        #expect(planned.measuringHTML(placing: [1]).contains("<li id=\"fn-2\" value=\"2\">補足</li>"))
    }

    @Test("古い設定と未知の値は文末を使い既定のキーを書き出さない")
    func coding() throws {
        for json in ["{}", "{\"footnotes\":\"future\"}"] {
            #expect(try JSONDecoder().decode(PrintFinish.self, from: Data(json.utf8)).footnotes == .end)
        }
        let encoded = try JSONEncoder().encode(PrintFinish())
        #expect(!String(decoding: encoded, as: UTF8.self).contains("footnotes"))
        var finish = PrintFinish()
        finish.footnotes = .pageBottom
        #expect(try JSONDecoder().decode(PrintFinish.self, from: JSONEncoder().encode(finish)) == finish)
    }
}
