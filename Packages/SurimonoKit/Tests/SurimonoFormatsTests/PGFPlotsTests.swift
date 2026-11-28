import Foundation
import Testing

@testable import SurimonoFormats

struct PGFPlotsTests {
    @Test("空の横軸目盛りは線だけを描き、余ったラベルを後続の目盛りへずらさない")
    func sparseTickLabels() throws {
        let body = #"\addplot coordinates {(0,1)(3,1)};"#
        let drawing = try PGFPlots.lower(
            environment: "axis",
            options: "xtick={0,1,2,3},xticklabels={A,,C,{},Unused},ytick={}", body: body)
        #expect(drawing.roles == ["tickX", "tickX"])
        #expect(drawing.source.contains("(16.25pt,-3.3pt){A}") && drawing.source.contains("(124.5833333pt,-3.3pt){C}"))
        #expect(!drawing.source.contains("Unused"))
        #expect(drawing.source.components(separatedBy: #"\draw[gray]"#).count - 1 == 8)
        let short = try PGFPlots.lower(
            environment: "axis", options: "xtick={0,1,2},xticklabels={A},ytick={}", body: body)
        #expect(short.roles == ["tickX"])
    }

    @Test("凡例は既定で列の中央に置き、左右揃えと明示した隅の位置を読む")
    func legendCells() throws {
        let body = #"\addplot coordinates {(0,1)(1,1)};\addlegendentry{A}"#
        let implicit = try #require(PGFPlots.lower(environment: "axis", options: "", body: body).legend)
        #expect(implicit.cellAlign == "center")
        #expect(implicit.at == "(191.1pt,158.76pt)")
        for align in ["left", "right", "center"] {
            let legend = try #require(
                PGFPlots.lower(
                    environment: "axis",
                    options: "legend pos=north west,legend cell align=\(align)", body: body
                ).legend)
            #expect(legend.cellAlign == align)
            #expect(legend.at == "(5.85pt,157.14pt)")
        }
        #expect(throws: TikZError.self) {
            try PGFPlots.lower(environment: "axis", options: "legend cell align=justify", body: body)
        }
    }

    @Test("水路の基準 PDF と同じ座標と目盛りを選ぶ")
    func linearTicks() throws {
        let x = try PGFPlotsScale(data: [0, 1, 2, 3], axis: "x", options: [:], length: 195, logarithmic: false)
        let y = try PGFPlotsScale(data: [8, 7, 5, 4], axis: "y", options: [:], length: 162, logarithmic: false)
        #expect(try x.majorTicks() == [0, 0.5, 1, 1.5, 2, 2.5, 3])
        #expect(try y.majorTicks() == [4, 5, 6, 7, 8])
        #expect(abs(try x.position(1) - x.position(0) - 54.16667) < 0.001)
        #expect(abs(try y.position(5) - y.position(4) - 33.75) < 0.001)
    }

    @Test("沈降の基準 PDF と同じ指数の主目盛りと等比の補助目盛りを選ぶ")
    func logTicks() throws {
        let x = try PGFPlotsScale(data: [0, 4], axis: "x", options: [:], length: 195, logarithmic: false)
        let y = try PGFPlotsScale(data: [exp(-4), 1], axis: "y", options: [:], length: 162, logarithmic: true)
        #expect(try x.majorTicks() == [0, 1, 2, 3, 4])
        #expect(try y.majorTicks() == [0.1, 1])
        let minors = try y.minorLogTicks()
        #expect(minors.count == 16)
        #expect(abs(try y.position(0.1) - y.position(0.01) - 77.71225) < 0.001)
    }

    @Test("明示した軸の範囲は自動で広げず大きい目盛りに倍率を付ける")
    func scaledTicks() throws {
        let plot = try PGFPlots.lower(
            environment: "axis", options: "xmin=0,xmax=50000,xtick={0,25000,50000},scaled ticks=true",
            body: #"\addplot[blue] coordinates {(0,1)(50000,2)};"#)
        #expect(plot.source.contains(#"{$\times 10^{4}$}"#))
        #expect(plot.source.contains("{2.5}"))
        #expect(plot.source.contains("(195pt,"))
    }

    @Test("文字の目盛りにも指定された指数の倍率を添える")
    func customTickMultiplier() throws {
        let plot = try PGFPlots.lower(
            environment: "axis",
            options: "xmin=0,xmax=50000,xtick={0,25000,50000},xticklabels={A,B,C},scaled ticks=true",
            body: #"\addplot coordinates {(0,1)(50000,2)};"#)
        #expect(plot.source.contains("{B}"))
        #expect(plot.source.contains(#"{$\times 10^{4}$}"#))
        let fixed = try PGFPlots.lower(
            environment: "axis", options: "scaled ticks=base 10:-3,xtick={0,2000},ytick={}",
            body: #"\addplot coordinates {(0,1)(2000,2)};"#)
        #expect(fixed.source.contains("{2}"))
        #expect(fixed.source.contains(#"{$\times 10^{3}$}"#))
    }

    @Test("系列の明示設定と加算設定で巡回の色と印を区別する")
    func cycle() throws {
        let plot = try PGFPlots.lower(
            environment: "axis",
            options: #"legend style={at={(0.5,-.2)},anchor=north,draw=none,fill=none,font=\small}"#,
            body: #"""
                \addplot coordinates {(0,0)(1,1)};\addlegendentry{First}
                \addplot[only marks] coordinates {(0,1)(1,0)};\addlegendentry{Second}
                \addplot+[dashed,mark=x,domain=0:1,samples=4] {x^2};\addlegendentry{Third}
                """#)
        let legend = try #require(plot.legend)
        #expect(legend.at == "(97.5pt,-32.4pt)")
        #expect(legend.entries.map(\.text) == ["First", "Second", "Third"])
        #expect(legend.entries.map(\.series.mark) == ["*", "*", "x"])
        #expect(legend.entries[0].series.paths.contains("blue"))
        #expect(legend.entries[1].series.paths.isEmpty && legend.entries[1].series.onlyMarks)
        #expect(legend.entries[2].series.paths == ["brown!60!black", "dashed"])
        #expect(legend.entries[2].series.points.count == 4)
        #expect(legend.entries[2].series.points.last?.y == 1)
    }

    @Test(
        "pgfplots の標準の印を描き、星の付かない印は塗らない",
        arguments: [
            ("diamond", 1, false), ("diamond*", 1, true), ("pentagon", 1, false), ("pentagon*", 1, true),
            ("oplus", 2, false), ("oplus*", 2, true), ("otimes", 2, false), ("|", 1, false), ("-", 1, false),
            ("asterisk", 1, false),
        ])
    func standardMarks(mark: String, commands: Int, filled: Bool) throws {
        let plot = try PGFPlots.lower(
            environment: "axis", options: "xtick={},ytick={}",
            body: "\\addplot[only marks,mark=\(mark)] coordinates {(0,0)};\\addlegendentry{A}")
        #expect(plot.legend?.entries.first?.series.mark == mark)
        let lines = plot.source.split(separator: "\n").filter { $0.contains("solid") }
        #expect(lines.count == commands)
        #expect(lines.first?.hasPrefix(#"\filldraw"#) == filled)
    }

    @Test(
        "星の付かない印は系列に塗りの色があっても塗らず、星の付く印はその色で塗る",
        arguments: ["diamond", "pentagon", "oplus", "otimes", "o", "square", "triangle", "diamond*", "square*"])
    func seriesFill(mark: String) throws {
        let plot = try PGFPlots.lower(
            environment: "axis", options: "xtick={},ytick={}",
            body: "\\addplot[only marks,draw=black,fill=yellow,mark=\(mark)] coordinates {(0,0)};")
        let lines = plot.source.split(separator: "\n").filter { $0.contains("solid") }
        // TikZ lets the last fill key win, so read the final one in each option list.
        let fills = try lines.map { line in
            try #require(line.split(separator: "]").first).split(separator: ",").last { $0.hasPrefix("fill=") }
        }
        try #require(!fills.isEmpty)
        #expect(fills.first == (mark.hasSuffix("*") ? "fill=yellow" : "fill=none"))
        #expect(fills.dropFirst().allSatisfy { $0 == "fill=none" })
    }

    @Test("菱形と三角形の印は PGF の定義と同じ寸法で描く")
    func pgfMarkDimensions() throws {
        func outline(_ mark: String) throws -> [[Double]] {
            // A filled circle at the same point gives the mark's center.
            let plot = try PGFPlots.lower(
                environment: "axis", options: "xtick={},ytick={}",
                body: "\\addplot[only marks,mark=*] coordinates {(0,0)};"
                    + "\\addplot[only marks,mark=\(mark),mark size=4pt] coordinates {(0,0)};")
            let lines = plot.source.split(separator: "\n").filter { $0.contains("solid") }
            try #require(lines.count == 2)
            func points(_ line: Substring) -> [[Double]] {
                line.matches(of: /\((-?[0-9.e+-]+)pt,(-?[0-9.e+-]+)pt\)/).compactMap { match in
                    guard let x = Double(match.1), let y = Double(match.2) else { return nil }
                    return [x, y]
                }
            }
            let center = try #require(points(lines[0]).first)
            return points(lines[1]).map { [$0[0] - center[0], $0[1] - center[1]] }
        }
        func close(_ actual: [[Double]], _ expected: [[Double]]) -> Bool {
            actual.count == expected.count
                && zip(actual, expected).allSatisfy { abs($0[0] - $1[0]) < 1e-6 && abs($0[1] - $1[1]) < 1e-6 }
        }
        // pgflibraryplotmarks: the diamond reaches ±r vertically and ±0.75r horizontally; the triangle
        // has its apex at r and its base corners at polar −30° and −150°.
        #expect(close(try outline("diamond"), [[0, 4], [3, 0], [0, -4], [-3, 0]]))
        #expect(close(try outline("triangle*"), [[0, 4], [3.4641016, -2], [-3.4641016, -2]]))
    }

    @Test("棒の表を列名で読み横軸の文字と目盛りに対応付ける")
    func namedTable() throws {
        let plot = try PGFPlots.lower(
            environment: "axis", options: "ybar,xtick={1,2},xticklabels={第一,第二},legend entries={件数}",
            body: #"""
                \addplot table[x=bin,y=n] {
                  n bin
                  10 1
                  20 2
                };
                """#)
        #expect(plot.source.contains("{第一}") && plot.source.contains("{第二}"))
        let series = try #require(plot.legend?.entries.first?.series)
        #expect(series.bars && series.paths == ["blue", "fill=blue!30"])
        #expect(series.points.map(\.x) == [1, 2])
        #expect(series.points.map(\.y) == [10, 20])
    }

    @Test("未対応のキー・外部表・対数のゼロ・不正な式・上限超過は図全体を残さない")
    func fallback() {
        for (settings, body) in [
            ("legend columns=2", #"\addplot {x};"#), ("grid=minor", #"\addplot {x};"#),
            ("ymode=log", #"\addplot coordinates {(0,0)(1,1)};"#),
            ("scaled ticks=real:32", #"\addplot {x};"#),
            ("", #"\addplot table {file.csv};"#), ("", #"\addplot[samples=2001] {x};"#),
            ("", #"\addplot {1/(x-x)};"#), ("", #"\addplot[smooth] {x};"#),
            ("", #"\addplot {x}; \draw (0,0)--(1,1);"#),
            ("", #"\addplot {x}; \addlegendentry[rotate=10]{A}"#),
            ("xmode=log", #"\addplot coordinates {(-1,1)(2,2)};"#),
            ("", #"\addplot[mark=unknown] coordinates {(0,0)(1,1)};"#),
        ] {
            #expect(throws: (any Error).self) { try PGFPlots.lower(environment: "axis", options: settings, body: body) }
        }
    }
}
