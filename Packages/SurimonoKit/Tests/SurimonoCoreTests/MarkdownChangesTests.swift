import Foundation
import Testing

@testable import SurimonoCore

struct MarkdownChangesTests {
    @Test("LCSは挿入による行ずれを変更と誤認しない")
    func lineDiff() throws {
        let changes = try #require(MarkdownChanges.lines(from: "a\nb\nc\nb", to: "a\nx\nb\nc\nb"))
        #expect(changes.inserted == [2])
        #expect(changes.deletions.isEmpty)
        #expect(MarkdownChanges.lines(from: "a\r\nb", to: "a\nb")?.inserted.isEmpty == true)
        #expect(MarkdownChanges.marks(from: "same", to: "same").isEmpty)
    }

    @Test("差分の計算量と入力の上限を超えたら印を省く")
    func cap() {
        #expect(MarkdownChanges.lines(from: "a\nb", to: "a\nc", cellLimit: 8) == nil)
        #expect(MarkdownChanges.marks(from: "a\nb", to: "a\nc", cellLimit: 8).isEmpty)
        #expect(MarkdownChanges.lines(from: "a", to: String(repeating: "x", count: 2_000_001)) == nil)
    }

    @Test("前付けと脚注の取り出し後も段落は元の行を指す")
    func frontMatterAndFootnote() throws {
        let text = "---\ntitle: Title\n---\n# Heading\n\nBody [^a]\n\n[^a]: Note\n    continued\n\nLast"
        let document = MarkdownConverter.convertWithSourceMap(text)
        #expect(document.blocks.contains { $0.lines == [4] })
        #expect(document.blocks.contains { $0.lines == [6] })
        #expect(document.blocks.contains { $0.lines == [8, 9] })
        #expect(document.blocks.contains { $0.lines == [11] })
        let requests = MarkdownChanges.marks(from: text, to: text.replacingOccurrences(of: "continued", with: "edited"))
        let mark = try #require(requests.only)
        let edited = MarkdownConverter.convertWithSourceMap(text.replacingOccurrences(of: "continued", with: "edited"))
        #expect(edited.blocks.first { $0.id == mark.blockID }?.lines == [8, 9])
        #expect(!mark.isShort)
    }

    @Test("複数行数式の短縮と囲みの展開を経ても本文の行を失わない")
    func mathAndCallout() {
        let text = "$$\nx +\ny\n$$\n\nAfter\n\n:::note Title\nInside\n:::"
        let document = MarkdownConverter.convertWithSourceMap(text)
        #expect(document.blocks.contains { $0.lines == [1, 2, 3, 4] })
        #expect(document.blocks.contains { $0.lines == [6] })
        #expect(document.blocks.contains { $0.lines == [8, 9, 10] })
        #expect(document.blocks.contains { $0.lines == [9] })
        let changed = text.replacingOccurrences(of: "Inside", with: "Changed")
        let blocks = MarkdownConverter.convertWithSourceMap(changed).blocks
        let marks = MarkdownChanges.marks(from: text, to: changed)
        #expect(marks.count == 1)
        #expect(blocks.first { $0.id == marks.first?.blockID }?.lines == [9])
    }

    @Test("リスト項目と引用内の段落は親と重複せず内側だけを示す")
    func nestedBlocks() throws {
        let old = "- outer\n  - inner\n\n> quoted\n>\n> second"
        let new = old.replacingOccurrences(of: "inner", with: "edited").replacingOccurrences(
            of: "second", with: "changed")
        let mapped = MarkdownConverter.convertWithSourceMap(new)
        let marks = MarkdownChanges.marks(from: old, to: new)
        #expect(marks.count == 2)
        let ranges = marks.compactMap { request in mapped.blocks.first { $0.id == request.blockID }?.lines }
        #expect(ranges.contains([2]))
        #expect(ranges.contains([6]))
    }

    @Test("引用形式の囲みはタイトルを除いた本文の段落へ対応付ける")
    func quoteCallout() throws {
        let old = "> [!note] Title\n> Body"
        let new = "> [!note] Title\n> Edited"
        let document = MarkdownConverter.convertWithSourceMap(new)
        let mark = try #require(MarkdownChanges.marks(from: old, to: new).only)
        #expect(document.blocks.first { $0.id == mark.blockID }?.lines == [2])
    }

    @Test("削除だけなら次のブロックを短く示し末尾では前を示す")
    func deletion() throws {
        let old = "First\n\nRemoved\n\nLast"
        let new = "First\n\nLast"
        let blocks = MarkdownConverter.convertWithSourceMap(new).blocks
        let middle = try #require(MarkdownChanges.marks(from: old, to: new).only)
        #expect(middle.isShort)
        #expect(blocks.first { $0.id == middle.blockID }?.lines == [3])
        let end = try #require(MarkdownChanges.marks(from: new, to: "First").only)
        #expect(end.isShort)
        #expect(end.blockID == MarkdownConverter.convertWithSourceMap("First").blocks.first?.id)
    }

    @Test("ブロックIDは決定的で無関係な前置きによって変わらず同じ本文の重複は区別する")
    func stableIDs() {
        let original = MarkdownConverter.convertWithSourceMap("One\n\nTwo\n\nTwo")
        let again = MarkdownConverter.convertWithSourceMap("One\n\nTwo\n\nTwo")
        let inserted = MarkdownConverter.convertWithSourceMap("Zero\n\nOne\n\nTwo\n\nTwo")
        #expect(original.blocks.map(\.id) == again.blocks.map(\.id))
        #expect(original.blocks.map(\.id) == Array(inserted.blocks.dropFirst()).map(\.id))
        #expect(Set(original.blocks.map(\.id)).count == 3)
    }

    @Test(
        "対応付けの属性以外は通常のHTMLを変えない",
        arguments: [
            "# Heading\n\nParagraph ==highlight== {漢字|かんじ} :smile:",
            "- first\n- second\n\n> quote\n\n---\n\n```swift\nlet a = 1\n```",
            "| A | B |\n|---|---|\n| a | b |", ":::note Title\nBody\n:::",
            "Body [^a]\n\n[^a]: Note\n    continued", "$$\nx + y\n$$\n\nEnd",
            "Term\n: Definition\n\nAnother\n\n: Loose definition",
        ])
    func unchangedHTML(text: String) {
        let mapped = MarkdownConverter.convertWithSourceMap(text)
        let stripped = mapped.fragment.body.replacingOccurrences(
            of: #" data-surimono-block="[^"]+""#, with: "", options: .regularExpression)
        #expect(stripped == MarkdownConverter.convert(text).body)
        #expect(!mapped.blocks.isEmpty)
        #expect(!mapped.fragment.body.contains("surimono-mark:"))
    }
}

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
