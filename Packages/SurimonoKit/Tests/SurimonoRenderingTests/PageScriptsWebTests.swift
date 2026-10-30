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
            <details><summary>Q</summary>ANSWER</details><textarea>first</textarea></body>
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
        let values = try JSONDecoder().decode([String].self, from: Data(result.utf8))
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
}
