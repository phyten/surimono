import Foundation

struct PGFPlotsPlane {
    let x: PGFPlotsScale
    let y: PGFPlotsScale
    let options: [String: String]
    var source = ""
    var roles: [String] = []
    private var commands = 0
    private var bytes = 0

    init(x: PGFPlotsScale, y: PGFPlotsScale, options: [String: String]) {
        self.x = x
        self.y = y
        self.options = options
    }

    mutating func add(_ text: String, role: String? = nil) throws {
        if let role { roles.append(role) }
        bytes += text.utf8.count
        commands += 1
        guard bytes <= 1_500_000, commands <= 5_000 else { throw TikZError("pgfplots: picture limit") }
        source += text + "\n"
    }

    mutating func axes() throws {
        let grid = options["grid"] ?? "none"
        let lines = options["axis lines"] ?? "box"
        guard ["major", "both", "none"].contains(grid) else { throw TikZError("grid=" + grid) }
        guard ["box", "left", "middle", "center"].contains(lines) else { throw TikZError("axis lines=" + lines) }
        let center = lines == "middle" || lines == "center"
        guard !center || !x.logarithmic && !y.logarithmic else { throw TikZError("axis lines=" + lines) }
        let xAxis = center ? try min(y.length, max(0, y.position(0))) : 0
        let yAxis = center ? try min(x.length, max(0, x.position(0))) : 0
        let gridStyle = "gray!60," + (options["grid style"] ?? "")
        let tickStyle = options["tick label style"] ?? ""
        let labelStyle = options["label style"] ?? ""
        var widestY = 0
        for (key, scale) in [("x", x), ("y", y)] {
            let ticks = try options[key + "tick"].map(Self.tickList) ?? scale.majorTicks()
            let labels = try options[key + "ticklabels"].map(PGFPlotsInput.list)
            let exponent = try tickExponent(ticks, scale: scale)
            func ends(_ near: Double, _ far: Double, _ p: Double) -> String {
                if key == "x" { return PGFPlots.point(p, near) + "--" + PGFPlots.point(p, far) }
                return PGFPlots.point(near, p) + "--" + PGFPlots.point(far, p)
            }
            let axisPosition = key == "x" ? xAxis : yAxis
            let opposite = key == "x" ? y.length : x.length
            if grid == "both" {
                for minor in try scale.minorLogTicks() {
                    let p = try scale.position(minor)
                    try add("\\draw[\(gridStyle)] " + ends(0, opposite, p) + ";")
                }
            }
            for (i, value) in ticks.enumerated() {
                let p = try scale.position(value)
                guard p >= -0.001, p <= scale.length + 0.001 else { continue }
                let text: String
                if let labels {
                    text = labels.indices.contains(i) ? labels[i].tikzUnbraced : ""
                } else if scale.logarithmic {
                    let power = log10(value)
                    text =
                        abs(power - power.rounded()) < 1e-9 ? "$10^{\(Int(power.rounded()))}$" : PGFPlots.number(value)
                } else {
                    let scaled = value / pow(10, Double(exponent))
                    guard scaled.isFinite, scaled != 0 || value == 0 else { throw TikZError("scaled ticks") }
                    text = PGFPlots.number(scaled)
                }
                if grid != "none" { try add("\\draw[\(gridStyle)] " + ends(0, opposite, p) + ";") }
                if lines == "box" {
                    try add("\\draw[gray] " + ends(opposite, opposite - 3, p) + ";")
                }
                if center, abs(p - (key == "x" ? yAxis : xAxis)) < 0.001 { continue }
                let a = axisPosition - (lines == "box" ? 0 : 1.5)
                try add("\\draw[gray] " + ends(a, a + 3, p) + ";")
                guard !text.isEmpty else { continue }
                let inset = lines == "box" ? 3.3 : 5.5
                let position = key == "x" ? PGFPlots.point(p, xAxis - inset) : PGFPlots.point(yAxis - inset, p)
                try add(
                    "\\node[inner sep=0pt,anchor=\(key == "x" ? "north" : "east"),\(tickStyle)] at \(position){\(text)};",
                    role: key == "x" ? "tickX" : "tickY")
                if key == "y" { widestY = max(widestY, scale.logarithmic && labels == nil ? 4 : text.count) }
            }
            if exponent != 0 {
                let at = key == "x" ? PGFPlots.point(x.length, xAxis - 15) : PGFPlots.point(yAxis, y.length + 2)
                try add(
                    "\\node[anchor=\(key == "x" ? "north west" : "south west"),\(tickStyle)] at \(at){$\\times 10^{\(exponent)}$};",
                    role: "")
            }
        }
        if lines == "box" {
            try add("\\draw " + PGFPlots.point(0, 0) + " rectangle " + PGFPlots.point(x.length, y.length) + ";")
        } else {
            try add("\\draw[-Stealth] " + PGFPlots.point(0, xAxis) + "--" + PGFPlots.point(x.length, xAxis) + ";")
            try add("\\draw[-Stealth] " + PGFPlots.point(yAxis, 0) + "--" + PGFPlots.point(yAxis, y.length) + ";")
        }
        if center, let text = options["xlabel"] {
            try add(
                "\\node[anchor=south east,\(labelStyle)] at " + PGFPlots.point(x.length, xAxis) + "{\(text)};", role: ""
            )
        } else if let text = options["xlabel"] {
            try add(
                "\\node[anchor=north,inner sep=0pt,\(labelStyle)] at " + PGFPlots.point(x.length / 2, xAxis - 17)
                    + "{\(text)};", role: "labelX")
        }
        if center, let text = options["ylabel"] {
            try add(
                "\\node[anchor=north west,\(labelStyle)] at " + PGFPlots.point(yAxis, y.length) + "{\(text)};", role: ""
            )
        } else if let text = options["ylabel"] {
            let offset = 12.5 + Double(widestY) * 4.8
            try add(
                "\\node[rotate=90,anchor=south,inner sep=0pt,\(labelStyle)] at "
                    + PGFPlots.point(yAxis - offset, y.length / 2) + "{\(text)};", role: "labelY")
        }
        if let text = options["title"] {
            try add("\\node[anchor=south] at " + PGFPlots.point(x.length / 2, y.length + 2) + "{\(text)};", role: "")
        }
    }

    private static func tickList(_ source: String) throws -> [Double] {
        let items = try PGFPlotsInput.list(source)
        var ticks: [Double] = []
        var i = 0
        while i < items.count {
            if items[i] == "..." {
                guard let last = ticks.last, i + 1 < items.count else { throw TikZError("tick range") }
                let end = try PGFPlotsInput.number(items[i + 1])
                let step = ticks.count > 1 ? last - ticks[ticks.count - 2] : (end < last ? -1 : 1)
                let n = (end - last) / step
                guard n.isFinite, n >= 0, n <= 512 else { throw TikZError("tick range") }
                for k in 0..<Int(floor(n + 1e-9)) { ticks.append(last + Double(k + 1) * step) }
                i += 2
            } else {
                ticks.append(try PGFPlotsInput.number(items[i]))
                i += 1
            }
            guard ticks.count <= 512 else { throw TikZError("tick limit") }
        }
        return ticks
    }

    private func tickExponent(_ ticks: [Double], scale: PGFPlotsScale) throws -> Int {
        let setting = options["scaled ticks"] ?? "true"
        switch setting {
        case "false": return 0
        case "true":
            guard !scale.logarithmic, !ticks.isEmpty else { return 0 }
            // PGF uses the axis limits even when the author supplies replacement tick strings.
            let magnitude = max(abs(scale.minimum), abs(scale.maximum))
            let exponent = Int(floor(log10(magnitude)))
            return exponent > 3 || exponent < -1 ? exponent : 0
        default:
            guard setting.hasPrefix("base 10:"), let power = Int(String(setting.dropFirst(8)).tikzTrimmed),
                (-300...300).contains(power),
                !scale.logarithmic
            else { throw TikZError("scaled ticks=" + setting) }
            return ticks.isEmpty ? 0 : -power
        }
    }

    mutating func series(_ plot: PGFPlotsSeries, barOffset: Double) throws {
        let points = try plot.points.map { try (x.position($0.x), y.position($0.y)) }
        let style = plot.paths.joined(separator: ",")
        if plot.bars {
            let baseline = try y.position(0)
            for (px, py) in points {
                try add(
                    "\\draw[\(style)] " + PGFPlots.point(px + barOffset - plot.barWidth / 2, baseline) + " rectangle "
                        + PGFPlots.point(px + barOffset + plot.barWidth / 2, py) + ";")
            }
        } else if !plot.onlyMarks {
            let path = points.map { PGFPlots.point($0.0, $0.1) }.joined(separator: "--")
            try add("\\draw[\(style)] " + path + ";")
        }
        if let mark = plot.mark {
            for (px, py) in points { try drawMark(mark, x: px, y: py, plot: plot) }
        }
    }

    private mutating func drawMark(_ mark: String, x: Double, y: Double, plot: PGFPlotsSeries) throws {
        let r = plot.markSize
        func p(_ dx: Double, _ dy: Double) -> String { PGFPlots.point(x + dx * r, y + dy * r) }
        let color = plot.markFill.map { ",fill=" + $0 } ?? ""
        let closed = mark.contains("*")
        let paint =
            (closed ? "\\filldraw[" : "\\draw[") + (plot.paths + ["solid"]).joined(separator: ",")
            + (closed ? color : "") + "] "
        let line = "\\draw[" + (plot.paths + ["solid", "fill=none"]).joined(separator: ",") + "] "
        // Polar points of PGF's pentagon and the six-pointed asterisk, in units of the mark size.
        func polar(_ degrees: Double) -> String {
            p(cos(degrees * .pi / 180), sin(degrees * .pi / 180))
        }
        let k = sqrt(0.5)
        switch mark {
        case "*", "o", "otimes", "otimes*", "oplus", "oplus*":
            try add(paint + p(0, 0) + " circle (" + PGFPlots.number(r) + "pt);")
            if mark.hasPrefix("otimes") {
                try add(line + p(-k, -k) + "--" + p(k, k) + " " + p(-k, k) + "--" + p(k, -k) + ";")
            } else if mark.hasPrefix("oplus") {
                try add(line + p(-1, 0) + "--" + p(1, 0) + " " + p(0, -1) + "--" + p(0, 1) + ";")
            }
        case "square", "square*":
            try add(paint + p(-1, -1) + " rectangle " + p(1, 1) + ";")
        case "triangle", "triangle*":
            try add(paint + p(0, 1.33) + "--" + p(-1.15, -0.665) + "--" + p(1.15, -0.665) + "--cycle;")
        case "diamond", "diamond*":
            try add(paint + p(0, 1.3) + "--" + p(1, 0) + "--" + p(0, -1.3) + "--" + p(-1, 0) + "--cycle;")
        case "pentagon", "pentagon*":
            try add(paint + [90, 18, -54, 234, 162].map(polar).joined(separator: "--") + "--cycle;")
        case "star":
            for i in 0..<5 {
                let angle = (Double(i) / 5 * 2 + 0.5) * .pi
                try add(line + p(0, 0) + "--" + p(cos(angle), sin(angle)) + ";")
            }
        case "asterisk":
            let spokes = [p(0, -1) + "--" + p(0, 1), polar(30) + "--" + polar(210), polar(-30) + "--" + polar(150)]
            try add(line + spokes.joined(separator: " ") + ";")
        case "x": try add(line + p(-1, -1) + "--" + p(1, 1) + " " + p(-1, 1) + "--" + p(1, -1) + ";")
        case "+": try add(line + p(-1, 0) + "--" + p(1, 0) + " " + p(0, -1) + "--" + p(0, 1) + ";")
        case "|": try add(line + p(0, 1) + "--" + p(0, -1) + ";")
        case "-": try add(line + p(1, 0) + "--" + p(-1, 0) + ";")
        default: throw TikZError("mark=" + mark)
        }
    }

    /// Every mark drawMark knows. The legend painter in tikz.js draws the same set with the same geometry.
    static let marks: Set<String> = [
        "*", "o", "square", "square*", "triangle", "triangle*", "diamond", "diamond*", "pentagon", "pentagon*",
        "x", "+", "|", "-", "star", "asterisk", "oplus", "oplus*", "otimes", "otimes*",
    ]
}
