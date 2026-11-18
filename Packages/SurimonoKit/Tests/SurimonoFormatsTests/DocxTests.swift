import Foundation
import Testing
import UniformTypeIdentifiers

@testable import SurimonoFormats

struct DocxTests {
    private var sample: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "../../../../Samples/sample.docx"
        ).standardizedFileURL
    }

    @Test("見本の構造と日本語をテーマ用の本文に残す")
    func converts() throws {
        let fragment = try DocxConverter.convert(Data(contentsOf: sample))
        #expect(fragment.title == "印刷の手引き / Print guide")
        #expect(fragment.language == "ja-JP")
        for marker in [
            "org-title-block", "<h2 id=", "<strong>", "<em>", "<thead>", "colspan=\"2\"", "<ul>", "<ol start=\"4\">",
            "data:image/png;base64,", "<blockquote>", "<figcaption>", "<pre><code>", "page-break",
            "class=\"footnotes\"", "注の本文",
        ] {
            #expect(fragment.body.contains(marker), "見本に \(marker) がある")
        }
    }

    @Test("書誌情報とスタイルを読み、変更履歴の削除・コメント・数式を除く")
    func structure() throws {
        let url = try #require(
            Bundle.module.url(forResource: "word-structure", withExtension: "docx", subdirectory: "Fixtures"))
        let fragment = try DocxConverter.convert(Data(contentsOf: url))
        #expect(fragment.title == "Metadata title")
        #expect(fragment.language == nil)
        for marker in [
            "org-subtitle", "org-author", "org-date", "<blockquote>", "<pre><code>x &lt; y", "<code>inline code",
            "<u>underline", "<s>strike", "<mark>highlight", "<sup>sup", "<sub>sub", "first-heading-1",
            "id=\"target\"", "href=\"#target\"", "href=\"https://example.org/\"", "InsertedText", "末尾の注",
            "<caption>表の題</caption>", "rowspan=\"2\"", "docx-image-note", "図の説明", "古い図の説明", "TextBoxHeading",
            "p class=\"abstract\"",
        ] {
            #expect(fragment.body.contains(marker), "変換結果に \(marker) がある")
        }
        for omitted in [
            "Metadata title", "CreatorSentinel", "CommentSentinel", "MathSentinel", "DeletedText",
            "javascript:", "data:image/x-emf", "↑",
        ] { #expect(!fragment.body.contains(omitted)) }
    }

    @Test("注を初出順で振り直し戻りリンクを除く")
    func notes() throws {
        let body = try DocxConverter.convert(Data(contentsOf: sample)).body
        #expect(body.contains("<li id=\"fn-1\"><p>注の本文 2"))
        #expect(body.contains("<li id=\"fn-2\"><p>注の本文 1"))
        #expect(!body.contains("footnote-ref-"))
        #expect(!body.contains("↑"))
        #expect(body.contains("両面にする<ul><li>入れ子の項目"))
    }

    @Test("書き換えでスクリプト・イベント属性・実行可能なリンクを除く")
    func sanitized() throws {
        let source = #"<p onclick="go()">本文<script>hidden()</script><a href="JaVa&#x09;ScRiPt:go()">リンク</a></p>"#
        #expect(try PrintMarkup.fragment(source, format: .docx).body == "<p>本文<a>リンク</a></p>")
    }

    @Test("複数の変換が同じ実行環境で状態を混同しない")
    func concurrent() async throws {
        let bytes = try Data(contentsOf: sample)
        async let first = DocxConverter.convert(bytes)
        async let second = DocxConverter.convert(bytes)
        let results = try await (first, second)
        #expect(results.0 == results.1)
    }

    @Test("ZIPではないファイルとWord本文のないZIPを拒む")
    func invalid() {
        for bytes in [Data([0xd0, 0xcf]), Data([0x50, 0x4b, 5, 6] + Array(repeating: 0, count: 18))] {
            #expect(throws: DocxError.invalidDocument) { try DocxConverter.convert(bytes) }
        }
    }

    @Test("暗号化文書と旧Word形式のコンテナにはdocxを案内する")
    func encrypted() throws {
        let ole = Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
        #expect(throws: DocxError.encryptedOrLegacy) { try DocxConverter.convert(ole) }
        var bytes = try Data(contentsOf: sample)
        let header = try #require(bytes.range(of: Data([0x50, 0x4b, 1, 2]))).lowerBound
        bytes[header + 8] |= 1
        #expect(throws: DocxError.encryptedOrLegacy) { try DocxConverter.convert(bytes) }
    }

    @Test("圧縮前後の上限を超える文書を変換前に拒む")
    func limits() throws {
        #expect(throws: DocxError.tooLarge) { try DocxConverter.convert(Data(count: 50_000_001)) }
        var bytes = try Data(contentsOf: sample)
        let header = try #require(bytes.range(of: Data([0x50, 0x4b, 1, 2]))).lowerBound
        bytes.replaceSubrange(header + 24..<header + 28, with: [0, 0, 0, 32])
        #expect(throws: DocxError.tooLarge) { try DocxConverter.convert(bytes) }
    }

    @Test("ポンプの上限で中断した後も別の文書を変換できる")
    func bounded() throws {
        let bytes = try Data(contentsOf: sample)
        #expect(throws: DocxError.conversionFailed) { try DocxConverter.convert(bytes, maximumRounds: 0) }
        #expect(try DocxConverter.convert(bytes).title != nil)
    }
}
