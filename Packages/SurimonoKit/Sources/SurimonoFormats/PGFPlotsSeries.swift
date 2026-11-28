import Foundation

struct PGFPlotsSeries {
    struct Point {
        let x: Double
        let y: Double
    }

    var points: [Point] = []
    var paths: [String] = []
    var mark: String?
    var markSize = 2.0
    var onlyMarks = false
    var bars = false
    var barWidth = 10.0
    var markFill: String?
    var domain = "-5:5"
    var samples = 25

    init(index: Int, options: String, cycle: Bool, axis: [String: String], colors: [String: (Double, Double, Double)])
        throws
    {
        let tags = try PGFPlotsInput.options(options)
        bars = axis["ybar"] != nil || tags.contains { $0.key == "ybar" }
        if let width = axis["bar width"] { barWidth = try PGFPlotsInput.length(width) }
        if let range = axis["domain"] { domain = range }
        if let n = axis["samples"] { samples = try Self.count(n) }
        if cycle {
            let colors = [
                "blue", "red", "brown!60!black", "black", "blue", "red", "brown!60!black", "black", "blue", "red",
            ]
            let marks = ["*", "square*", "otimes*", "star", "diamond*"]
            let barColors = ["blue", "red", "brown!60!black", "black", "violet!80!black", "green"]
            let barFills = ["blue!30", "red!30", "brown!30", "gray", "violet", "green!80!black"]
            if bars {
                paths = [barColors[index % 6], "fill=" + barFills[index % 6]]
            } else {
                let i = index % colors.count
                paths = [colors[i]]
                if i >= 5 { paths.append("densely dashed") }
                mark = marks[i % marks.count]
                markFill =
                    [
                        "blue!80!black", "red!80!black", "brown!80!black", "black", "blue!80!black",
                        "red!80!black", "brown!80!black", "gray", "blue", "red!80!black",
                    ][i]
            }
        }

        for item in tags {
            switch (item.key, item.value) {
            case ("domain", let v?): domain = v
            case ("samples", let v?): samples = try Self.count(v)
            case ("mark size", let v?): markSize = try PGFPlotsInput.length(v)
            case ("mark", let v?):
                guard v == "none" || PGFPlotsPlane.marks.contains(v) else { throw TikZError("mark=" + v) }
                mark = v == "none" ? nil : v
            case ("only marks", nil): onlyMarks = true
            case ("ybar", nil): bars = true
            case ("bar width", let v?): barWidth = try PGFPlotsInput.length(v)
            case ("draw", _), ("color", _), ("fill", _), ("line width", _), ("line cap", _), ("line join", _),
                ("opacity", _), ("fill opacity", _), ("dash pattern", _):
                paths.append(item.original)
            case (_, nil):
                guard
                    TikZParser.widths[item.key] != nil
                        || ["solid", "dashed", "densely dashed", "loosely dashed", "dotted"].contains(item.key)
                        || LaTeXSymbols.cssColor(item.key, defined: colors) != nil
                else { throw TikZError(item.key) }
                paths.append(item.original)
            default: throw TikZError(item.key)
            }
        }
        if onlyMarks, !tags.contains(where: { $0.key == "mark" }), mark == nil { mark = "*" }
        guard !onlyMarks || !bars else { throw TikZError("only marks,ybar") }
        if bars && !cycle && !paths.contains(where: { $0.hasPrefix("fill=") }) { paths.append("fill=none") }
    }

    private static func count(_ value: String) throws -> Int {
        guard let n = Int(value), (2...2_000).contains(n) else { throw TikZError("samples") }
        return n
    }

    mutating func read(_ input: inout TikZScanner) throws {
        if input.take("coordinates") {
            var rows = TikZScanner(try input.group("{", "}"))
            rows.space()
            while !rows.tail.isEmpty {
                guard points.count < 2_000 else { throw TikZError("coordinates") }
                let pair = try PGFPlotsInput.list(rows.group("(", ")"))
                guard pair.count == 2 else { throw TikZError("coordinates") }
                points.append(try Point(x: PGFPlotsInput.number(pair[0]), y: PGFPlotsInput.number(pair[1])))
                rows.space()
            }
        } else if input.take("table") {
            let columns = try PGFPlotsInput.dictionary(input.options(), allowed: ["x", "y"])
            let rows = try input.group("{", "}").split(whereSeparator: { $0.isNewline }).map {
                $0.split(whereSeparator: { $0.isWhitespace })
            }.filter { !$0.isEmpty }
            guard let first = rows.first, first.count >= 2, rows.count <= 2_001 else { throw TikZError("table") }
            let hasHeader = columns.count > 0 || Double(first[0]) == nil
            let x = columns["x"].flatMap { first.firstIndex(of: Substring($0)) }
            let y = columns["y"].flatMap { first.firstIndex(of: Substring($0)) }
            guard columns["x"] == nil || x != nil, columns["y"] == nil || y != nil else {
                throw TikZError("table columns")
            }
            let (xi, yi) = (x ?? 0, y ?? 1)
            for row in rows.dropFirst(hasHeader ? 1 : 0) {
                guard row.count == first.count, points.count < 2_000 else { throw TikZError("table row") }
                points.append(
                    try Point(x: PGFPlotsInput.number(String(row[xi])), y: PGFPlotsInput.number(String(row[yi]))))
            }
        } else {
            let expression = try input.group("{", "}")
            let ends = domain.components(separatedBy: ":")
            guard ends.count == 2, expression.utf8.count <= 512 else { throw TikZError("domain") }
            let start = try PGFPlotsInput.number(ends[0])
            let end = try PGFPlotsInput.number(ends[1])
            for i in 0..<samples {
                let x = start + (end - start) * (Double(i) / Double(samples - 1))
                let y = try PGFMath.evaluate(expression, x: x)
                guard x.isFinite, y.isFinite else { throw TikZError("pgfplots: expression") }
                points.append(Point(x: x, y: y))
            }
        }
        guard !points.isEmpty, input.take(";") else { throw TikZError("\\addplot") }
    }
}
