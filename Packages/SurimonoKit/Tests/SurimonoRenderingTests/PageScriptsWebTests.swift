import AppKit
import Foundation
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PageScriptsWebTests {
    private let a4 = CGSize(width: 595.28, height: 841.89)

    init() {
        _ = NSApplication.shared
    }

    private func preparationResult(of html: String, script: String) async throws -> String {
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: script)
        return try #require(result.preparationResult)
    }

    @Test("紙面の整えは追従を static に、画面の高さを auto にし、印刷の指定はそのまま残す")
    func paperCleanup() async throws {
        let html = """
            <!doctype html><meta charset="utf-8"><style>
            header { position: fixed; top: 0; } .hero { min-height: 100vh; }
            @media print { .cover { height: 100vh; } }
            </style><body><header>HEADER</header><section class="hero">HERO</section>
            <div class="cover" style="position: sticky">COVER</div><p>BODY</p></body>
            """
        let report = """
            const rule = Array.from(document.styleSheets[0].cssRules).find(rule => rule.media);
            return JSON.stringify([
              getComputedStyle(document.querySelector('header')).position,
              document.querySelector('.hero').style.minHeight || Array.from(document.styleSheets[0].cssRules)
                .find(rule => rule.selectorText === '.hero').style.minHeight,
              document.querySelector('.cover').style.position,
              rule.cssRules[0].style.height,
            ]);
            """
        let result = try await preparationResult(of: html, script: PaperCleanupScript.javaScript + "\n" + report)
        #expect(result == #"["static","auto","static","100vh"]"#)
    }

    @Test("今の状態の写しは入力と開いた折りたたみを写しの属性に残し、元の文書の既定値は変えない")
    func snapshotKeepsTheState() async throws {
        let html = """
            <!doctype html><meta charset="utf-8"><body><input id="name"><input id="agree" type="checkbox">
            <details><summary>Q</summary>ANSWER</details><textarea>first</textarea>
            <details><summary>Q2</summary>A2</details><details open><summary>Q3</summary>A3</details>
            <details><summary>Q4</summary>A4</details></body>
            """
        let script = """
            document.getElementById('name').value = 'typed';
            document.getElementById('agree').checked = true;
            document.querySelector('details').open = true;
            document.querySelector('textarea').value = 'second';
            const snapshot = await (async () => {
            \(HTMLSnapshotScript.javaScript)
            })();
            return JSON.stringify([
              snapshot, document.getElementById('name').value,
              String(document.getElementById('name').getAttribute('value')),
              String(document.getElementById('agree').hasAttribute('checked')),
              document.querySelector('textarea').defaultValue,
            ]);
            """
        let result = try await preparationResult(of: html, script: script)
        var values = try JSONDecoder().decode([String].self, from: Data(result.utf8))
        let snapshot = try #require(HTMLSnapshot(scriptResult: values[0]))
        values[0] = snapshot.html
        // The first was opened on the live page; two of the others are still closed.
        #expect(snapshot.closedDetailsCount == 2)
        #expect(values[0].hasPrefix("<!DOCTYPE html>"))
        #expect(values[0].contains(#"value="typed""#))
        #expect(values[0].contains(#"type="checkbox" checked="""#))
        #expect(values[0].contains("<details open=\"\">"))
        #expect(values[0].contains("<textarea>second</textarea>"))
        #expect(!values[0].contains("data-surimono-snapshot"))
        #expect(values[1] == "typed")
        // The live page's defaults, which a form reset returns to, stay as the document wrote them.
        #expect(values[2] == "null")
        #expect(values[3] == "false")
        #expect(values[4] == "first")
    }

    @Test("文書の JavaScript が止まっていても、@page の向きを全ページの指定と印刷の指定から読み、画面だけの指定は読まない")
    func readsPageRules() async throws {
        let html = """
            <!doctype html><meta charset="utf-8"><style>
            @page { size: A4 portrait; margin: 10mm; }
            @media print { @page { size: A4 landscape; } }
            @media screen { @page { size: 210mm 297mm; } }
            @page :first { size: letter; }
            </style><body><p>BODY</p></body>
            """
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: false,
            readsPageRules: true)
        #expect(result.pageRules.map(\.size).count == 3)
        #expect(result.pageRules.first?.size.lowercased().contains("portrait") == true)
        #expect(result.pageRules.contains { $0.selector == ":first" })
        #expect(PageRule.orientation(of: result.pageRules) == .landscape)
    }

    private func pageRules(_ css: String, extra: String = "") async throws -> [PageRule] {
        let html = """
            <!doctype html><meta charset="utf-8"><style>\(css)</style>\(extra)<body><p>BODY</p></body>
            """
        return try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: false,
            readsPageRules: true
        ).pageRules
    }

    @Test("印刷に当たる media と、使える @supports の中の @page を読み、当たらない物と無効な style sheet は読まない")
    func pageRulesFollowMediaAndSupports() async throws {
        let rules = try await pageRules(
            """
            @media screen, print { @page { size: A4 landscape; } }
            @media not print { @page { size: 210mm 297mm; } }
            @supports (display: grid) { @page :first { size: letter; } }
            @supports (foo: bar) { @page wide { size: legal; } }
            @media only print and (min-width: 1px) { @page named { size: A5; } }
            """,
            extra: #"<style media="not all">@page { size: B5; }</style>"#)
        #expect(rules.map(\.size).contains { $0.lowercased().contains("landscape") })
        #expect(!rules.map(\.size).contains { $0.contains("210mm") })
        #expect(rules.contains { $0.selector == ":first" })
        #expect(!rules.contains { $0.selector == "wide" })
        #expect(rules.contains { $0.selector == "named" })
        #expect(!rules.map(\.size).contains { $0.lowercased().contains("b5") })
    }

    @Test("無効にした style sheet の @page は読まない")
    func disabledSheetIsSkipped() async throws {
        let html = """
            <!doctype html><meta charset="utf-8"><style>@page { size: landscape; }</style>
            <style id="alt">@page { size: portrait; }</style>
            <script>document.getElementById('alt').sheet.disabled = true;</script><body><p>BODY</p></body>
            """
        let rules = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: true,
            readsPageRules: true
        ).pageRules
        #expect(rules == [PageRule(size: "landscape")])
    }

    @Test("WebKit は @page の !important を残さないので、WebKit の組版と同じく後の指定が勝つ")
    func importantPageRuleInWebKit() async throws {
        // WebKit drops the priority of @page descriptors while parsing (neither cssText nor getPropertyPriority keeps
        // it), and lays the page out the same way; PageRule.orientation(of:) honours importance when it is reported.
        let rules = try await pageRules("@page { size: A4 landscape !important; } @page { size: A4 portrait; }")
        #expect(rules.count == 2)
        #expect(rules.allSatisfy { !$0.important })
        #expect(PageRule.orientation(of: rules) == .portrait)
    }

    @Test("折りたたみを開く処理は、名前つきの組も含めてすべての details を開く")
    func opensAllDetails() async throws {
        let html = """
            <!doctype html><meta charset="utf-8"><body>
            <details name="faq"><summary>Q1</summary>A1</details><details name="faq"><summary>Q2</summary>A2</details>
            <details><summary>Q3</summary><details><summary>Q4</summary>A4</details></details></body>
            """
        let script =
            HTMLSnapshotScript.openDetailsJavaScript + """

                return String(Array.from(document.querySelectorAll('details')).filter(details => details.open).length);
                """
        #expect(try await preparationResult(of: html, script: script) == "4")
    }
}
