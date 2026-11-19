import Foundation

struct PGFPlotsScale {
    let minimum: Double
    let maximum: Double
    let logarithmic: Bool
    let length: Double

    init(data: [Double], axis: String, options: [String: String], length: Double, logarithmic: Bool) throws {
        self.length = length
        self.logarithmic = logarithmic
        guard !data.isEmpty, data.allSatisfy({ $0.isFinite && (!logarithmic || $0 > 0) }) else {
            throw TikZError(axis + " range")
        }
        let start = try options[axis + "min"].map(PGFPlotsInput.number)
        let end = try options[axis + "max"].map(PGFPlotsInput.number)
        guard var lower = start ?? data.min(), var upper = end ?? data.max(),
            upper >= lower, !logarithmic || lower > 0
        else { throw TikZError(axis + " range") }
        if logarithmic {
            lower = log10(lower)
            upper = log10(upper)
        }
        if lower == upper {
            guard start == nil || end == nil else { throw TikZError(axis + " range") }
            let extra = logarithmic ? 1 : max(1, abs(lower) * 0.1)
            if start == nil { lower -= extra }
            if end == nil { upper += extra }
        }
        let enlargement = options["enlargelimits"] ?? "auto"
        let fraction: Double
        switch enlargement {
        case "auto", "true": fraction = 0.1
        case "false": fraction = 0
        default: fraction = try PGFPlotsInput.number(enlargement)
        }
        guard fraction >= 0, fraction <= 100 else { throw TikZError("enlargelimits") }
        let padding = (upper - lower) * fraction
        minimum = lower - (start == nil || enlargement != "auto" ? padding : 0)
        maximum = upper + (end == nil || enlargement != "auto" ? padding : 0)
        guard minimum.isFinite, maximum.isFinite, (maximum - minimum).isFinite, maximum > minimum else {
            throw TikZError(axis + " range")
        }
    }

    func position(_ value: Double) throws -> Double {
        let n = logarithmic ? log10(value) : value
        let pt = ((n - minimum) / (maximum - minimum)) * length
        guard pt.isFinite, abs(pt) <= 1e6 else { throw TikZError("pgfplots: coordinate") }
        return pt
    }

    func majorTicks() throws -> [Double] {
        let span = maximum - minimum
        if logarithmic {
            guard minimum >= -306, maximum < 307 else { throw TikZError("log ticks") }
            let stride = max(1, ceil(span / max(2, length / 25)))
            return try multiples(of: stride).map { pow(10, $0) }
        }
        // PGFplots prefers readable 1, 2, 5 steps. Choosing the next larger step avoids crowded labels.
        let rough = span / max(2, length / 25)
        let base = pow(10, floor(log10(rough)))
        let factor = [1.0, 2.0, 5.0, 10.0].first { $0 * base >= rough * (1 - 1e-10) } ?? 10
        return try multiples(of: factor * base)
    }

    private func multiples(of step: Double) throws -> [Double] {
        let first = ceil(minimum / step - 1e-10)
        let last = floor(maximum / step + 1e-10)
        guard step > 0, step.isFinite, first.isFinite, last.isFinite, abs(first) < 9e15, last - first <= 512 else {
            throw TikZError("pgfplots: ticks")
        }
        return (0..<max(0, Int(last - first) + 1)).map { (first + Double($0)) * step }
    }

    func minorLogTicks() throws -> [Double] {
        guard logarithmic else { return [] }
        guard minimum >= -306, maximum < 307, maximum - minimum <= 32 else { throw TikZError("minor log ticks") }
        return (Int(floor(minimum))...Int(floor(maximum))).flatMap { exponent in
            (2...9).map { Double($0) * pow(10.0, Double(exponent)) }
        }.filter { log10($0) >= minimum && log10($0) <= maximum }
    }
}
