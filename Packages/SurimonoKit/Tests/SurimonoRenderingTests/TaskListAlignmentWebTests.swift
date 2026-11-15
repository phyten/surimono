import AppKit
import Foundation
import SurimonoCore
import SurimonoRendering
import Testing

/// Measures in WebKit where a task item's lines start, which depends on each theme's box rules and font.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TaskListAlignmentWebTests {
    private let a4 = CGSize(width: 595.28, height: 841.89)

    init() {
        _ = NSApplication.shared
    }

    @Test("全テーマで、折り返したタスクの項目は 1 行目と折り返した行の左端がそろう")
    func wrappedTaskItemsStartAtTheSameEdge() async throws {
        let long = "折り返した行と同じ左端から始まるように、日本語の文と English words を混ぜた長い項目を書いておく。"
        let latin = "Latin text comes first in this item, mixed with 日本語の文字, so that it wraps onto a second line."
        let markdown = """
            - [ ] \(long)\(long)
            - [x] \(latin) \(latin)
              - [ ] \(long)\(long)

            区切りの段落

            - [ ] \(long)\(long)

            - [x] \(latin) \(latin)
            """
        // Haiku centres every line, so its wrapped lines start wherever their length puts them.
        let themes = try PrintThemeLibrary.load().filter { $0.isBuiltIn && $0.id != "haiku" }
        let sheets = themes.map { [$0.id, HTMLDocumentBuilder.styleSheet(theme: $0)] }
        let script = """
            const style = document.querySelector('style');
            const failures = [];
            let checked = 0;
            for (const [id, css] of \(String(decoding: try JSONEncoder().encode(sheets), as: UTF8.self))) {
              style.textContent = css;
              await document.fonts.ready;
              for (const box of document.querySelectorAll('li.task-list-item input[type="checkbox"]')) {
                const text = box.nextSibling;
                const range = document.createRange();
                range.setStart(text, text.textContent.search(/\\S/));
                range.setEnd(text, text.textContent.length);
                const lines = Array.from(range.getClientRects()).filter(rect => rect.width > 0);
                const first = lines[0];
                const wrapped = lines.find(rect => rect.top >= first.bottom - 1);
                checked += 1;
                if (!wrapped || Math.abs(first.left - wrapped.left) > 0.5) {
                  const kind = box.parentElement.localName === 'p' ? 'loose' : 'tight';
                  failures.push([id, kind, first.left, wrapped ? wrapped.left : 'no wrap'].join(' '));
                }
              }
            }
            return JSON.stringify({ checked, failures });
            """
        let html = HTMLDocumentBuilder.build(
            fragment: MarkdownConverter.convert(markdown), format: .markdown, theme: themes[0])
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: a4, margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: script)
        // Five task items for each theme: 3 in the tight list, one of them nested, and 2 in the loose one. The count
        // follows the themes, so that adding a theme does not fail a test about alignment.
        #expect(themes.count > 90)
        #expect(result.preparationResult == #"{"checked":\#(themes.count * 5),"failures":[]}"#)
    }
}
