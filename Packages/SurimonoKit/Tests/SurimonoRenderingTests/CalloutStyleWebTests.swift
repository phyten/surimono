import AppKit
import Foundation
import SurimonoCore
import SurimonoRendering
import Testing

/// Reads the cascade itself in WebKit, for what depends on a theme's own selectors and cannot be computed from its CSS.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CalloutStyleWebTests {
    private let a4 = CGSize(width: 595.28, height: 841.89)

    init() {
        _ = NSApplication.shared
    }

    private func report(markdown: String, script: String) async throws -> String {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let html = HTMLDocumentBuilder.build(
            fragment: MarkdownConverter.convert(markdown), format: .markdown, theme: standard)
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: script)
        return try #require(result.preparationResult)
    }

    private func sheets() throws -> String {
        let themes = try PrintThemeLibrary.load().filter(\.isBuiltIn).map { [$0.id, $0.css] }
        return String(decoding: try JSONEncoder().encode(themes), as: UTF8.self)
    }

    @Test("全テーマの札の中のリンク・強調・コードは札の文字色のまま地を持たない")
    func inlineMarkupKeepsTheTagInk() async throws {
        let title = "[リンク](https://example.com) **強調** *斜体* `コード` ==印=="
        let markdown = ["note", "tip", "warning", "danger", "quote", "recipe"]
            .map { "> [!\($0)] \(title)\n> 本文\n" }.joined(separator: "\n")
        let script = """
            const style = document.querySelector('style');
            const failures = [];
            let checked = 0;
            for (const [id, css] of \(try sheets())) {
              style.textContent = css;
              for (const title of document.querySelectorAll('.callout > .callout-title')) {
                const ink = getComputedStyle(title).color;
                for (const element of title.querySelectorAll('a, strong, em, code, mark')) {
                  const computed = getComputedStyle(element);
                  checked += 1;
                  if (computed.color !== ink || computed.backgroundColor !== 'rgba(0, 0, 0, 0)') {
                    failures.push(id + ' ' + title.parentElement.dataset.callout + ' ' + element.localName);
                  }
                }
              }
            }
            return JSON.stringify({ checked, failures });
            """
        let result = try await report(markdown: markdown, script: script)
        // 108 themes, 6 callouts and 5 kinds of markup.
        #expect(result == #"{"checked":3240,"failures":[]}"#)
    }

    @Test("以前のクラスを併記した囲みは群の見た目になり、以前のクラスだけの HTML は注意の見た目になる")
    func compatibilityClass() async throws {
        let markdown = """
            :::important 表題
            本文
            :::

            :::example 表題
            本文
            :::

            <div class="callout callout-important"><p>本文</p></div>
            """
        let script = """
            const line = element => getComputedStyle(element, '::before').borderTopStyle;
            const color = element => getComputedStyle(element, '::before').borderTopColor;
            const [important, example, raw] = document.querySelectorAll('.callout');
            return JSON.stringify([line(important), line(example), line(raw), color(raw) === color(important)]);
            """
        #expect(try await report(markdown: markdown, script: script) == #"["dashed","solid","dashed",true]"#)
    }

    @Test("札のない囲みは枠を箱の上端から描き、本文を線に重ねない")
    func calloutWithoutTitle() async throws {
        let script = """
            const callout = document.querySelector('.callout');
            const paragraph = callout.querySelector('p').getBoundingClientRect();
            return JSON.stringify([
              getComputedStyle(callout, '::before').top,
              paragraph.top > callout.getBoundingClientRect().top,
            ]);
            """
        #expect(try await report(markdown: ":::message\n本文\n:::", script: script) == #"["0px",true]"#)
    }

    @Test("レシピカードで名前を隠すのは recipe の札だけで、入れ子の未知の名前は隠さない")
    func recipeCardHidesOnlyItsOwnName() async throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "recipecard" })
        let css = String(decoding: try JSONEncoder().encode(theme.css), as: UTF8.self)
        let script = """
            document.querySelector('style').textContent = \(css);
            return JSON.stringify(
              Array.from(document.querySelectorAll('.callout-name')).map(name => getComputedStyle(name).display));
            """
        let markdown = "::::recipe 表題\n:::other 内側\n本文\n:::\n::::"
        #expect(try await report(markdown: markdown, script: script) == #"["none","inline"]"#)
    }
}
