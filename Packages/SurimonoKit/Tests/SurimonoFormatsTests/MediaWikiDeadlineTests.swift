import Foundation
import Synchronization
import Testing

@testable import SurimonoFormats

struct MediaWikiDeadlineTests {
    private func expiring(after polls: Int) -> PreviewConversion {
        let start = ContinuousClock.now
        let deadline = start + .seconds(5)
        let count = Mutex(0)
        return PreviewConversion(deadline: deadline) {
            count.withLock {
                $0 += 1
                return $0 >= polls ? deadline : start
            }
        }
    }

    @Test("一致のない正規表現も探索の途中で期限を検知し、未処理の末尾を返さない")
    func noMatchProgress() {
        let pattern = WikiPattern("[ab][0-9]")
        let text = String(repeating: "ab ", count: 32_768)
        let start = ContinuousClock.now
        let deadline = start + .seconds(5)
        let polls = Mutex(0)
        let request = PreviewConversion(deadline: deadline) {
            polls.withLock {
                $0 += 1
                return $0 >= 4 ? deadline : start
            }
        }
        let result = PreviewConversion.$current.withValue(request) {
            pattern.replace(text) { _ in
                Issue.record("一致しないはずの文字列")
                return ""
            }
        }
        #expect(result.isEmpty)
        // A scan that merely suppresses its result would keep delivering progress callbacks.
        #expect(polls.withLock { (4...6).contains($0) })
    }

    @Test("閉じていない外部リンクの末尾に空白が3万個あっても、期限なしで速やかに読み終える")
    func unclosedExternalLink() {
        let url = "https://example.test"
        let spaces = String(repeating: " ", count: 30_000)
        let text = "[" + url + spaces
        let reader = WikiReader(directory: nil, imageExists: { _ in false })
        let start = ContinuousClock.now
        let html = reader.inline(text)
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(html == "[<a href=\"\(url)\">\(url)</a>" + spaces)
        let interrupted = PreviewConversion.$current.withValue(expiring(after: 4)) { reader.inline(text) }
        #expect(interrupted.isEmpty)
    }

    @Test("深さ上限を超えた表を原文に戻す途中でも、残りの行を走査せずに打ち切る")
    func deepTable() {
        let reader = WikiReader(directory: nil, imageExists: { _ in false })
        let lines = ["{|"] + Array(repeating: "| paper", count: 8192) + ["|}"]
        var index = 0
        let result = PreviewConversion.$current.withValue(expiring(after: 10)) {
            reader.table(lines, at: &index, opening: "{|", nesting: 32)
        }
        #expect(index > 1 && index < lines.count)
        #expect(result.isEmpty)
    }

    @Test("一行に多数の空セルが続く表をセルの処理中に打ち切る")
    func emptyCells() {
        let reader = WikiReader(directory: nil, imageExists: { _ in false })
        let lines = ["|" + String(repeating: "||", count: 8192)]
        var index = 0
        let result = PreviewConversion.$current.withValue(expiring(after: 10)) {
            reader.table(lines, at: &index, opening: "{|", nesting: 0)
        }
        #expect(index == 1 && result.isEmpty)
    }

    @Test("テンプレートの名前付き引数や表示対象外の引数を走査中にも期限を検知する", arguments: ["cite web", "Box"])
    func templateFields(_ name: String) {
        let reader = WikiReader(directory: nil, imageExists: { _ in false })
        let text = name + "|title=Paper" + String(repeating: "|unused", count: 8192)
        let result = PreviewConversion.$current.withValue(expiring(after: 12)) {
            reader.template(text, block: true)
        }
        #expect(result.isEmpty)
    }

    @Test("一行に多数の強調記号があるとき、本文を出す途中で打ち切る")
    func emphasisDeadline() {
        expectDeadlineDuringRendering { reader, marker in
            let words = String(repeating: "''paper'' ", count: 512)
            return reader.inline(words + marker + words)
        }
    }

    @Test("多数の関連記事を参照するテンプレートを引数の表示途中で打ち切る")
    func relatedArticlesDeadline() {
        expectDeadlineDuringRendering { reader, marker in
            let args = String(repeating: "|paper", count: 512)
            return reader.template("See also" + args + "|" + marker + args, block: true)
        }
    }

    private func expectDeadlineDuringRendering(_ render: (WikiReader, String) -> String) {
        let start = ContinuousClock.now
        let deadline = start + .seconds(5)
        let reachedImage = Mutex(false)
        let request = PreviewConversion(deadline: deadline) { reachedImage.withLock { $0 ? deadline : start } }
        // The image lookup advances the clock only after parsing has reached the middle of the rendered sequence.
        let reader = WikiReader(directory: URL(fileURLWithPath: "/", isDirectory: true)) { _ in
            reachedImage.withLock { $0 = true }
            return true
        }
        let marker = reader.atom("link", "File:marker.svg")
        let result = PreviewConversion.$current.withValue(request) { render(reader, marker) }
        #expect(reachedImage.withLock { $0 })
        #expect(result.isEmpty)
    }
}
