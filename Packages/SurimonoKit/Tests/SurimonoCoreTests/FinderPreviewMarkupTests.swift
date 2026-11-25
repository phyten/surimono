import Testing

@testable import SurimonoCore

extension FinderPreviewTests {
    @Test("タグと属性を再構成し、外部参照や能動的な要素は本文に通さない")
    func inertMarkup() throws {
        let markup = #"""
            <base href="https://example.invalid"><meta http-equiv="refresh" content="0"><link rel="stylesheet" href="sheet.css">
            <iframe>hidden-frame</iframe><object>hidden-object</object><embed src="hidden.pdf"><form>hidden-form</form>
            <a href="javascript:unused">one</a><a href="data:text/html,unused">two</a>
            <img src="missing.png" alt="diagram" srcset="remote.png 2x"><img src="missing.png">
            <p style="color:red;width:u\72l(remote.png)">paper</p>
            <svg><script>hidden-script</script><foreignObject><p>hidden-svg</p></foreignObject><circle r="4"/></svg>
            """#
        let html = try PreviewMarkup.clean(markup) { _ in nil }
        for removed in [
            "<base", "<meta", "<link", "<iframe", "<object", "<embed", "<form", "hidden-", "<script",
            "foreignobject", "srcset", "javascript:", "data:", "remote.png", "example.invalid", #"\72"#,
        ] {
            #expect(!html.lowercased().contains(removed))
        }
        for kept in ["one", "two", "diagram", "preview-missing-image", "color:red", "paper", "<circle"] {
            #expect(html.contains(kept))
        }
    }

    @Test("閉じていない引用符から画像属性やリンクを作らない")
    func brokenQuotes() throws {
        for broken in [
            "<img src='missing.png", "<a href=\"https://example.invalid>", "<img alt='broken\" src=outside.png>",
        ] {
            let html = try PreviewMarkup.clean(broken) { _ in nil }
            #expect(!html.contains("<img") && !html.contains("<a "))
        }
    }
}
