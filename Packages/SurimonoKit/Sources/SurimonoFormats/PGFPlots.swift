import Foundation

/// Axis math stays in data space until explicit limits, ticks and samples have all been checked. Drawing then
/// uses the same physical lengths, clipping, label reader, font measurement and export as other TikZ pictures.
enum PGFPlots {
    struct Drawing {
        var source: String
        var legend: Legend?
        var roles: [String]
    }

    struct Legend {
        let at: String
        let cellAlign: String
        let options: String
        struct Entry {
            let text: String
            let series: PGFPlotsSeries
        }
        let entries: [Entry]
    }

    static let keys: Set<String> = [
        "width", "height", "xmin", "xmax", "ymin", "ymax", "xlabel", "ylabel", "title",
        "xtick", "ytick", "xticklabels", "yticklabels", "grid", "grid style", "axis lines",
        "legend pos", "legend style", "legend cell align", "legend entries", "tick label style", "label style",
        "xmode", "ymode", "ybar", "bar width", "enlargelimits", "scaled ticks", "domain", "samples",
    ]

    static func lower(
        environment: String, options: String, body: String, colors: [String: (Double, Double, Double)] = [:]
    ) throws -> Drawing {
        var axis = try PGFPlotsInput.dictionary(options, allowed: keys)
        // Non-boxed axis styles disable automatic padding at the point where PGF applies the key.
        for option in try PGFPlotsInput.options(options) {
            if option.key == "axis lines", option.value != "box" { axis["enlargelimits"] = "false" }
            if option.key == "enlargelimits" { axis["enlargelimits"] = option.value ?? "true" }
        }
        if let ybar = axis["ybar"], ybar != "true" { throw TikZError("ybar") }
        var scanner = TikZScanner(body)
        var plots: [PGFPlotsSeries] = []
        var legends = try axis["legend entries"].map(PGFPlotsInput.list) ?? []
        var count = 0
        scanner.space()
        while !scanner.tail.isEmpty {
            if scanner.take("\\addplot") {
                let plus = scanner.take("+")
                scanner.space()
                let hasOptions = scanner.tail.first == "["
                let options = try scanner.options()
                guard plots.count < 64, options.utf8.count <= 2_000 else { throw TikZError("\\addplot limit") }
                var series = try PGFPlotsSeries(
                    index: plots.count, options: options, cycle: !hasOptions || plus, axis: axis, colors: colors)
                try series.read(&scanner)
                count += series.points.count
                guard count <= 5_000 else { throw TikZError("plot points") }
                plots.append(series)
            } else if scanner.take("\\addlegendentry") {
                guard legends.count < 64, axis["legend entries"] == nil else { throw TikZError("\\addlegendentry") }
                let entryOptions = try scanner.options()
                if !entryOptions.isEmpty {
                    throw TikZError(
                        "\\addlegendentry: "
                            + (try PGFPlotsInput.options(entryOptions)).map(\.key).joined(separator: ", "))
                }
                legends.append(try scanner.group("{", "}"))
                _ = scanner.take(";")
            } else {
                throw TikZError(
                    String(scanner.tail.prefix(while: { !$0.isWhitespace && !"{[;".contains($0) }).prefix(64)))
            }
            scanner.space()
        }
        guard !plots.isEmpty, legends.count <= plots.count else { throw TikZError("pgfplots: series") }

        func logMode(_ dimension: String) throws -> Bool {
            let implicit = environment == "semilog" + dimension + "axis" || environment == "loglogaxis"
            let value = axis[dimension + "mode"] ?? (implicit ? "log" : "normal")
            guard ["normal", "log"].contains(value) else { throw TikZError(dimension + "mode") }
            return value == "log"
        }
        // The pgfplots default includes 45 TeX pt per dimension for labels.
        let requestedWidth = try axis["width"].map(PGFPlotsInput.length)
        let requestedHeight = try axis["height"].map(PGFPlotsInput.length)
        let width = (requestedWidth ?? requestedHeight.map { $0 * 240 / 207 } ?? 240) - 45
        let height = (requestedHeight ?? requestedWidth.map { $0 * 207 / 240 } ?? 207) - 45
        guard width > 0, height > 0 else { throw TikZError("width/height") }
        let all = plots.flatMap(\.points)
        let x = try PGFPlotsScale(
            data: all.map(\.x), axis: "x", options: axis, length: width, logarithmic: logMode("x"))
        let barPlots = plots.filter(\.bars)
        let logY = try logMode("y")
        guard !logY || barPlots.isEmpty else { throw TikZError("log ybar") }
        let y = try PGFPlotsScale(
            data: all.map(\.y) + (barPlots.isEmpty ? [] : [0]), axis: "y", options: axis, length: height,
            logarithmic: logY)
        var plane = PGFPlotsPlane(x: x, y: y, options: axis)
        try plane.axes()
        try plane.add("\\begin{scope}\\clip " + point(0, 0) + " rectangle " + point(width, height) + ";")
        let barSpan = barPlots.reduce(0) { $0 + $1.barWidth } + Double(max(0, barPlots.count - 1)) * 2
        var left = -barSpan / 2
        for series in plots {
            try plane.series(series, barOffset: series.bars ? left + series.barWidth / 2 : 0)
            if series.bars {
                left += series.barWidth + 2
            }
        }
        try plane.add("\\end{scope}")
        let legend = try legend(axis, texts: legends, plots: plots, width: width, height: height)
        return Drawing(source: plane.source, legend: legend, roles: plane.roles)
    }

    private static func legend(
        _ axis: [String: String], texts: [String], plots: [PGFPlotsSeries], width: Double, height: Double
    ) throws -> Legend? {
        let position = axis["legend pos"] ?? "north east"
        let locations = [
            "north east": (0.97, 0.97), "north west": (0.03, 0.97), "south east": (0.97, 0.03),
            "south west": (0.03, 0.03), "outer north east": (1.03, 1.0),
        ]
        guard let corner = locations[position] else { throw TikZError("legend pos=" + position) }
        var location = axis["legend pos"] == nil ? (0.98, 0.98) : corner
        let anchor = position == "outer north east" ? "north west" : position
        var style = ["anchor=" + anchor, "draw=black", "fill=white"]
        let align = axis["legend cell align"] ?? "center"
        guard ["left", "right", "center"].contains(align) else { throw TikZError("legend cell align=" + align) }
        for item in try PGFPlotsInput.options(axis["legend style"] ?? "") {
            switch item.key {
            case "at":
                var scanner = TikZScanner(item.value ?? "")
                let pair = try PGFPlotsInput.list(scanner.group("(", ")"))
                scanner.space()
                guard scanner.tail.isEmpty, pair.count == 2 else { throw TikZError("legend style: at") }
                location = try (PGFPlotsInput.number(pair[0]), PGFPlotsInput.number(pair[1]))
            case "anchor", "draw", "fill", "font", "text", "inner sep", "line width": style.append(item.original)
            default: throw TikZError("legend style: " + item.key)
            }
        }
        guard location.0.isFinite, location.1.isFinite, abs(location.0) <= 100, abs(location.1) <= 100 else {
            throw TikZError("legend style: at")
        }
        guard !texts.isEmpty else { return nil }
        return Legend(
            at: point(location.0 * width, location.1 * height), cellAlign: align, options: style.joined(separator: ","),
            entries: zip(texts, plots).map { .init(text: $0.tikzUnbraced, series: $1) })
    }

    static func number(_ value: Double) -> String {
        if value == 0 { return "0" }
        return String(format: "%.10g", value)
    }

    static func point(_ x: Double, _ y: Double) -> String {
        "(\(number(x))pt,\(number(y))pt)"
    }
}

extension TikZParser {
    func legend(_ legend: PGFPlots.Legend, scope: TikZScope, label: (String) -> String) throws {
        let entries: [[String: Any]] = try legend.entries.map { entry in
            let plot = entry.series
            var row: [String: Any] = [
                "html": try labelID(entry.text, label: label),
                "style": try style(plot.paths.joined(separator: ","), scope: scope, kind: "draw"),
                "markSize": plot.markSize, "onlyMarks": plot.onlyMarks, "bars": plot.bars,
            ]
            if let mark = plot.mark { row["mark"] = mark }
            if let fill = plot.markFill { row["markFill"] = LaTeXSymbols.cssColor(fill, defined: colors) }
            return row
        }
        try append([
            "kind": "legend", "at": try coordinate(legend.at), "cellAlign": legend.cellAlign,
            "style": try style(legend.options, scope: scope, kind: "node"), "entries": entries,
        ])
    }
}
