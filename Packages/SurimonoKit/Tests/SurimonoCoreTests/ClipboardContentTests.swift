import Foundation
import SurimonoCore
import Testing

struct ClipboardContentTests {
    @Test(
        "Markdownの印が一つあればMarkdownとして開く",
        arguments: [
            "# 見出し", "本文\n## 見出し", "- 項目", "* 項目", "1. 項目", "```swift\nlet a = 1\n```",
            "> 引用", "|---|", "| :--- | ---: |", "**強調**", "[リンク](https://example.com)", "$$x^2$$",
        ])
    func markdown(text: String) {
        #expect(ClipboardContent(text: text) == .document(data: Data(text.utf8), format: .markdown))
    }

    @Test("普通の文章はそのままテキストとして開く", arguments: ["こんにちは", "#hashtag", "2.5 kg", "a * b", "  本文\n"])
    func plainText(text: String) {
        #expect(ClipboardContent(text: text) == .document(data: Data(text.utf8), format: .plainText))
    }

    @Test(
        "HTML文書のソースはMarkdownの印があってもHTMLとして開く",
        arguments: [
            "<!doctype html><html>**text**</html>", " \n<HTML lang=\"ja\">本文</HTML>",
        ])
    func html(text: String) {
        #expect(ClipboardContent(text: text) == .document(data: Data(text.utf8), format: .html))
    }

    @Test(
        "BOMや空白や完結したコメントの後のHTMLを原文のまま開く",
        arguments: [
            "<!-- copied -->\n<!doctype html><html>本文</html>",
            "\u{FEFF} \n<!-- first -->\t<!-- second\nline -->\n<!DOCTYPE HTML><html>本文</html>",
            " \n\u{FEFF}\t<HTML lang=\"ja\">本文</HTML>",
            "<!-- **comment** --><!-- another --><html>本文</html>",
        ])
    func htmlAfterPreamble(text: String) {
        #expect(ClipboardContent(text: text) == .document(data: Data(text.utf8), format: .html))
    }

    @Test(
        "コメントだけや未完結のコメントをHTML文書とは判定しない",
        arguments: [
            "<!-- comment -->", "\u{FEFF} <!-- first -->\n<!-- second --> ",
            "<!-- <!doctype html> -->", "<!-- unfinished\n<!doctype html><html>本文</html>",
            "本文<!-- comment --><html>本文</html>",
        ])
    func commentsAreNotHTML(text: String) {
        #expect(ClipboardContent(text: text) == .document(data: Data(text.utf8), format: .plainText))
    }

    @Test(
        "単語の境界の二重アンダースコアはMarkdownの強調と判定する",
        arguments: ["__強調__", "本文 __強調__ 本文", "(__強調__)", "__two words__"])
    func underscoreEmphasis(text: String) {
        #expect(ClipboardContent(text: text) == .document(data: Data(text.utf8), format: .markdown))
    }

    @Test(
        "単語中のアンダースコアや空白を挟む区切りは普通のテキストのままにする",
        arguments: ["snake_case_name", "a__b", "a__b__c", "__word__suffix", "prefix__word__", "__ space __"])
    func underscoresInWords(text: String) {
        #expect(ClipboardContent(text: text) == .document(data: Data(text.utf8), format: .plainText))
    }

    @Test(
        "チルダのコードフェンスはMarkdownと判定する",
        arguments: ["~~~\ncode\n~~~", "本文\n~~~swift\nlet a = 1\n~~~", "  ~~~~\ncode\n~~~~"])
    func tildeFence(text: String) {
        #expect(ClipboardContent(text: text) == .document(data: Data(text.utf8), format: .markdown))
    }

    @Test("ファイルURLは文字列と画像より優先する")
    func files() {
        let urls = [URL(fileURLWithPath: "/fixtures/a.md"), URL(fileURLWithPath: "/fixtures/b.md")]
        #expect(ClipboardContent(fileURLs: urls, text: "text", png: Data([1])) == .files(urls))
    }

    @Test("文字列は画像より優先する")
    func textBeforeImage() {
        #expect(
            ClipboardContent(text: "text", png: Data([1])) == .document(data: Data("text".utf8), format: .plainText))
    }

    @Test("空白だけの文字列は画像があっても開けない", arguments: ["", " \n\t", "　"])
    func whitespace(text: String) {
        #expect(ClipboardContent(text: text, png: Data([1])) == .empty)
    }

    @Test("文字列がなければPNGをTIFFより優先する")
    func png() {
        #expect(ClipboardContent(png: Data([1]), tiff: Data([2])) == .document(data: Data([1]), format: .image))
    }

    @Test("TIFFだけでも画像として開く")
    func tiff() {
        #expect(ClipboardContent(tiff: Data([2])) == .document(data: Data([2]), format: .image))
    }

    @Test("流し込まれる文字は印がなくても Markdown として読む", arguments: ["こんにちは", "# 見出し", "<p>断片</p>"])
    func streamedMarkdown(text: String) {
        #expect(ClipboardContent.streaming(text: text) == .document(data: Data(text.utf8), format: .markdown))
    }

    @Test("流し込まれた HTML 文書は HTML として読む")
    func streamedHTML() {
        let text = "<!doctype html><html>本文</html>"
        #expect(ClipboardContent.streaming(text: text) == .document(data: Data(text.utf8), format: .html))
    }

    @Test("流し込まれた文字が空か空白だけなら何もしない", arguments: [nil, "", " \n"] as [String?])
    func streamedNothing(text: String?) {
        #expect(ClipboardContent.streaming(text: text) == .empty)
    }

    @Test("メモリ上の文書は形式と中身に合う拡張子で保存する")
    func fileExtensions() {
        #expect(ClipboardContent.fileExtension(of: Data("# a".utf8), format: .markdown) == "md")
        #expect(ClipboardContent.fileExtension(of: Data("a".utf8), format: .plainText) == "txt")
        #expect(ClipboardContent.fileExtension(of: Data("<html>".utf8), format: .html) == "html")
        #expect(ClipboardContent.fileExtension(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D]), format: .image) == "png")
        #expect(ClipboardContent.fileExtension(of: Data([0x4D, 0x4D, 0x00, 0x2A]), format: .image) == "tiff")
    }

    @Test("何もなければ開けない")
    func empty() {
        #expect(ClipboardContent() == .empty)
    }
}
