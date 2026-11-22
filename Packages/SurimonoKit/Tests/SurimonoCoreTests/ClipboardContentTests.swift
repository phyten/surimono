import Foundation
import SurimonoCore
import Testing

struct ClipboardContentTests {
    @Test(
        "文字は形式を決めずに原文のまま判定へ渡す",
        arguments: ["# 見出し", "こんにちは", "<!doctype html><html>**text**</html>", "  本文\n", "a\tb\n1\t2"])
    func textIsLeftToTheDetector(text: String) {
        #expect(ClipboardContent(text: text) == .text(text, hints: .init()))
    }

    @Test("クリップボードの型からの手がかりを文字と一緒に渡す")
    func hints() {
        let hints = ClipboardFormatHints(hasMatchingURL: true, hasTabularData: true)
        #expect(
            ClipboardContent(text: "https://example.com", hints: hints) == .text("https://example.com", hints: hints))
    }

    @Test(
        "流し込まれた BOM や空白や完結したコメントの後の HTML 文書は HTML として読む",
        arguments: [
            "<!doctype html><html>**text**</html>", " \n<HTML lang=\"ja\">本文</HTML>",
            "<!-- copied -->\n<!doctype html><html>本文</html>",
            "\u{FEFF} \n<!-- first -->\t<!-- second\nline -->\n<!DOCTYPE HTML><html>本文</html>",
            " \n\u{FEFF}\t<HTML lang=\"ja\">本文</HTML>",
            "<!-- **comment** --><!-- another --><html>本文</html>",
        ])
    func streamedHTMLAfterPreamble(text: String) {
        #expect(ClipboardContent.streaming(text: text) == .document(data: Data(text.utf8), format: .html))
    }

    @Test(
        "流し込まれたコメントだけや未完結のコメントは HTML 文書とせず Markdown として読む",
        arguments: [
            "<!-- comment -->", "\u{FEFF} <!-- first -->\n<!-- second --> ",
            "<!-- <!doctype html> -->", "<!-- unfinished\n<!doctype html><html>本文</html>",
            "本文<!-- comment --><html>本文</html>",
        ])
    func streamedCommentsAreNotHTML(text: String) {
        #expect(ClipboardContent.streaming(text: text) == .document(data: Data(text.utf8), format: .markdown))
    }

    @Test("ファイルURLは文字列と画像より優先する")
    func files() {
        let urls = [URL(fileURLWithPath: "/fixtures/a.md"), URL(fileURLWithPath: "/fixtures/b.md")]
        #expect(ClipboardContent(fileURLs: urls, text: "text", png: Data([1])) == .files(urls))
    }

    @Test("文字列は画像より優先する")
    func textBeforeImage() {
        #expect(
            ClipboardContent(text: "text", png: Data([1])) == .text("text", hints: .init()))
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

    @Test(
        "先頭の目印に形式があれば、目印を外してその形式で読む",
        arguments: [
            ("<!--format: org-->\n* 見出し", DocumentFormat.org, "* 見出し"),
            ("\u{FEFF} <!-- FORMAT:Org -->\n\n* 見出し", .org, "* 見出し"),
            ("<!--\nsource: Emacs\nformat: latex\n-->\n\\section{a}", .latex, "\\section{a}"),
            ("<!--format: asciidoc-->\n= 題", .asciidoc, "= 題"),
            ("<!--format: reStructuredText-->\nMill\n===", .rst, "Mill\n==="),
            ("<!--format: mediawiki-->\n== 題 ==", .mediawiki, "== 題 =="),
            ("<!--format: text-->\n# そのまま", .plainText, "# そのまま"),
            ("<!--format: qmd-->\n# 題", .quarto, "# 題"),
            ("<!--format: markdown-->\n<!doctype html><html></html>", .markdown, "<!doctype html><html></html>"),
        ] as [(String, DocumentFormat, String)])
    func streamedFormatHint(text: String, format: DocumentFormat, body: String) {
        #expect(ClipboardContent.streaming(text: text) == .document(data: Data(body.utf8), format: format))
    }

    @Test(
        "知らない形式や文字でない形式の目印は外すだけで、いつもの読み方をする",
        arguments: [
            ("<!--format: fountain-->\n# 題", DocumentFormat.markdown, "# 題"),
            ("<!--source: Bear.app-->\n# 題", .markdown, "# 題"),
            ("<!--format: pdf-->\n# 題", .markdown, "# 題"),
            ("<!--format: docx-->\n<!doctype html><html></html>", .html, "<!doctype html><html></html>"),
        ] as [(String, DocumentFormat, String)])
    func streamedUnknownHint(text: String, format: DocumentFormat, body: String) {
        #expect(ClipboardContent.streaming(text: text) == .document(data: Data(body.utf8), format: format))
    }

    @Test("目印だけで本文がまだないあいだは何もしない", arguments: ["<!--format: org-->", "<!--format: org-->\n \n"])
    func streamedHintOnly(text: String) {
        #expect(ClipboardContent.streaming(text: text) == .empty)
    }

    @Test("形式の行だけでできていないコメントは目印として扱わない")
    func streamedOrdinaryComment() {
        let text = "<!-- format: org のつもりの覚え書き\nほかの行 -->\n# 題"
        #expect(ClipboardContent.streaming(text: text) == .document(data: Data(text.utf8), format: .markdown))
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
        #expect(ClipboardContent.fileExtension(of: Data("* a".utf8), format: .org) == "org")
        #expect(ClipboardContent.fileExtension(of: Data("\\section{a}".utf8), format: .latex) == "tex")
        #expect(ClipboardContent.fileExtension(of: Data("a,b\n1,2".utf8), format: .csv) == "csv")
        #expect(ClipboardContent.fileExtension(of: Data("a\tb\n1\t2".utf8), format: .csv) == "tsv")
        #expect(ClipboardContent.fileExtension(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D]), format: .image) == "png")
        #expect(ClipboardContent.fileExtension(of: Data([0x4D, 0x4D, 0x00, 0x2A]), format: .image) == "tiff")
    }

    @Test("何もなければ開けない")
    func empty() {
        #expect(ClipboardContent() == .empty)
    }
}
