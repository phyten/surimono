import Foundation
import SurimonoCore
import Testing

/// Opt-in timing of the writing check (`make bench-prose`). It records and judges nothing in an ordinary test run.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_BENCH_PROSE"] == "1"), .serialized)
struct ProseCheckBenchmarks {
    @Test("文章の点検の時間を測る", .timeLimit(.minutes(10)))
    func record() throws {
        let runs = try #require(Int(ProcessInfo.processInfo.environment["SURIMONO_BENCH_RUNS"] ?? "40"))
        try #require(runs > 0)
        let inputs: [(String, String, DocumentFormat)] = [
            ("japanese-20k", Self.japanese(characters: 20_000), .markdown),
            ("japanese-200k", Self.japanese(characters: 200_000), .markdown),
            ("english-20k-words", Self.english(words: 20_000), .markdown),
            ("mixed-20k", Self.japanese(characters: 10_000) + Self.english(words: 2_000), .markdown),
            ("plain-japanese-20k", Self.japanese(characters: 20_000), .plainText),
        ]
        let clock = ContinuousClock()
        for (name, text, format) in inputs {
            var extraction: [Double] = []
            var whole: [Double] = []
            var findings = 0
            // The first pass loads the tokenizer's data and is left out, as the other benchmarks leave out theirs.
            for pass in 0...runs {
                let reading = try clock.measure { _ = try ProseSource.read(text, format: format) }
                var analysis = ProseAnalysis.notAnalysed(.noProse)
                let all = try clock.measure { analysis = try ProseCheck.analyse(text, format: format) }
                guard case .analysed(let report) = analysis else {
                    Issue.record("\(name) was not analysed")
                    return
                }
                findings = report.findings.count
                guard pass > 0 else { continue }
                extraction.append(Self.milliseconds(reading))
                whole.append(Self.milliseconds(all))
            }
            print(
                "BENCH prose/\(name) characters=\(text.count) findings=\(findings) runs=\(runs)"
                    + " total median=\(Self.format(Self.percentile(whole, 0.5))) p95=\(Self.format(Self.percentile(whole, 0.95)))"
                    + " max=\(Self.format(whole.max() ?? 0)) ms;"
                    + " reading median=\(Self.format(Self.percentile(extraction, 0.5))) ms")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func percentile(_ values: [Double], _ share: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * share).rounded(.up)) - 1)]
    }

    /// A linear congruential generator: the same text on every run and every machine.
    private struct Generator {
        var state: UInt64 = 0x5DEE_CE66D
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Made-up technical prose in Markdown: headings, paragraphs of a few sentences, some inline markup and a code
    /// block now and then, so that the reading of the source is measured with the analysis.
    static func japanese(characters: Int) -> String {
        let subjects = ["用紙", "余白", "印刷の設定", "プリンター", "ページの順序", "冊子のレイアウト", "見出しの書体", "表の罫線", "画像の解像度", "文書の構成"]
        let objects = ["確認", "変更", "保存", "比較", "調整", "選択", "記録", "点検", "整理", "更新"]
        let middles = [
            "を開く前に", "が変わったときは", "を決めるために", "に合わせて", "のあとで、もう一度", "について、担当の人と", "を **慎重に** ", "を `layout.json` で",
        ]
        let endings = ["します。", "しておくと、あとの作業が楽になります。", "する必要があります。", "できるかどうかを確かめます。", "した結果をメモに残しました。"]
        var generator = Generator()
        var text = ""
        var section = 0
        while text.count < characters {
            section += 1
            text += "## 第\(section)節 \(subjects[generator.next(subjects.count)])について\n\n"
            for _ in 0..<4 {
                for _ in 0..<(2 + generator.next(4)) {
                    text +=
                        subjects[generator.next(subjects.count)] + middles[generator.next(middles.count)]
                        + subjects[generator.next(subjects.count)] + "の" + objects[generator.next(objects.count)]
                        + "を" + endings[generator.next(endings.count)]
                }
                text += "\n\n"
            }
            if section % 5 == 0 { text += "```text\nlayout = booklet\n```\n\n" }
        }
        return text
    }

    static func english(words: Int) -> String {
        let nouns = [
            "sheet", "margin", "printer", "layout", "booklet", "heading", "table", "figure", "page", "setting",
        ]
        let verbs = [
            "checks", "changes", "saves", "compares", "adjusts", "selects", "records", "prints", "folds", "updates",
        ]
        let tails = ["before the next step.", "when the paper changes.", "and writes a short note about it.", "again."]
        var generator = Generator()
        var text = ""
        var count = 0
        while count < words {
            for _ in 0..<(3 + generator.next(4)) {
                let tail = tails[generator.next(tails.count)]
                text +=
                    "The \(nouns[generator.next(nouns.count)]) \(verbs[generator.next(verbs.count)]) the "
                    + "\(nouns[generator.next(nouns.count)]) \(tail) "
                count += 5 + tail.split(separator: " ").count
            }
            text += "\n\n"
        }
        return text
    }
}
