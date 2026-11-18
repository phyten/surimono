import Testing

@testable import SurimonoCore

struct DocumentDirectivesTests {
    @Test("印刷指示の全項目と引用符を読む")
    func allKeys() {
        let value = DocumentDirectives.read(
            fromMarkdown:
                "---\ntitle: 議事録\nsurimono:\n  set: '配布用'\n  layout: a4BookletA5\n  orientation: landscape\n  margins: 15mm\n  style: \"standard\"\n  text-size: 110%\n---\n本文"
        )
        #expect(value.metadata.title == "議事録")
        #expect(value.setName == "配布用")
        #expect(value.layoutID == "a4BookletA5")
        #expect(value.orientation == .landscape)
        #expect(value.marginMillimeters == 15)
        #expect(value.style == "standard")
        #expect(value.textScale == 1.1)
        #expect(!value.isEmpty)
    }

    @Test(
        "余白の単位をミリに揃える",
        arguments: [
            ("1.5cm", 15.0), ("0.5in", 12.7), ("15", 15.0), ("0mm", 0.0), ("50mm", 50.0), ("12.5mm", 12.5),
        ])
    func margins(_ pair: (String, Double)) {
        #expect(read("margins: \(pair.0)").marginMillimeters == pair.1)
    }

    @Test(
        "文字倍率は 1% 刻みにして範囲に収める",
        arguments: [("110%", 1.1), ("1.1", 1.1), ("20%", 0.8), ("500%", 2.0), ("113%", 1.13), ("112.6%", 1.13)])
    func scales(_ pair: (String, Double)) {
        #expect(read("text-size: \(pair.0)").textScale == pair.1)
    }

    @Test("文献や表題だけの変更では印刷設定を戻さない")
    func changesToMetadata() {
        let before = DocumentDirectives.read(fromMarkdown: "---\ntitle: One\n---")
        let after = DocumentDirectives.read(fromMarkdown: "---\ntitle: Two\nbibliography: refs.bib\n---")
        #expect(after.isEmpty)
        #expect(before.hasSamePrintSettings(as: after))
        #expect(!read("margins: 10mm").hasSamePrintSettings(as: after))
    }

    @Test("未知の項目と読めない値を無視する")
    func invalid() {
        #expect(read("margins: 51mm\n  text-size: nan\n  orientation: sideways\n  unknown: value").isEmpty)
        #expect(read("margins: -1\n  text-size: infinity").isEmpty)
        #expect(read("# comment\n  style: standard").style == "standard")
    }

    @Test("前付け以外とスカラーの指示を読まない")
    func boundaries() {
        for text in [
            "surimono:\n  style: standard", "---\nこれは文章\nsurimono:\n  style: standard\n---",
            "---\nsurimono: ignored\n  style: standard\n---",
        ] {
            #expect(DocumentDirectives.read(fromMarkdown: text).isEmpty)
        }
        #expect(MarkdownConverter.convert("---\nsurimono:\n  style: standard\n---\n本文").body == "<p>本文</p>\n")
    }

    private func read(_ lines: String) -> DocumentDirectives {
        DocumentDirectives.read(fromMarkdown: "---\nsurimono:\n  \(lines)\n---")
    }
}
