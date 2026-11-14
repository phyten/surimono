import Foundation
import SurimonoCore
import Testing

struct PaperLinksTests {
    @Test("同じリンク先には最初に現れた順の番号を共有する")
    func sharedNumbers() {
        let html = "<a href='https://a.test'>甲</a><a href='https://b.test'>乙</a><a href='https://a.test'>再掲</a>"
        let result = PaperLinks.endnotes.apply(to: html, language: "ja")
        #expect(result.components(separatedBy: "class=\"paper-link-ref\">[1]</sup>").count == 3)
        #expect(result.contains("[2]</sup>"))
        #expect(result.contains(">リンク</h2>"))
        #expect(result.components(separatedBy: "<li>").count == 3)
    }

    @Test("自動リンクと内部リンクと相対パスと画像だけのリンクを除く")
    func exclusions() {
        let html = """
            <a href='https://a.test'>https://a.test</a><a href='https://a.test'>a.test</a>
            <a href='#x'>内部</a><a href='file.md'>相対</a><a href='https://a.test'><img src='a.png'></a>
            <nav class='toc'><a href='https://a.test'>目次</a></nav>
            <sup class='footnote-ref'><a href='https://a.test'>1</a></sup>
            <pre><a href='https://a.test'>コード</a></pre><code><a href='https://a.test'>コード</a></code>
            <svg><a href='https://a.test'><text>数式</text></a></svg>
            """
        #expect(PaperLinks.endnotes.apply(to: html) == html)
        #expect(PaperLinks.inline.apply(to: html) == html)
    }

    @Test("見出しの中のリンクには何も足さない")
    func headings() {
        let html = "<h1><a href='https://a.test'>API</a> の使い方</h1><h3>節 <a href='https://b.test'>乙</a></h3>"
        #expect(PaperLinks.endnotes.apply(to: html) == html)
        #expect(PaperLinks.inline.apply(to: html) == html)
    }

    @Test("メールと特殊文字を含むリンク先を安全な文字として添える")
    func escaping() {
        let html = "<a href='mailto:help@example.test'>連絡</a><a href='https://a.test/?a=1&amp;b=&quot;x&quot;'>参照</a>"
        let result = PaperLinks.inline.apply(to: html)
        #expect(result.contains(" (mailto:help@example.test)</span>"))
        #expect(result.contains(" (https://a.test/?a=1&amp;b=&quot;x&quot;)</span>"))
        #expect(!result.contains("paper-link-ref"))
    }

    @Test("そのままでは入力のバイト列を一切変更しない")
    func unchanged() {
        let html = "\r\n<!-- a --><a HREF='https://a.test?a=1&amp;b=2'>参照</a>\t"
        #expect(Array(PaperLinks.asIs.apply(to: html).utf8) == Array(html.utf8))
    }

    @Test("リンクの既定値は保存せず旧設定と未知の値も読める")
    func persistence() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(PrintFinish())
        #expect(!String(decoding: data, as: UTF8.self).contains("links"))
        for json in ["{}", "{\"links\":\"future\"}"] {
            #expect(try JSONDecoder().decode(PrintFinish.self, from: Data(json.utf8)).links == .asIs)
        }
        var finish = PrintFinish()
        finish.links = .endnotes
        #expect(try JSONDecoder().decode(PrintFinish.self, from: encoder.encode(finish)) == finish)
    }
    @Test("設定セットはリンク設定を保存し一致判定に含める")
    func settingSet() throws {
        var settings = DocumentSettings()
        var finish = PrintFinish()
        finish.links = .inline
        settings.printFinish = finish
        let set = PrintSettingSet(name: "リンク", settings: settings)
        let decoded = try JSONDecoder().decode(PrintSettingSet.self, from: JSONEncoder().encode(set))
        #expect(decoded.finish?.links == .inline)
        #expect(decoded.matches(settings))
        settings.printFinish?.links = .endnotes
        #expect(!decoded.matches(settings))
    }

}
