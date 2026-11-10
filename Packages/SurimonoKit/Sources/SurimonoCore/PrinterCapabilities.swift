import CoreGraphics
import Foundation

/// What is wrong with sending a layout to a printer.
public enum PrinterIssue: Equatable, Sendable {
    case paperNotAccepted(PaperSize)
    case duplexNotAvailable
}

/// What a printer said it can do, as far as it said. Whatever it left unsaid is unknown, and an unknown never makes
/// an issue: a warning on a guess would be worse than none.
public struct PrinterCapabilities: Equatable, Sendable {
    /// The sizes a printer that takes custom paper accepts, in points.
    public struct CustomRange: Equatable, Sendable {
        public var width: ClosedRange<Double>
        public var height: ClosedRange<Double>

        public init(width: ClosedRange<Double>, height: ClosedRange<Double>) {
            self.width = width
            self.height = height
        }
    }

    /// The papers it lists, in points. Empty when it listed none, which says nothing about what it takes.
    public var paperSizes: [CGSize]
    public var customRange: CustomRange?
    /// Whether it prints on both sides; nil when it did not say.
    public var duplex: Bool?

    /// Printers round their papers to whole points (A4 is 595 × 842 in a PPD, 595.28 × 841.89 here).
    public static let tolerance = 2.0

    public init(paperSizes: [CGSize] = [], customRange: CustomRange? = nil, duplex: Bool? = nil) {
        self.paperSizes = paperSizes
        self.customRange = customRange
        self.duplex = duplex
    }

    /// The paper comes first: a sheet the printer does not take cannot be printed on either side.
    public func issue(for layout: PrintLayout) -> PrinterIssue? {
        if accepts(layout.sheet.size) == false { return .paperNotAccepted(layout.sheet) }
        if layout.sentDuplex != .none, duplex == false { return .duplexNotAvailable }
        return nil
    }

    /// Whether a sheet of this size goes in, lying either way; nil when the printer listed no papers at all.
    public func accepts(_ size: CGSize) -> Bool? {
        guard !paperSizes.isEmpty || customRange != nil else { return nil }
        let turned = CGSize(width: size.height, height: size.width)
        return [size, turned].contains { candidate in
            paperSizes.contains {
                abs($0.width - candidate.width) <= Self.tolerance && abs($0.height - candidate.height) <= Self.tolerance
            } || customRange.map { Self.contains($0, candidate) } == true
        }
    }

    private static func contains(_ range: CustomRange, _ size: CGSize) -> Bool {
        range.width.lowerBound - tolerance <= size.width && size.width <= range.width.upperBound + tolerance
            && range.height.lowerBound - tolerance <= size.height && size.height <= range.height.upperBound + tolerance
    }
}

extension PrinterCapabilities {
    /// Reads what the system gave for a printer: the papers of its paper list and the text of its PPD. A driverless
    /// (IPP / AirPrint) queue has a PPD too, which the system writes from what the printer reports. Returns nil when
    /// neither says anything.
    public init?(paperSizes listed: [CGSize], ppd text: String?) {
        // An empty or cut-off file is not a description that leaves duplex out.
        let ppd = text.flatMap { $0.contains("*PPD-Adobe") ? $0 : nil }
        var sizes = listed.filter { $0.width > 0 && $0.height > 0 }
        var widths: ClosedRange<Double>?
        var heights: ClosedRange<Double>?
        var duplexChoices: [String] = []
        var mentionsDuplex = false
        for line in (ppd ?? "").split(whereSeparator: \.isNewline) {
            // "*%" starts a comment.
            guard line.hasPrefix("*"), !line.hasPrefix("*%") else { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch words.first {
            case "*PaperDimension":
                let numbers = Self.numbers(afterColonIn: line)
                if numbers.count == 2, numbers[0] > 0, numbers[1] > 0 {
                    sizes.append(CGSize(width: numbers[0], height: numbers[1]))
                }
            case "*ParamCustomPageSize" where words.count >= 6:
                // "*ParamCustomPageSize Width: 1 points 252 842": the order, the unit, the smallest and the largest.
                guard let low = Double(words[4]), let high = Double(words[5]), low <= high else { continue }
                if words[1] == "Width:" { widths = low...high }
                if words[1] == "Height:" { heights = low...high }
            case "*Duplex" where words.count >= 2:
                duplexChoices.append(String(words[1].prefix { $0 != "/" && $0 != ":" }))
            default:
                break
            }
            let lowered = line.lowercased()
            if lowered.contains("duplex") || lowered.contains("sided") || line.contains("両面") { mentionsDuplex = true }
        }
        let duplex: Bool? =
            if ppd == nil {
                nil
            } else if !duplexChoices.isEmpty {
                duplexChoices.contains { $0 != "None" }
            } else if mentionsDuplex {
                // A driver may keep its duplex unit under a name of its own (an installable option, a vendor keyword).
                nil
            } else {
                false
            }
        let range = widths.flatMap { width in heights.map { CustomRange(width: width, height: $0) } }
        guard !sizes.isEmpty || range != nil || duplex != nil else { return nil }
        self.init(paperSizes: sizes, customRange: range, duplex: duplex)
    }

    /// The numbers of a PPD value such as `"595 842"`.
    private static func numbers(afterColonIn line: Substring) -> [Double] {
        guard let colon = line.firstIndex(of: ":") else { return [] }
        return line[line.index(after: colon)...]
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\"" })
            .compactMap { Double($0) }
    }
}
