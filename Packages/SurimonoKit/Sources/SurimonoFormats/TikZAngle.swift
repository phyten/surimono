import Foundation

extension TikZParser {
    /// An angles-library pic is defined in physical space. Decline a coordinate that depends on a
    /// measured node, font-relative length or affine transform; those points exist only in the DOM.
    func physicalPoints(_ length: String, unit: String) -> Double? {
        func physical(_ value: String) -> Double? {
            for (suffix, scale) in [
                ("cm", 72.27 / 2.54), ("mm", 72.27 / 25.4), ("pt", 1.0),
                ("bp", 72.27 / 72), ("in", 72.27), ("pc", 12.0),
            ] where value.hasSuffix(suffix) {
                return Double(value.dropLast(suffix.count)).map { $0 * scale }
            }
            return nil
        }
        let result = physical(length) ?? Double(length).flatMap { value in physical(unit).map { value * $0 } }
        guard let result, abs(result) <= 1e7 else { return nil }
        return result
    }

    func anglePic(_ input: inout TikZScanner, scope: TikZScope, label: (String) -> String) throws {
        let options = try TikZScanner.split(input.options(), at: ",")
        let spec = try TikZScanner.split(input.group("{", "}"), at: "=")
        guard spec.count == 2, spec[0] == "angle", input.take(";") else { throw TikZError("\\pic") }
        let names = spec[1].components(separatedBy: "--").map(\.tikzTrimmed)
        guard names.count == 3, let a = anglePoints[names[0]], let b = anglePoints[names[1]],
            let c = anglePoints[names[2]], a != b, b != c, scope.values["transforms"] == nil
        else {
            throw TikZError("angle coordinates")
        }
        var styles: [String] = []
        var text: String?
        var radius = 5 * 72.27 / 25.4
        var eccentricity = 0.6
        for option in options where !option.isEmpty {
            if option.hasPrefix("\"") {
                guard text == nil, let end = option.dropFirst().firstIndex(of: "\"") else { throw TikZError("quotes") }
                text = String(option[option.index(after: option.startIndex)..<end])
                var suffix = TikZScanner(String(option[option.index(after: end)...]))
                suffix.space()
                if !suffix.tail.isEmpty {
                    let settings = try TikZScanner.split(suffix.group("{", "}"), at: "=")
                    // The library places the text before applying its local options. A text-local
                    // eccentricity has no effect on its position (unlike a pic-level eccentricity).
                    guard settings.count == 2, settings[0] == "angle eccentricity", (try? scalar(settings[1])) != nil
                    else { throw TikZError("pic text options") }
                    suffix.space()
                    guard suffix.tail.isEmpty else { throw TikZError("quotes") }
                }
            } else {
                let parts = try TikZScanner.split(option, at: "=")
                switch parts[0] {
                case "angle radius":
                    guard parts.count == 2, let r = physicalPoints(try length(parts[1]), unit: "1pt"), r > 0 else {
                        throw TikZError(option)
                    }
                    radius = r
                case "angle eccentricity":
                    guard parts.count == 2 else { throw TikZError(option) }
                    eccentricity = try scalar(parts[1])
                case "draw", "line width", "thin", "thick", "dashed", "color": styles.append(option)
                default: throw TikZError(parts[0])
                }
            }
        }
        let paint = try style(styles.joined(separator: ","), scope: scope, kind: "path")
        guard paint["fill"] as? String == "none", paint["transforms"] == nil else {
            throw TikZError("angle fill/transform")
        }
        let start = atan2(a.y - b.y, a.x - b.x) * 180 / .pi
        var end = atan2(c.y - b.y, c.x - b.x) * 180 / .pi
        if end < start { end += 360 }
        func at(_ degrees: Double, _ distance: Double) throws -> [String: String] {
            let theta = degrees * .pi / 180
            let x = b.x + distance * cos(theta)
            let y = b.y + distance * sin(theta)
            guard abs(x) <= 1e8, abs(y) <= 1e8 else { throw TikZError("angle dimension") }
            return ["x": tikzNumber(x) + "pt", "y": tikzNumber(y) + "pt"]
        }
        let r = tikzNumber(radius) + "pt"
        let ops: [Object] = [
            ["op": "M", "p": try at(start, radius)], ["op": "arc", "start": start, "end": end, "rx": r, "ry": r],
        ]
        try append(["kind": "path", "style": paint, "ops": ops])
        if let text {
            try append([
                "kind": "node", "style": try style("", scope: scope, kind: "node"),
                "at": try at((start + end) / 2, radius * eccentricity), "html": try labelID(text, label: label),
            ])
        }
    }
}
